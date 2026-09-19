# Storage adapter only. Build -> lossless binary CSR spool -> builder EXIT ->
# native HiGHS. Never hold a JuMP construction model beside the solver model.
# All rows/columns survive. HiGHS's own ordinary presolve remains unchanged.
using SHA, Serialization, Mmap

const SPOOL_SCHEMA="go3_scheduling_binary_csr_v1"
const SPOOL_SETS=(MOI.GreaterThan{Float64},MOI.LessThan{Float64},MOI.EqualTo{Float64},MOI.Interval{Float64})
const SPOOL_F=MOI.ScalarAffineFunction{Float64}
const SPOOL_FIELDS=("col_cost","col_lower","col_upper","integrality","row_lower","row_upper","a_start","a_index","a_value")
spool_sha(path)=open(io->bytes2hex(SHA.sha256(io)),path,"r")

function spool_local(path)
    occursin("onedrive",lowercase(abspath(path))) && error("OneDrive spool forbidden")
    p=abspath(path)
    ancestor=p
    while !ispath(ancestor); ancestor=dirname(ancestor); end
    occursin("onedrive",lowercase(realpath(ancestor))) && error("OneDrive resolved spool forbidden")
    p
end
spool_check_deadline(deadline)=time()<deadline || error("Scheduling storage work deadline exhausted")
spool_bounds(s::MOI.GreaterThan)= (s.lower,Inf)
spool_bounds(s::MOI.LessThan)= (-Inf,s.upper)
spool_bounds(s::MOI.EqualTo)= (s.value,s.value)
spool_bounds(s::MOI.Interval)= (s.lower,s.upper)
spool_map(f,x::Array)=map(f,x)
spool_map(f,x::JuMP.Containers.DenseAxisArray)=JuMP.Containers.DenseAxisArray(map(f,x.data),axes(x)...)

# An IOBuffer per stream bounds allocations and avoids a syscall per matrix entry.
mutable struct SpoolStream
    io::IOStream
    buffer::IOBuffer
end
SpoolStream(path)=SpoolStream(open(path,"w"),IOBuffer())
function spool_write(s::SpoolStream,x)
    write(s.buffer,x)
    position(s.buffer)>=2^20 && write(s.io,take!(s.buffer))
end
function Base.close(s::SpoolStream)
    write(s.io,take!(s.buffer));close(s.io)
end
function spool_name(s::SpoolStream,id,name)
    spool_write(s,Int64(id));spool_write(s,Int32(ncodeunits(name)));spool_write(s,codeunits(name))
end

function spool_columns!(src,n,directory;deadline,on_event)
    lo=fill(-Inf,n);hi=fill(Inf,n);cost=zeros(n);integer=zeros(HiGHS.HighsInt,n)
    # Match the pinned MOI->HiGHS order, then intersect binary domains just as
    # HiGHS.jl does immediately before optimize! (not generator-bound clipping).
    for S in SPOOL_SETS
        ids=MOI.get(src,MOI.ListOfConstraintIndices{MOI.VariableIndex,S}())
        for (j,ci) in enumerate(ids)
            v=MOI.get(src,MOI.ConstraintFunction(),ci).value
            l,u=spool_bounds(MOI.get(src,MOI.ConstraintSet(),ci))
            S!=MOI.LessThan{Float64} && (lo[v]=l)
            S!=MOI.GreaterThan{Float64} && (hi[v]=u)
            j%65536==0 && spool_check_deadline(deadline)
        end
        ids=nothing;GC.gc(false)
    end
    domain_counts=Dict{String,Int}()
    for S in (MOI.ZeroOne,MOI.Integer)
        ids=MOI.get(src,MOI.ListOfConstraintIndices{MOI.VariableIndex,S}())
        domain_counts[string(S)]=length(ids)
        for ci in ids
            v=MOI.get(src,MOI.ConstraintFunction(),ci).value
            integer[v]=HiGHS.kHighsVarTypeInteger
            S==MOI.ZeroOne && (lo[v]=max(0.0,lo[v]);hi[v]=min(1.0,hi[v]))
        end
        ids=nothing;GC.gc(false)
    end
    f=MOI.get(src,MOI.ObjectiveFunction{SPOOL_F}())
    for term in f.terms;cost[term.variable.value]+=term.coefficient;end
    offset=f.constant;f=nothing
    all(isfinite,cost) && isfinite(offset) || error("Nonfinite source objective")
    any(isnan,lo) || any(isnan,hi) ? error("NaN source bound") : nothing
    for (file,data) in (("col_cost",cost),("col_lower",lo),("col_upper",hi),("integrality",integer))
        open(io->write(io,data),joinpath(directory,file*".bin"),"w")
    end
    # Original stable column identities and names are retained out-of-core;
    # they are not materialized as 19M solver-side Julia metadata objects.
    names=SpoolStream(joinpath(directory,"column_names.bin"))
    try
        for i in 1:n
            v=MOI.VariableIndex(i)
            MOI.is_valid(src,v) || error("Non-dense source columns: refusing guessed mapping")
            spool_name(names,i,MOI.get(src,MOI.VariableName(),v))
            i%65536==0 && spool_check_deadline(deadline)
        end
    finally;close(names);end
    on_event("spool_columns_complete",Dict("columns"=>n,"integer_columns"=>count(!iszero,integer)))
    offset,domain_counts
