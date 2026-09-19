# Deliberately separate OS process. Exiting releases the construction heap even
# on allocators where GC alone does not return freed pages to Windows.
include(joinpath(@__DIR__,"pilot_worker.jl"))

function build_scheduling_worker(case_path,output,config,deadline)
    get(config,"scheduling_storage_policy","") in ("disk_backed_native_v1","disk_isolated_native_v1") ||
        error("Unregistered storage policy")
    get(config,"scheduling_seed_policy","off")=="off" || error("Only original cold route supported")
    get(config,"scheduling_balance_penalties","")=="source_pq_duration_weighted" || error("Source penalties required")
    dominance=get(config,"scheduling_consumer_dominance","off")
    dominance in ("off","guarded_online_v1") || error("Unknown dominance policy")
    started=time();sequence=0
    function event(name,details)
        sequence+=1
        record=merge(Dict("event"=>name,"elapsed_scheduling_seconds"=>time()-started),details)
        filename=lpad(string(sequence),8,'0')*".json"
        atomic_json(joinpath(output,"statistics","scheduling_events",filename),record)
        atomic_json(joinpath(output,"timing_snapshots","scheduling_events",filename),
            Dict("scheduling_elapsed_to_last_event"=>time()-started,"last_scheduling_event"=>name))
        atomic_json(joinpath(output,"progress",filename),merge(record,
            Dict("stage"=>"scheduling_build","remaining_work_seconds"=>deadline-time())))
        println("GO3_PROGRESS ",JSON.json(record));flush(stdout)
    end
    event("spool_builder_loading",Dict("pid"=>getpid()))
    case=JSON.parsefile(case_path);input=GO3.process_input_data(case)
    loading=time()-started;spool_check_deadline(deadline)
    model=build_source_scheduling(input;include_reserves=get(config,"scheduling_include_reserves",true),
        consumer_dominance=dominance=="guarded_online_v1")
    event("model_built",model.ext[:scheduling_formulation])
    event("native_metadata_release_begin",Dict("variables"=>num_variables(model)))
    cleanup=release_scheduling_construction_metadata!(model)
    event("native_metadata_release_complete",cleanup)
    record=write_scheduling_spool(model,joinpath(output,"scheduling_spool");
        identity=Dict("input_sha256"=>spool_sha(case_path),"config"=>config),
        deadline=deadline,on_event=event)
    atomic_json(joinpath(output,"scheduling_builder.json"),Dict(
        "total_seconds"=>time()-started,"loading_seconds"=>loading,
        "model_build_seconds"=>model.ext[:scheduling_formulation]["build_seconds"],
        "cleanup_seconds"=>cleanup["cleanup_and_gc_seconds"],"export_seconds"=>record["export_seconds"],
        "pid"=>getpid(),"solve_calls"=>0))
    event("spool_builder_exiting",Dict("solve_calls"=>0))
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==4 || error("case output config absolute_work_deadline_epoch required")
    try
        build_scheduling_worker(abspath(ARGS[1]),spool_local(ARGS[2]),JSON.parsefile(ARGS[3]),parse(Float64,ARGS[4]))
    catch e
        atomic_json(joinpath(ARGS[2],"worker_error.json"),Dict("stage"=>"scheduling_spool_builder",
            "error"=>sprint(showerror,e),"backtrace"=>sprint(showerror,e,catch_backtrace())))
        rethrow()
    end
end
