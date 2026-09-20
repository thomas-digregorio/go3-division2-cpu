# Lossless source-row partition of an already proof-checked compact spool.
# No solver, raw-case mutation, saved solution or tolerance-based reduction.
using SparseArrays

const RB_RESERVE_FAMILIES=Set(("p_rgu","p_rgd","p_scr","p_nsc","p_rru_on","p_rrd_on",
    "p_rru_off","p_rrd_off","q_qru","q_qrd","p_rgu_slack","p_rgd_slack","p_scr_slack",
    "p_nsc_slack","p_rru_slack","p_rrd_slack","q_qru_slack","q_qrd_slack","max_prod_in_azone"))
const RB_PARTITION_SCHEMA="go3_source_reserve_partition_v1"

function rb_domain_product(a,b,up)
    (a==0 || b==0) && return 0.0
    b==1 && return a
    b== -1 && return -a
    !isfinite(b) && return a*b
    up ? nextfloat(a*b) : prevfloat(a*b)
end

function rb_domain_add(a,b,up)
    b==0 && return a
    a==0 && return b
    value=a+b
    isnan(value) && error("Indeterminate source-domain activity")
    up ? nextfloat(value) : prevfloat(value)
end

function rb_projected_bounds(a,row,groups)
    # Domain-based redundancy is proved only for the additional implied master
    # projection. Every original row still remains in its source reserve LP.
    nonnegative=true;nonpositive=true;activity_lower=0.0;activity_upper=0.0
    for k in Int(a.start[row])+1:Int(a.start[row+1])
        j=Int(a.index[k])+1;v=a.value[k]
        if groups[j]>0
            nonnegative &= v>=0;nonpositive &= v<=0
        else
            lb=v>0 ? a.lo[j] : a.hi[j];ub=v>0 ? a.hi[j] : a.lo[j]
            activity_lower=rb_domain_add(activity_lower,rb_domain_product(v,lb,false),false)
            activity_upper=rb_domain_add(activity_upper,rb_domain_product(v,ub,true),true)
        end
    end
    lower=nonpositive ? a.rl[row] : -Inf;upper=nonnegative ? a.ru[row] : Inf
    candidate=isfinite(lower) || isfinite(upper)
    activity_lower>=lower && (lower= -Inf)
    activity_upper<=upper && (upper=Inf)
    (;lower,upper,candidate,box_redundant=candidate && !isfinite(lower) && !isfinite(upper))
end

function rb_name_period(name)
    bracket=findfirst('[',name)
    bracket===nothing && return 0
    name[firstindex(name):prevind(name,bracket)] in RB_RESERVE_FAMILIES || return 0
    comma=findlast(',',name)
    comma!==nothing && endswith(name,"]") || error("Unrecognized source reserve name: $name")
    hour=tryparse(Int,name[nextind(name,comma):prevind(name,lastindex(name))])
    hour!==nothing && 1<=hour<=10000 || error("Invalid reserve period: $name")
    hour
end

function rb_classify_columns(original,compact,source,reduced;deadline=Inf)
    n=Int(reduced["variables"]);groups=fill(Int32(-1),n)
    mapping=spool_array(compact,"original_to_compact",Int32,source["variables"])
    names_path=joinpath(original,"column_names.bin");names_info=source["files"]["column_names.bin"]
    filesize(names_path)==names_info["bytes"] && spool_sha(names_path)==names_info["sha256"] ||
        error("Original name provenance mismatch")
    count=0
    open(names_path,"r") do io
        while !eof(io)
            id=Int(read(io,Int64));len=Int(read(io,Int32));count+=1
            id==count && 0<=len<=10000 || error("Original column-name identity mismatch")
            name=String(read(io,len));j=Int(mapping[id]);j==0 && continue
            hour=rb_name_period(name)
            groups[j]=groups[j]==-1 ? Int32(hour) : groups[j]==hour ? groups[j] : Int32(0)
            count%65536==0 && spool_check_deadline(deadline)
        end
    end
    count==source["variables"] && all(groups.>=0) || error("Incomplete reserve column classification")
    groups