end

function spool_rows!(src,directory;deadline,on_event)
    fields=("row_lower","row_upper","a_start","a_index","a_value","row_names")
    out=Dict(k=>SpoolStream(joinpath(directory,k*".bin")) for k in fields)
    row=0;nnz=0;families=Any[]
    try
        for S in SPOOL_SETS
            ids=MOI.get(src,MOI.ListOfConstraintIndices{SPOOL_F,S}())
            first_row=row+1
            for ci in ids
                # Only ONE row function copy at a time; no fs[], I/J/V whole
                # matrix triplets, constraint-index dictionary, or transpose.
                f=MOI.get(src,MOI.ConstraintFunction(),ci)
                MOI.Utilities.canonicalize!(f)
                l,u=spool_bounds(MOI.get(src,MOI.ConstraintSet(),ci))
                isfinite(f.constant) && !isnan(l) && !isnan(u) || error("Nonfinite source row")
                spool_write(out["row_lower"],l-f.constant)
                spool_write(out["row_upper"],u-f.constant)
                spool_write(out["a_start"],HiGHS.HighsInt(nnz))
                for term in f.terms
                    isfinite(term.coefficient) || error("Nonfinite source coefficient")
                    spool_write(out["a_index"],HiGHS.HighsInt(term.variable.value-1))
                    spool_write(out["a_value"],term.coefficient)
                end
                nnz+=length(f.terms);nnz<=typemax(HiGHS.HighsInt) || error("HiGHS index capacity exceeded")
                spool_name(out["row_names"],ci.value,MOI.get(src,MOI.ConstraintName(),ci))
                row+=1
                if row%65536==0
                    spool_check_deadline(deadline)
                    row%1048576==0 && on_event("spool_rows_progress",Dict("rows_written"=>row,"nonzeros"=>nnz))
                end
            end
            push!(families,Dict("set"=>string(S),"first_row"=>first_row,"count"=>length(ids)))
            ids=nothing;GC.gc(false)
        end
        spool_write(out["a_start"],HiGHS.HighsInt(nnz))
    finally;foreach(close,values(out));end
    row,nnz,families
end

