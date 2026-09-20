include(joinpath(@__DIR__,"solve_scheduling_native.jl"))
include(joinpath(@__DIR__,"reserve_benders_partition.jl"))

function run_reserve_partition(original,compact,output,deadline)
    original=spool_local(original);compact=spool_local(compact);output=spool_local(output)
    checked=JSON.parsefile(joinpath(compact,"proof_verification.json"))
    checked["pass"] && checked["complete"] &&
        checked["compact_manifest_sha256"]==spool_sha(joinpath(compact,"manifest.json")) ||
        error("A completed compact-model equivalence proof is required first")
    sequence=0;started=time()
    function event(name,data)
        sequence+=1
        message=merge(Dict("event"=>name,"pid"=>getpid(),"epoch_seconds"=>time(),
            "elapsed_seconds"=>time()-started,"solve_calls"=>0),data)
        atomic_json(joinpath(output,"progress",lpad(string(sequence),8,'0')*".json"),message)
        println("GO3_PROGRESS ",JSON.json(message));flush(stdout)
    end
    event("source_reserve_partition_begin",Dict())
    partition=joinpath(output,"reserve_partition")
    record=partition_reserve_spool(original,compact,partition;deadline=deadline,on_event=event)
    GC.gc(true)
    event("source_reserve_partition_verify_begin",Dict("master_source_columns"=>record["master_source_columns"]))
    audit=verify_reserve_partition(compact,partition;deadline=deadline,on_event=event)
    atomic_json(joinpath(partition,"proof_verification.json"),audit)
    event("source_reserve_partition_verified",audit)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("original compact output absolute_deadline required")
    run_reserve_partition(ARGS[1],ARGS[2],ARGS[3],parse(Float64,ARGS[4]))
end