end

mutable struct RBPartitionWriter
    directory::String
    streams::Dict{String,SpoolStream}
    rows::Int
    nonzeros::Int
    parameter_nonzeros::Int
end

function RBPartitionWriter(directory)
    mkpath(directory)
    fields=("row_lower","row_upper","a_start","a_index","a_value","source_row",
        "p_start","p_index","p_value")
    RBPartitionWriter(directory,Dict(k=>SpoolStream(joinpath(directory,k*".bin")) for k in fields),0,0,0)
end

function rb_partition_row!(writer,source_row,lower,upper,terms,parameters)
    s=writer.streams
    spool_write(s["source_row"],Int32(source_row))
    spool_write(s["row_lower"],Float64(lower));spool_write(s["row_upper"],Float64(upper))
    spool_write(s["a_start"],Int32(writer.nonzeros))
    spool_write(s["p_start"],Int32(writer.parameter_nonzeros))
    for (j,a) in terms
        spool_write(s["a_index"],Int32(j-1));spool_write(s["a_value"],a);writer.nonzeros+=1
    end
    for (j,a) in parameters
        spool_write(s["p_index"],Int32(j-1));spool_write(s["p_value"],a);writer.parameter_nonzeros+=1
    end
    writer.rows+=1
end

function rb_close_writer!(writer)
    spool_write(writer.streams["a_start"],Int32(writer.nonzeros))
    spool_write(writer.streams["p_start"],Int32(writer.parameter_nonzeros))
    foreach(close,values(writer.streams))
end

function rb_partition_columns!(directory,a,ids;master=false,period_count=0)
    for (field,values) in (("col_cost",a.cost),("col_lower",a.lo),("col_upper",a.hi),("integrality",a.integer))
        selected=copy(values[ids])
        if master
            tail=field=="col_cost" ? fill(-1.0,period_count) :
                 field=="col_upper" ? fill(Inf,period_count) : zeros(eltype(values),period_count)
            append!(selected,tail)
        elseif field=="col_cost"
            selected .*= -1.0 # source welfare max becomes reserve cost min
        end
        open(io->write(io,selected),joinpath(directory,field*".bin"),"w")
    end
    open(io->write(io,Int32.(ids)),joinpath(directory,"source_columns.bin"),"w")
end