function write_scheduling_spool(model,directory;identity=Dict(),deadline=Inf,on_event=(a,b)->nothing)
    directory=spool_local(directory)
    ispath(directory) && error("Immutable spool directory already exists")
    mode(model)!=DIRECT && termination_status(model)==MOI.OPTIMIZE_NOT_CALLED ||
        error("Only a cold UNSOLVED construction model can be spooled")
    src=backend(model);n=num_variables(model)
    0<n<=typemax(HiGHS.HighsInt) || error("Unsupported column count")
    MOI.get(src,MOI.ObjectiveFunctionType())==SPOOL_F || error("Only affine objective supported")
    objective_sense(model) in (MOI.MIN_SENSE,MOI.MAX_SENSE) || error("Unsupported objective sense")
    for (F,S) in MOI.get(src,MOI.ListOfConstraintTypesPresent())
        ((F==SPOOL_F && S in SPOOL_SETS) ||
         (F==MOI.VariableIndex && (S in SPOOL_SETS || S in (MOI.ZeroOne,MOI.Integer)))) ||
            error("Unsupported source constraint; never omit or bridge: $F in $S")
    end
    MOI.VariablePrimalStart() in MOI.get(src,MOI.ListOfVariableAttributesSet()) &&
        error("Disk-backed route forbids a supplied start")
    scheduling_plain_metadata(model.ext) || error("Spool metadata must not retain model references")
    spool_check_deadline(deadline);mkpath(directory)
    started=time()
    offset,domains=spool_columns!(src,n,directory;deadline=deadline,on_event=on_event)
    GC.gc(true)
    rows,nnz,families=spool_rows!(src,directory;deadline=deadline,on_event=on_event)
    rows==num_constraints(model;count_variable_in_set_constraints=false) || error("Spool omitted rows")
    extraction=Dict(symbol=>spool_map(v->Int32(index(v).value),model[symbol])
        for symbol in SCHEDULING_EXTRACTION_SYMBOLS if haskey(object_dictionary(model),symbol))
    open(io->serialize(io,(ext=model.ext,extraction=extraction)),joinpath(directory,"extraction.bin"),"w")
    record=Dict("schema"=>SPOOL_SCHEMA,"complete"=>true,"cold_unsolved"=>true,
        "builder_pid"=>getpid(),"builder_solve_calls"=>0,"directory"=>directory,
        "identity"=>identity,"julia_version"=>string(VERSION),
        "highs_version"=>string(HiGHS.Highs_versionMajor(),".",HiGHS.Highs_versionMinor(),".",HiGHS.Highs_versionPatch()),
        "highs_int_bytes"=>sizeof(HiGHS.HighsInt),"endianness"=>string(ENDIAN_BOM),
        "variables"=>n,"rows"=>rows,"nonzeros"=>nnz,"row_families"=>families,
        "constraint_inventory"=>scheduling_constraint_inventory(model),"domain_counts"=>domains,
        "sense"=>objective_sense(model)==MOI.MAX_SENSE ? -1 : 1,"objective_offset"=>offset,
        "rows_or_columns_eliminated"=>0,"source_values_changed"=>false,
        "names_policy"=>"Complete original names and stable indices retained in binary sidecars; numeric solver uses positions",
        "files"=>Dict(basename(p)=>Dict("bytes"=>filesize(p),"sha256"=>spool_sha(p))
            for p in readdir(directory;join=true)),"export_seconds"=>time()-started)
    spool_check_deadline(deadline)
    atomic_json(joinpath(directory,"manifest.json"),record)
    on_event("spool_export_complete",Dict("variables"=>n,"rows"=>rows,"nonzeros"=>nnz,
        "export_seconds"=>record["export_seconds"],"bytes"=>sum(v["bytes"] for v in values(record["files"]))))
    record
end

function validate_scheduling_spool(directory;require_exit=true,deadline=Inf)
    directory=spool_local(directory)
    record=JSON.parsefile(joinpath(directory,"manifest.json"))
    (record["schema"]==SPOOL_SCHEMA && record["complete"] && record["cold_unsolved"] &&
        record["builder_solve_calls"]==0 && record["directory"]==directory &&
        record["julia_version"]==string(VERSION) && record["highs_int_bytes"]==sizeof(HiGHS.HighsInt) &&
        record["highs_version"]==string(HiGHS.Highs_versionMajor(),".",HiGHS.Highs_versionMinor(),".",HiGHS.Highs_versionPatch()) &&
        record["endianness"]==string(ENDIAN_BOM)) || error("Incompatible or incomplete spool")
    if require_exit
        exit_record=JSON.parsefile(joinpath(directory,"builder_exit.json"))
        (exit_record["returncode"]==0 && exit_record["pid"]==record["builder_pid"] &&
            exit_record["exited_before_native_launch"]===true &&
            record["builder_pid"]!=getpid() && exit_record["manifest_sha256"]==spool_sha(joinpath(directory,"manifest.json"))) ||
            error("Builder must exit successfully before native load")
    end
    expected=Set([k*".bin" for k in SPOOL_FIELDS] ∪ ["column_names.bin","row_names.bin","extraction.bin"])
    Set(keys(record["files"]))==expected || error("Spool file inventory mismatch")
    for (file,info) in record["files"]
        spool_check_deadline(deadline)
        path=joinpath(directory,file)
        filesize(path)==info["bytes"] && spool_sha(path)==info["sha256"] || error("Spool hash mismatch: $file")
    end
    record
end

function spool_array(directory,field,::Type{T},n) where T
    path=joinpath(directory,field*".bin")
    filesize(path)==sizeof(T)*n || error("Spool array length mismatch: $field")
    n==0 && return T[]
    open(io->Mmap.mmap(io,Vector{T},n),path,"r")::Vector{T}
