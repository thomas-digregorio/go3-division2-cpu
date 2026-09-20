# Native scheduling master and source reserve recourse. The entry point runs
# either master OR recourse in an OS process, never both native heaps together.
using LinearAlgebra

const RB_RESULT_SCHEMA="go3_source_reserve_benders_round_v1"

rb_finite(value)=isfinite(value) ? value : nothing
rb_ref(path)=Dict("path"=>spool_local(path),"sha256"=>spool_sha(path))
function rb_checked_ref(ref)
    path=spool_local(ref["path"])
    spool_sha(path)==ref["sha256"] || error("Benders artifact hash mismatch: $path")
    path
end

function rb_binary(path,values)
    path=spool_local(path);ispath(path) && error("Immutable Benders vector exists")
    mkpath(dirname(path));open(io->write(io,values),path,"w")
    merge(rb_ref(path),Dict("elements"=>length(values),"bytes"=>filesize(path)))
end

function rb_vector(ref,n)
    path=rb_checked_ref(ref)
    ref["elements"]==n && ref["bytes"]==filesize(path)==8*n || error("Benders vector length mismatch")
    spool_array(dirname(path),splitext(basename(path))[1],Float64,n)
end

function rb_context(output,config;deadline=Inf)
    get(config,"scheduling_decomposition_policy","off")==RESERVE_BENDERS_POLICY || error("Unregistered decomposition")
    get(config,"scheduling_storage_policy","")==ISOLATED_STORAGE_POLICY || error("Decomposition requires disjoint native lifetimes")
    get(config,"scheduling_compaction_policy","")==COMPACTION_POLICY || error("Decomposition requires the source equivalence proof")
    get(config,"scheduling_seed_policy","off")=="off" || error("External scheduling starts are forbidden")
    get(config,"scheduling_include_reserves",false)===true || error("Source reserves must remain included")
    output=spool_local(output);original=joinpath(output,"scheduling_spool")
    compact=joinpath(output,"compact_spool");partition=joinpath(output,"reserve_decomposition","reserve_partition")
    source=JSON.parsefile(joinpath(original,"manifest.json"))
    reduced=JSON.parsefile(joinpath(compact,"manifest.json"))
    record=JSON.parsefile(joinpath(partition,"manifest.json"))
    proof=JSON.parsefile(joinpath(partition,"proof_verification.json"))
    compact_proof=JSON.parsefile(joinpath(compact,"proof_verification.json"))
    source["identity"]["config"]==config || error("Benders source configuration mismatch")
    record["schema"]==RB_PARTITION_SCHEMA && record["complete"] && proof["pass"] && proof["complete"] &&
        compact_proof["pass"] && compact_proof["complete"] &&
        proof["partition_manifest_sha256"]==spool_sha(joinpath(partition,"manifest.json")) &&
        record["compact_manifest_sha256"]==compact_proof["compact_manifest_sha256"]==spool_sha(joinpath(compact,"manifest.json")) &&
        record["original_manifest_sha256"]==spool_sha(joinpath(original,"manifest.json")) || error("Benders partition proof identity mismatch")
    for (file,info) in record["mapping_files"]
        p=joinpath(partition,file)
        filesize(p)==info["bytes"] && spool_sha(p)==info["sha256"] || error("Benders source mapping changed")
    end
    master_directory=joinpath(partition,record["parts"]["0"]["directory"])
    spool_sha(joinpath(master_directory,"manifest.json"))==record["parts"]["0"]["manifest_sha256"] || error("Benders master identity mismatch")
    master,ma=rb_load_part(master_directory;deadline=deadline)
    (;output,original,compact,partition,source,reduced,record,master_directory,master,ma,
        identity=Dict("partition_manifest_sha256"=>spool_sha(joinpath(partition,"manifest.json")),
            "source_manifest_sha256"=>spool_sha(joinpath(original,"manifest.json"))))
end

function rb_configure!(native,options,log_path)
    for (key,value) in options
        MOI.set(native,MOI.RawOptimizerAttribute(key),value)
        MOI.get(native,MOI.RawOptimizerAttribute(key))==value || error("Benders native option rejected: $key")
    end
    MOI.set(native,MOI.RawOptimizerAttribute("log_file"),spool_local(log_path))
end