function partition_reserve_spool(original,compact,output;deadline=Inf,on_event=(n,d)->nothing)
    original=spool_local(original);compact=spool_local(compact);output=spool_local(output)
    ispath(output) && error("Immutable reserve partition already exists")
    source=JSON.parsefile(joinpath(original,"manifest.json"))
    reduced=validate_compact_spool(original,compact;deadline=deadline)
    reduced["sense"]==-1 || error("Reserve partition currently requires source welfare maximization")
    a=compact_original_arrays(compact,reduced)
    groups=rb_classify_columns(original,compact,source,reduced;deadline=deadline)
    periods=sort!(unique(filter(>(0),groups)))
    isempty(periods) && error("No independently identifiable source reserve periods")
    columns=Dict(g=>Int32[] for g in [Int32(0);periods]);local_index=zeros(Int32,length(groups))
    for j in eachindex(groups)
        g=groups[j]
        if g>0
            a.lo[j]==0 && a.hi[j]>=0 && a.integer[j]==0 && a.cost[j]<=0 ||
                error("Unsupported source recourse domain or signed cost at compact column $j")
        end
        push!(columns[g],Int32(j));local_index[j]=Int32(length(columns[g]))
    end
    mkpath(output)
    writers=Dict(g=>RBPartitionWriter(joinpath(output,g==0 ? "master" : "hour_"*lpad(string(g),4,'0')))
        for g in keys(columns))
    for (g,writer) in writers
        rb_partition_columns!(writer.directory,a,columns[g];master=g==0,period_count=g==0 ? length(periods) : 0)
    end
    on_event("reserve_partition_columns",Dict("master_columns"=>length(columns[Int32(0)]),
        "recourse_columns"=>length(groups)-length(columns[Int32(0)]),"periods"=>Int.(periods)))
    master_terms=Tuple{Int32,Float64}[];recourse_terms=Tuple{Int32,Float64}[]
    projected=0;pure_master=0;box_redundant=0
    try
        for row in 1:Int(reduced["rows"])
            empty!(master_terms);empty!(recourse_terms);group=Int32(0)
            for k in Int(a.start[row])+1:Int(a.start[row+1])
                j=Int(a.index[k])+1;coefficient=a.value[k]
                if groups[j]==0
                    push!(master_terms,(local_index[j],coefficient))
                else
                    group==0 && (group=groups[j])
                    group==groups[j] || error("Source reserve row couples different periods: $row")
                    push!(recourse_terms,(local_index[j],coefficient))
                end
            end
            if group==0
                rb_partition_row!(writers[Int32(0)],row,a.rl[row],a.ru[row],master_terms,())
                pure_master+=1
            else
                rb_partition_row!(writers[group],row,a.rl[row],a.ru[row],recourse_terms,master_terms)
                # These zero-reserve projections are implied by the source row
                # because recourse variables have nonnegative original domains.
                projection=rb_projected_bounds(a,row,groups)
                box_redundant+=projection.box_redundant
                if isfinite(projection.lower) || isfinite(projection.upper)
                    rb_partition_row!(writers[Int32(0)],row,projection.lower,projection.upper,master_terms,())
                    projected+=1
                end
            end
            row%65536==0 && spool_check_deadline(deadline)
            row%1048576==0 && on_event("reserve_partition_rows",Dict("rows_processed"=>row,
                "rows_required"=>Int(reduced["rows"])))
        end
    finally
        foreach(rb_close_writer!,values(writers))
    end
    records=Dict{String,Any}()
    for (g,writer) in writers
        rec=Dict("schema"=>RB_PARTITION_SCHEMA,"complete"=>true,"period"=>Int(g),
            "variables"=>length(columns[g])+(g==0 ? length(periods) : 0),"rows"=>writer.rows,
            "nonzeros"=>writer.nonzeros,"parameter_nonzeros"=>writer.parameter_nonzeros,
            "source_variables"=>length(columns[g]),"sense"=>g==0 ? -1 : 1,
            "objective_offset"=>g==0 ? reduced["objective_offset"] : 0.0,
            "files"=>Dict(basename(p)=>Dict("bytes"=>filesize(p),"sha256"=>spool_sha(p))
                for p in readdir(writer.directory;join=true)))
        atomic_json(joinpath(writer.directory,"manifest.json"),rec)
        records[string(g)]=Dict("directory"=>basename(writer.directory),
            "manifest_sha256"=>spool_sha(joinpath(writer.directory,"manifest.json")))
    end
    open(io->write(io,groups),joinpath(output,"column_group.bin"),"w")
    open(io->write(io,local_index),joinpath(output,"column_local.bin"),"w")
    record=Dict("schema"=>RB_PARTITION_SCHEMA,"complete"=>true,"source_values_changed"=>false,
        "compact_manifest_sha256"=>spool_sha(joinpath(compact,"manifest.json")),
        "original_manifest_sha256"=>spool_sha(joinpath(original,"manifest.json")),
        "periods"=>Int.(periods),"master_source_columns"=>length(columns[Int32(0)]),
        "master_pure_rows"=>pure_master,"master_implied_projection_rows"=>projected,
        "box_redundant_master_projections"=>box_redundant,
        "source_columns"=>length(groups),"source_rows"=>reduced["rows"],"parts"=>records,
        "mapping_files"=>Dict(f=>Dict("bytes"=>filesize(joinpath(output,f)),"sha256"=>spool_sha(joinpath(output,f)))
            for f in ("column_group.bin","column_local.bin")))
    atomic_json(joinpath(output,"manifest.json"),record)
    record
end