end

function load_spool_native!(native,directory,record)
    n=record["variables"];m=record["rows"];nnz=record["nonzeros"]
    arrays=[spool_array(directory,k,Float64,n) for k in ("col_cost","col_lower","col_upper")]
    rl=spool_array(directory,"row_lower",Float64,m);ru=spool_array(directory,"row_upper",Float64,m)
    starts=spool_array(directory,"a_start",HiGHS.HighsInt,m+1)
    indices=spool_array(directory,"a_index",HiGHS.HighsInt,nnz)
    values=spool_array(directory,"a_value",Float64,nnz)
    integer=spool_array(directory,"integrality",HiGHS.HighsInt,n)
    starts[1]==0 && starts[end]==nnz && issorted(starts) || error("Invalid CSR offsets")
    all(i->0<=i<n,indices) || error("Invalid CSR column identity")
    ret=HiGHS.Highs_passMip(native,n,m,nnz,HiGHS.kHighsMatrixFormatRowwise,
        record["sense"],record["objective_offset"],arrays...,rl,ru,starts,indices,values,integer)
    ret==HiGHS.kHighsStatusOk || error("Native model load returned $ret; refusing silent changes")
    (HiGHS.Highs_getNumCol(native)==n && HiGHS.Highs_getNumRow(native)==m &&
        HiGHS.Highs_getNumNz(native)==nnz) || error("Native load changed matrix dimensions/nonzeros")
    nothing # mapped arrays can now be unmapped by GC; HiGHS owns its numeric copy
end

# Read-only JuMP result facade, not another optimization model. It lets the
# UNMODIFIED upstream schedule extractor read the native primal by source index.
mutable struct SpoolResult <: MOI.AbstractOptimizer
    primal::Vector{Float64}
    stats::Dict{String,Any}
    options::Dict{String,Any}
end
MOI.is_empty(r::SpoolResult)=isempty(r.stats)
MOI.supports_incremental_interface(::SpoolResult)=true
MOI.get(r::SpoolResult,::MOI.NumberOfVariables)=length(r.primal)
MOI.get(r::SpoolResult,::MOI.TerminationStatus)=r.stats["termination_code"]
MOI.get(r::SpoolResult,::MOI.PrimalStatus)=r.stats["has_primal"] ? MOI.FEASIBLE_POINT : MOI.NO_SOLUTION
MOI.get(r::SpoolResult,::MOI.ResultCount)=r.stats["has_primal"] ? 1 : 0
MOI.get(r::SpoolResult,::MOI.VariablePrimal,v::MOI.VariableIndex)=r.primal[v.value]
MOI.get(r::SpoolResult,a::MOI.RawOptimizerAttribute)=r.options[a.name]
for (Attr,key) in ((MOI.ObjectiveValue,"objective"),(MOI.ObjectiveBound,"bound"),
        (MOI.RelativeGap,"relative_gap"),(MOI.SolveTimeSec,"solve_seconds"),
        (MOI.SimplexIterations,"simplex_iterations"),(MOI.BarrierIterations,"barrier_iterations"),
        (MOI.NodeCount,"nodes"))
    @eval MOI.get(r::SpoolResult,::$Attr)=r.stats[$key]
end

function spool_native_info(native,key,::Type{T}=Float64) where T
    value=Ref{T}()
    ret=T==Float64 ? HiGHS.Highs_getDoubleInfoValue(native,key,value) :
        T==Int64 ? HiGHS.Highs_getInt64InfoValue(native,key,value) : HiGHS.Highs_getIntInfoValue(native,key,value)
    ret==HiGHS.kHighsStatusOk || error("Native info unavailable: $key ($ret)")
    value[]
end