function rb_native_run!(native,deadline,limit,on_event,details)
    seconds=min(Float64(limit),deadline-time()-0.25)
    seconds>0 || error("Benders deadline exhausted before native solve")
    MOI.set(native,MOI.TimeLimitSec(),seconds)
    HiGHS.Highs_zeroAllClocks(native)==HiGHS.kHighsStatusOk || error("Benders native clock reset failed")
    on_event("reserve_benders_solve_begin",merge(details,Dict("actual_limit_seconds"=>seconds)))
    started=time();ret=HiGHS.Highs_run(native)
    status=HiGHS.Highs_getModelStatus(native)
    ret==HiGHS.kHighsStatusError && error("Benders native solve failed: status=$status")
    result=Dict("native_status"=>Int(status),"termination"=>string(isolated_termination(status)),
        "solve_wall_seconds"=>time()-started,"solve_seconds"=>HiGHS.Highs_getRunTime(native),
        "simplex_iterations"=>Int(spool_native_info(native,"simplex_iteration_count",HiGHS.HighsInt)),
        "barrier_iterations"=>Int(spool_native_info(native,"ipm_iteration_count",HiGHS.HighsInt)),
        "has_primal"=>spool_native_info(native,"primal_solution_status",HiGHS.HighsInt)==HiGHS.kHighsSolutionStatusFeasible)
    on_event("reserve_benders_solve_returned",merge(details,result))
    result
end

function rb_cut_row(cut,ctx)
    cut["kind"] in ("cost","feasibility") || error("Unknown reserve cut kind")
    period=Int(cut["period"]);position=findfirst(==(period),ctx.record["periods"])
    position!==nothing && cut["identity"]==ctx.identity && cut["certificate"]["valid_lower_cut"] || error("Cut provenance mismatch")
    ids=Int32.(cut["parameter_ids"]);beta=Float64.(cut["coefficients"])
    length(ids)==length(beta) && issorted(ids) && allunique(ids) &&
        all(j->1<=j<=ctx.master["source_variables"],ids) && all(isfinite,beta) &&
        isfinite(cut["intercept"]) && all(v->v==0 || abs(v)>=1e-8,beta) || error("Malformed or unsafe reserve cut")
    keep=findall(!iszero,beta)
    index=ids[keep].-Int32(1);values= -beta[keep]
    if cut["kind"]=="cost"
        push!(index,Int32(ctx.master["source_variables"]+position-1));push!(values,1.0)
    end
    (;index,values,lower=Float64(cut["intercept"]))
end

function rb_load_cuts(request,ctx)
    cuts=Any[]
    for ref in request["recourse_history"]
        record=JSON.parsefile(rb_checked_ref(ref))
        record["schema"]==RB_RESULT_SCHEMA && record["complete"] && record["mode"]=="recourse" &&
            record["identity"]==ctx.identity || error("Incomplete or foreign recourse history")
        for item in record["cuts"]
            cut=JSON.parsefile(rb_checked_ref(item));rb_cut_row(cut,ctx);push!(cuts,cut)
        end
    end
    cuts
end

