include(joinpath(@__DIR__,"solve_scheduling_native.jl"))

function run_compaction(original,output,deadline)
    sequence=maximum([0;[parse(Int,splitext(f)[1]) for f in
        (isdir(joinpath(output,"progress")) ? readdir(joinpath(output,"progress")) : String[])
        if occursin(r"^\d+\.json$",f)]])
    function event(name,data)
        sequence+=1;record=merge(Dict("stage"=>"exact_compaction","event"=>name,
            "pid"=>getpid(),"epoch_seconds"=>time(),"remaining_work_seconds"=>deadline-time()),data)
        atomic_json(joinpath(output,"progress",lpad(string(sequence),8,'0')*".json"),record)
        println("GO3_PROGRESS ",JSON.json(record));flush(stdout)
    end
    directory=joinpath(output,"compact_spool")
    event("exact_compaction_begin",Dict())
    record=compact_scheduling_spool(original,directory;deadline=deadline,on_event=event)
    GC.gc(true)
    event("exact_compaction_verify_begin",Dict("variables"=>record["variables"],"rows"=>record["rows"]))
    audit=verify_compaction_proof(original,directory;deadline=deadline,on_event=event)
    atomic_json(joinpath(directory,"proof_verification.json"),audit)
    event("exact_compaction_verified",audit)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==3 || error("original_spool output absolute_deadline required")
    run_compaction(spool_local(ARGS[1]),spool_local(ARGS[2]),parse(Float64,ARGS[3]))
end