function rb_load_part(directory;deadline=Inf)
    directory=spool_local(directory);record=JSON.parsefile(joinpath(directory,"manifest.json"))
    record["schema"]==RB_PARTITION_SCHEMA && record["complete"] || error("Incomplete reserve part")
    for (file,info) in record["files"]
        spool_check_deadline(deadline);path=joinpath(directory,file)
        filesize(path)==info["bytes"] && spool_sha(path)==info["sha256"] || error("Reserve part hash mismatch: $file")
    end
    record,compact_original_arrays(directory,record)
end

function rb_csr_matrix(start,index,value,m,n)
    transposed=SparseMatrixCSC{Float64,Int32}(n,m,start .+ Int32(1),index .+ Int32(1),value)
    copy(transpose(transposed))
end

function load_reserve_partition_lp(directory;deadline=Inf)
    record,a=rb_load_part(directory;deadline=deadline)
    record["period"]>0 && record["sense"]==1 || error("Not a source reserve LP")
    m=Int(record["rows"]);n=Int(record["variables"]);pnz=Int(record["parameter_nonzeros"])
    ps=spool_array(directory,"p_start",Int32,m+1);pi=spool_array(directory,"p_index",Int32,pnz)
    pv=spool_array(directory,"p_value",Float64,pnz)
    parameter_ids=sort!(unique(pi)) .+ Int32(1)
    local_pi=Int32[searchsortedfirst(parameter_ids,j+1)-1 for j in pi]
    A=rb_csr_matrix(a.start,a.index,a.value,m,n)
    P=rb_csr_matrix(ps,local_pi,pv,m,length(parameter_ids))
    (;record,A,P,parameter_ids,c=copy(a.cost),lower=copy(a.rl),upper=copy(a.ru),y_upper=copy(a.hi))
end