function solve_scheduling_spool(input,directory;optimizer,time_limit,deadline=Inf,
        set_silent=false,include_reserves=true,on_event=(a,b)->nothing,require_exit=true,on_loaded=n->nothing)
    started=time();on_event("disk_handoff_begin",Dict())
    record=validate_scheduling_spool(directory;require_exit=require_exit,deadline=deadline)
    metadata=open(deserialize,joinpath(directory,"extraction.bin"))
    metadata.ext[:scheduling_formulation]["include_reserves"]==include_reserves || error("Reserve contract mismatch")
    native=MOI.instantiate(optimizer)
    try
        load_spool_native!(native,directory,record)
        GC.gc(true)
        on_loaded(native) # tiny-fixture exact native matrix audit
        storage=Dict("policy"=>"disk_backed_native_v1","whole_model_copy"=>true,
            "builder_exited_before_native_load"=>require_exit,"variables"=>record["variables"],
            "rows"=>record["rows"],"nonzeros"=>record["nonzeros"],
            "constraint_inventory"=>record["constraint_inventory"],
            "rows_or_columns_eliminated"=>0,"source_values_changed"=>false,
            "cold_unsolved"=>record["cold_unsolved"],"builder_solve_calls"=>record["builder_solve_calls"],
            "manifest_sha256"=>spool_sha(joinpath(directory,"manifest.json")),
            "names_policy"=>record["names_policy"],"export_seconds"=>record["export_seconds"],
            "load_verify_and_gc_seconds"=>time()-started,"native_julia_per_row_metadata"=>false)
        on_event("disk_handoff_complete",storage)
        spool_check_deadline(deadline-1)
        MOI.set(native,MOI.TimeLimitSec(),min(Float64(time_limit),deadline-time()-1))
        set_silent && MOI.set(native,MOI.Silent(),true)
        options=Dict(k=>MOI.get(native,MOI.RawOptimizerAttribute(k)) for k in
            ("mip_lp_solver","log_dev_level","highs_analysis_level"))
        on_event("economic_solve_begin",Dict("actual_solver_limit_seconds"=>MOI.get(native,MOI.TimeLimitSec())))
        solve_started=time()
        HiGHS.Highs_zeroAllClocks(native)==HiGHS.kHighsStatusOk || error("Native clock reset failed")
        ret=HiGHS.Highs_run(native) # exactly one cold solve; no hidden retry
        on_event("economic_solve_returned",Dict("wall_seconds"=>time()-solve_started,"native_returncode"=>ret))
        status=HiGHS.Highs_getModelStatus(native)
        term=get(Dict(7=>MOI.OPTIMAL,8=>MOI.INFEASIBLE,9=>MOI.INFEASIBLE_OR_UNBOUNDED,
            10=>MOI.DUAL_INFEASIBLE,11=>MOI.OBJECTIVE_LIMIT,12=>MOI.OBJECTIVE_LIMIT,
            13=>MOI.TIME_LIMIT,14=>MOI.ITERATION_LIMIT,16=>MOI.SOLUTION_LIMIT,17=>MOI.INTERRUPTED),Int(status),MOI.OTHER_ERROR)
        ret==HiGHS.kHighsStatusError && error("Native solve error: $status")
        has_primal=spool_native_info(native,"primal_solution_status",HiGHS.HighsInt)==HiGHS.kHighsSolutionStatusFeasible
        primal=has_primal ? Vector{Float64}(undef,record["variables"]) : Float64[]
        if has_primal
            HiGHS.Highs_getSolution(native,primal,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk || error("Native primal extraction failed")
            all(isfinite,primal) || error("Nonfinite native primal")
        end
        stats=Dict{String,Any}("termination_code"=>term,"has_primal"=>has_primal,
            "objective"=>has_primal ? HiGHS.Highs_getObjectiveValue(native) : nothing,
            "bound"=>spool_native_info(native,"mip_dual_bound"),
            "relative_gap"=>spool_native_info(native,"mip_gap"),
            "solve_seconds"=>HiGHS.Highs_getRunTime(native),
            "simplex_iterations"=>spool_native_info(native,"simplex_iteration_count",HiGHS.HighsInt),
            "barrier_iterations"=>spool_native_info(native,"ipm_iteration_count",HiGHS.HighsInt),
            "nodes"=>spool_native_info(native,"mip_node_count",Int64))
        result=SpoolResult(Float64[],Dict{String,Any}(),Dict{String,Any}())
        model=direct_model(result)
        result.primal=primal;result.stats=stats;result.options=options
        merge!(model.ext,metadata.ext);model.ext[:scheduling_storage]=storage
        for (symbol,indices) in metadata.extraction
            model[symbol]=spool_map(i->VariableRef(model,MOI.VariableIndex(Int(i))),indices)
        end
        schedule=has_primal ? GO3._process_schedule_data(input,
            GO3.extract_data_from_scheduling_model(input,model;include_reserves=include_reserves)) : nothing
        model,schedule
    finally
        finalize(native) # release the native model BEFORE any reserve/AC solve
    end
end