function rb_master_round(ctx,config,request,directory;deadline,on_event=(n,d)->nothing)
    cuts=rb_load_cuts(request,ctx);options=isolated_options(config)
    native=HiGHS.Optimizer();started=time();start_record=Dict{String,Any}("supplied"=>false)
    primal=Float64[];stats=nothing;log_path=joinpath(directory,"master.log")
    try
        rb_configure!(native,options,log_path)
        load_spool_native!(native,ctx.master_directory,ctx.master)
        expected_nz=Int(ctx.master["nonzeros"])
        for cut in cuts
            row=rb_cut_row(cut,ctx)
            ret=HiGHS.Highs_addRow(native,row.lower,Inf,length(row.index),row.index,row.values)
            ret==HiGHS.kHighsStatusOk || error("Native reserve cut insertion failed")
            expected_nz+=length(row.index)
        end
        HiGHS.Highs_getNumRow(native)==ctx.master["rows"]+length(cuts) &&
            HiGHS.Highs_getNumNz(native)==expected_nz || error("Native solver changed reserve cuts")
        if request["start"]!==nothing
            previous=JSON.parsefile(rb_checked_ref(request["start"]))
            previous["mode"]=="recourse" && previous["identity"]==ctx.identity &&
                previous["complete"] && previous["all_hours_feasible"] && previous["original_audit"]["pass"] ||
                error("Only a within-attempt, fully audited reserve start is allowed")
            x=rb_vector(previous["master_start"],ctx.master["variables"])
            audit=check_original_spool_point(ctx.master_directory,ctx.master,x;deadline=deadline)
            residual=maximum([0.0;[row.lower-sum(row.values.*x[row.index.+1]) for row in (rb_cut_row(c,ctx) for c in cuts)]])
            audit["pass"] && residual<=1e-8 || error("Prior audited start violates the new master")
            ret=HiGHS.Highs_setSolution(native,x,C_NULL,C_NULL,C_NULL)
            start_record=Dict("supplied"=>true,"scope"=>"complete within-attempt primal; no external seed",
                "source_result"=>request["start"],"api_returncode"=>Int(ret),"api_accepted"=>ret==HiGHS.kHighsStatusOk,
                "original_master_audit"=>audit,"maximum_cut_violation"=>residual)
            ret==HiGHS.kHighsStatusOk || error("HiGHS rejected the complete Benders primal start")
        end
        GC.gc(true)
        on_event("reserve_benders_master_loaded",Dict("variables"=>ctx.master["variables"],
            "rows"=>HiGHS.Highs_getNumRow(native),"nonzeros"=>expected_nz,"cut_count"=>length(cuts),"start"=>start_record))
        stats=rb_native_run!(native,deadline,config["scheduling_benders_master_round_seconds"],on_event,Dict("mode"=>"master"))
        stats["objective"]=stats["has_primal"] ? HiGHS.Highs_getObjectiveValue(native) : nothing
        stats["bound"]=rb_finite(spool_native_info(native,"mip_dual_bound"))
        stats["relative_gap"]=rb_finite(spool_native_info(native,"mip_gap"))
        stats["nodes"]=spool_native_info(native,"mip_node_count",Int64)
        if stats["has_primal"]
            primal=Vector{Float64}(undef,ctx.master["variables"])
            HiGHS.Highs_getSolution(native,primal,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk || error("Master extraction failed")
        end
    finally
        finalize(native)
    end
    start_record["native_log_evidence"]=isfile(log_path) ? filter(line->occursin(r"(?i)user.supplied|mip start|provided.*solution|supplied.*solution",line),readlines(log_path)) : String[]
    # The API acceptance and explicit residual checks are recorded separately
    # from whether the native log reports that it consumed the supplied start.
    start_record["native_consumption_reported"]=!isempty(start_record["native_log_evidence"])
    audit=nothing
    if stats["has_primal"]
        audit=check_original_spool_point(ctx.master_directory,ctx.master,primal;deadline=deadline)
        audit["maximum_cut_violation"]=maximum([0.0;[row.lower-sum(row.values.*primal[row.index.+1]) for row in (rb_cut_row(c,ctx) for c in cuts)]])
        audit["pass"] && audit["maximum_cut_violation"]<=1e-8 || error("Master primal failed original-domain or cut audit")
    end
    Dict("schema"=>RB_RESULT_SCHEMA,"mode"=>"master","complete"=>true,"pid"=>getpid(),
        "identity"=>ctx.identity,"statistics"=>stats,"options"=>options,"start"=>start_record,
        "primal"=>rb_binary(joinpath(directory,"master_primal.bin"),primal),"audit"=>audit,
        "cut_count"=>length(cuts),"solve_calls"=>1,"wall_seconds"=>time()-started)
end

function rb_lp_solve(lp,x,log_path;deadline,limit,on_event,phase_one=false)
    A=lp.A;c=lp.c;Y=lp.y_upper
    if phase_one
        # For each finite lower/upper row add only its own nonnegative elastic
        # variable. Phase I is a certificate oracle, never a repaired schedule.
        rows=Int32[];columns=Int32[];values=Float64[]
        for i in eachindex(lp.lower)
            if isfinite(lp.lower[i]);push!(rows,i);push!(columns,length(columns)+1);push!(values,1.0);end
            if isfinite(lp.upper[i]);push!(rows,i);push!(columns,length(columns)+1);push!(values,-1.0);end
        end
        A=hcat(A,sparse(rows,columns,values,size(A,1),length(columns)))
        c=[zeros(length(lp.c));ones(length(columns))];Y=[lp.y_upper;fill(Inf,length(columns))]
    end
    shift=lp.P*x;lower=lp.lower.-shift;upper=lp.upper.-shift
    native=HiGHS.Optimizer();primal=Float64[];dual=Float64[];stats=nothing
    try
        rb_configure!(native,Dict("threads"=>1,"parallel"=>"off","solver"=>"simplex",
            "primal_feasibility_tolerance"=>1e-9,"dual_feasibility_tolerance"=>1e-9),log_path)
        m,n=size(A)
        ret=HiGHS.Highs_passLp(native,n,m,nnz(A),HiGHS.kHighsMatrixFormatColwise,1,0.0,
            c,zeros(n),Y,lower,upper,Int32.(A.colptr.-1),Int32.(A.rowval.-1),A.nzval)
        ret==HiGHS.kHighsStatusOk && HiGHS.Highs_getNumNz(native)==nnz(A) || error("Reserve LP load changed coefficients")
        stats=rb_native_run!(native,deadline,limit,on_event,Dict("mode"=>phase_one ? "phase_one" : "recourse","period"=>lp.record["period"]))
        if stats["has_primal"]
            primal=Vector{Float64}(undef,n);dual=Vector{Float64}(undef,m)
            HiGHS.Highs_getSolution(native,primal,C_NULL,C_NULL,dual)==HiGHS.kHighsStatusOk || error("Reserve primal/dual extraction failed")
            all(isfinite,primal) && all(isfinite,dual) || error("Nonfinite reserve solution")
            activity=A*primal+shift
            residual=max(0.0,maximum(-primal;init=0.0),maximum(primal.-Y;init=0.0),
                maximum(lp.lower.-activity;init=0.0),maximum(activity.-lp.upper;init=0.0))
            stats["maximum_residual"]=residual;stats["objective"]=dot(c,primal)
            residual<=1e-8 || error("Reserve LP primal violates unchanged original rows")
        end
    finally
        finalize(native)
    end
    (;A,c,Y,primal,dual,statistics=stats)
end

function rb_recourse_round(ctx,config,request,directory;deadline,on_event=(n,d)->nothing)
    started=time();master_path=rb_checked_ref(request["master_result"]);master=JSON.parsefile(master_path)
    master["identity"]==ctx.identity && master["mode"]=="master" && master["complete"] &&
        master["statistics"]["has_primal"] && master["audit"]["pass"] || error("No audited restricted-master point")
    x=rb_vector(master["primal"],ctx.master["variables"]);start=copy(x)
    point=zeros(ctx.reduced["variables"])
    master_ids=spool_array(ctx.master_directory,"source_columns",Int32,ctx.master["source_variables"])
    point[master_ids]=x[1:ctx.master["source_variables"]]
    records=Any[];cuts=Any[];all_feasible=true;solve_calls=0
    for (position,period) in enumerate(ctx.record["periods"])
        spool_check_deadline(deadline)
        part=ctx.record["parts"][string(period)];part_dir=joinpath(ctx.partition,part["directory"])
        spool_sha(joinpath(part_dir,"manifest.json"))==part["manifest_sha256"] || error("Reserve-hour identity changed")
        lp=load_reserve_partition_lp(part_dir;deadline=deadline)
        local_x=x[lp.parameter_ids];hour_dir=joinpath(directory,"hour_"*lpad(string(period),4,'0'));mkpath(hour_dir)
        result=rb_lp_solve(lp,local_x,joinpath(hour_dir,"reserve.log");deadline=deadline,
            limit=config["scheduling_benders_recourse_seconds"],on_event=on_event);solve_calls+=1
        cost_statistics=result.statistics;kind="cost"
        if !result.statistics["has_primal"]
            result.statistics["native_status"]==8 || error("Reserve LP returned no primal before its deadline")
            result=rb_lp_solve(lp,local_x,joinpath(hour_dir,"phase_one.log");deadline=deadline,
                limit=config["scheduling_benders_recourse_seconds"],on_event=on_event,phase_one=true);solve_calls+=1
            result.statistics["has_primal"] || error("Reserve Phase I returned no certificate candidate")
            kind="feasibility";all_feasible=false
        end
        lower=copy(ctx.ma.lo[lp.parameter_ids]);upper=copy(ctx.ma.hi[lp.parameter_ids])
        cut=reserve_benders_cut(result.A,lp.P,result.c,lp.lower,lp.upper,result.Y,lower,upper,result.dual)
        cut=reserve_solver_safe_cut(cut,lower,upper)
        lower_value=reserve_cut_lower_value(cut,local_x)
        lower_value<=result.statistics["objective"]+1e-8 || error("Reserve cut exceeds its generating primal cost")
        kind=="cost" || lower_value>1e-8 || error("Reserve infeasibility was not independently certified; refusing an unsafe cut")
        cut_path=joinpath(hour_dir,"cut.json")
        atomic_json(cut_path,Dict("kind"=>kind,"period"=>period,"identity"=>ctx.identity,
            "parameter_ids"=>lp.parameter_ids,"coefficients"=>cut.coefficients,"intercept"=>cut.intercept,
            "certificate"=>cut.certificate,"generating_lower_value"=>lower_value,
            "generating_master_result"=>request["master_result"],"part_manifest_sha256"=>part["manifest_sha256"],
            "raw_dual"=>rb_binary(joinpath(hour_dir,"raw_dual.bin"),result.dual)))
        push!(cuts,rb_ref(cut_path))
        row=Dict("period"=>period,"kind"=>kind,"statistics"=>result.statistics,
            "ordinary_cost_statistics"=>cost_statistics,"lower_value"=>lower_value,
            "weak_zero_cut"=>cut.certificate["dual_repair"]["zero_fallback"])
        if kind=="cost"
            ids=spool_array(part_dir,"source_columns",Int32,lp.record["variables"])
            point[ids]=result.primal;start[ctx.master["source_variables"]+position]=result.statistics["objective"]
            row["primal"]=rb_binary(joinpath(hour_dir,"primal.bin"),result.primal)
        end
        atomic_json(joinpath(hour_dir,"result.json"),row);push!(records,row)
        on_event("reserve_benders_hour_complete",Dict("period"=>period,"kind"=>kind,
            "hours_completed"=>position,"hours_required"=>length(ctx.record["periods"])))
        lp=nothing;result=nothing;GC.gc(true)
    end
    record=Dict{String,Any}("schema"=>RB_RESULT_SCHEMA,"mode"=>"recourse","complete"=>true,
        "pid"=>getpid(),"identity"=>ctx.identity,"master_result"=>request["master_result"],
        "all_hours_feasible"=>all_feasible,"hours_completed"=>length(records),
        "hours_required"=>length(ctx.record["periods"]),"hours"=>records,"cuts"=>cuts,
        "solve_calls"=>solve_calls,"original_audit"=>nothing,"objective"=>nothing)
    if all_feasible
        compact_audit=check_original_spool_point(ctx.compact,ctx.reduced,point;deadline=deadline)
        compact_audit["pass"] || error("Recomposed reserve schedule failed compact original rows")
        # Re-read and hash-check the complete original arrays, not a subset of
        # reserve constraints, before an incumbent or AC handoff can be saved.
        validate_scheduling_spool(ctx.original;deadline=deadline)
        mapping=spool_array(ctx.compact,"original_to_compact",Int32,ctx.source["variables"])
        source_point=[j==0 ? 0.0 : point[j] for j in mapping]
        audit=check_original_spool_point(ctx.original,ctx.source,source_point;deadline=deadline)
        tolerance=max(1e-6,1e-10*max(1.0,abs(audit["objective"])))
        audit["objective_agreement"]=abs(audit["objective"]-compact_audit["objective"])<=tolerance &&
            abs(audit["objective"]-(ctx.master["objective_offset"]+dot(ctx.ma.cost,start)))<=tolerance
        audit["pass"] && audit["objective_agreement"] || error("Recomposed source schedule failed full original audit")
        record["original_audit"]=audit;record["compact_audit"]=compact_audit;record["objective"]=audit["objective"]
        record["source_primal"]=rb_binary(joinpath(directory,"source_primal.bin"),source_point)
        record["master_start"]=rb_binary(joinpath(directory,"master_start.bin"),start)
        atomic_json(joinpath(directory,"original_audit.json"),audit)
        on_event("reserve_benders_incumbent_audited",Dict("objective"=>audit["objective"],"maximum_residual"=>audit["maximum_residual"]))
    end
    record["wall_seconds"]=time()-started
    record
end