function verify_reserve_partition(compact,output;deadline=Inf,on_event=(n,d)->nothing)
    record=JSON.parsefile(joinpath(output,"manifest.json"))
    reduced=JSON.parsefile(joinpath(compact,"manifest.json"));a=compact_original_arrays(compact,reduced)
    record["schema"]==RB_PARTITION_SCHEMA && record["complete"] &&
        record["compact_manifest_sha256"]==spool_sha(joinpath(compact,"manifest.json")) || error("Partition identity mismatch")
    n=Int(reduced["variables"]);m=Int(reduced["rows"])
    for (file,info) in record["mapping_files"]
        path=joinpath(output,file)
        filesize(path)==info["bytes"] && spool_sha(path)==info["sha256"] || error("Partition mapping mismatch")
    end
    groups=spool_array(output,"column_group",Int32,n);local_id=spool_array(output,"column_local",Int32,n)
    coverage=zeros(UInt8,m);columns_seen=falses(n);projections=0;box_redundant=0
    projections_seen=falses(m);projections_expected=falses(m)
    for (key,info) in record["parts"]
        directory=joinpath(output,info["directory"]);g=parse(Int,key)
        spool_sha(joinpath(directory,"manifest.json"))==info["manifest_sha256"] || error("Part identity mismatch")
        part,b=rb_load_part(directory;deadline=deadline)
        part["period"]==g || error("Reserve period changed")
        ids=spool_array(directory,"source_columns",Int32,part["source_variables"])
        for (j,source_j) in enumerate(ids)
            1<=source_j<=n && !columns_seen[source_j] && groups[source_j]==g && local_id[source_j]==j ||
                error("Source column omitted, duplicated or reidentified")
            columns_seen[source_j]=true
            b.lo[j]==a.lo[source_j] && b.hi[j]==a.hi[source_j] && b.integer[j]==a.integer[source_j] &&
                b.cost[j]==(g==0 ? a.cost[source_j] : -a.cost[source_j]) || error("Source domain or cost changed")
            g==0 || (b.lo[j]==0 && b.integer[j]==0 && b.cost[j]>=0) || error("Invalid recourse domain")
        end
        if g==0
            part["variables"]==length(ids)+length(record["periods"]) || error("Missing reserve epigraph")
            part["objective_offset"]==reduced["objective_offset"] && part["sense"]== -1 || error("Master objective changed")
            for j in length(ids)+1:part["variables"]
                b.lo[j]==0 && b.hi[j]==Inf && b.integer[j]==0 && b.cost[j]== -1 || error("Reserve epigraph changed")
            end
        else
            part["variables"]==length(ids) && part["objective_offset"]==0 && part["sense"]==1 || error("Recourse objective changed")
        end
        row_count=Int(part["rows"]);pnz=Int(part["parameter_nonzeros"])
        source_rows=spool_array(directory,"source_row",Int32,row_count)
        ps=spool_array(directory,"p_start",Int32,row_count+1)
        pi=spool_array(directory,"p_index",Int32,pnz)
        pv=spool_array(directory,"p_value",Float64,pnz)
        expected=Dict{Int,Float64}();parameters=Dict{Int,Float64}();others=Float64[]
        for i in 1:row_count
            row=Int(source_rows[i]);1<=row<=m || error("Invalid source row")
            empty!(expected);empty!(parameters);empty!(others)
            for k in Int(a.start[row])+1:Int(a.start[row+1])
                j=Int(a.index[k])+1;v=a.value[k]
                if groups[j]==g
                    expected[Int(local_id[j])]=v
                elseif g>0 && groups[j]==0
                    parameters[Int(local_id[j])]=v
                elseif g==0
                    push!(others,v)
                else
                    error("Recourse row spans multiple periods")
                end
            end
            if isempty(others)
                b.rl[i]==a.rl[row] && b.ru[i]==a.ru[row] || error("Source row bounds changed")
                coverage[row]+=1;coverage[row]==1 || error("Duplicate source row")
                if g>0
                    projection=rb_projected_bounds(a,row,groups)
                    projections_expected[row]=isfinite(projection.lower) || isfinite(projection.upper)
                    box_redundant+=projection.box_redundant
                end
            else
                g==0 || error("Unsupported projection")
                projection=rb_projected_bounds(a,row,groups)
                b.rl[i]==projection.lower && b.ru[i]==projection.upper &&
                    (isfinite(projection.lower) || isfinite(projection.upper)) || error("Invalid implied master row")
                !projections_seen[row] || error("Duplicated master projection")
                projections_seen[row]=true
                projections+=1
            end
            length(expected)==Int(b.start[i+1]-b.start[i]) || error("Source row term missing")
            for k in Int(b.start[i])+1:Int(b.start[i+1])
                j=Int(b.index[k])+1
                pop!(expected,j,NaN)==b.value[k] || error("Source row coefficient changed")
            end
            isempty(expected) || error("Unmapped source row term")
            length(parameters)==Int(ps[i+1]-ps[i]) || error("Parameter term missing")
            for k in Int(ps[i])+1:Int(ps[i+1])
                pop!(parameters,Int(pi[k])+1,NaN)==pv[k] || error("Parameter coefficient changed")
            end
            isempty(parameters) || error("Unmapped parameter term")
            i%65536==0 && spool_check_deadline(deadline)
        end
        on_event("reserve_partition_part_verified",Dict("period"=>g,"rows_checked"=>row_count,
            "columns_checked"=>length(ids)))
    end
    all(columns_seen) && all(coverage.==1) || error("Incomplete source partition coverage")
    projections==record["master_implied_projection_rows"] || error("Projection count mismatch")
    projections_seen==projections_expected || error("Missing implied master projection")
    box_redundant==record["box_redundant_master_projections"] || error("Redundant projection count mismatch")
    Dict("pass"=>true,"complete"=>true,"source_rows_checked"=>m,"source_columns_checked"=>n,
        "source_coefficients_and_bounds_unchanged"=>true,"source_rows_covered_exactly_once"=>true,
        "master_projection_rows_proved"=>projections,"periods"=>record["periods"],
        "box_redundant_master_projections_proved"=>box_redundant,
        "partition_manifest_sha256"=>spool_sha(joinpath(output,"manifest.json")),
        "scope"=>"Exact source scheduling partition; no solved or verified GO3 candidate")
end
