include(joinpath(@__DIR__,"solve_scheduling_native.jl"))
include(joinpath(@__DIR__,"reserve_benders_partition.jl"))
include(joinpath(@__DIR__,"reserve_benders_certificate.jl"))
include(joinpath(@__DIR__,"reserve_benders_runtime.jl"))
include(joinpath(@__DIR__,"reserve_benders_primal.jl"))

function run_benders_stage(output,config_path,request_path,directory,deadline)
    output=spool_local(output);directory=spool_local(directory)
    ispath(joinpath(directory,"result.json")) && error("A completed Benders stage cannot be rerun")
    mkpath(directory);config=JSON.parsefile(spool_local(config_path));request=JSON.parsefile(spool_local(request_path))
    ctx=rb_context(output,config;deadline=deadline)
    request["identity"]==ctx.identity || error("Benders request identity mismatch")
    sequence=maximum([0;[parse(Int,splitext(f)[1]) for f in
        (isdir(joinpath(output,"progress")) ? readdir(joinpath(output,"progress")) : String[])
        if occursin(r"^\d+\.json$",f)]])
    function event(name,details)
        sequence+=1
        record=merge(Dict("event"=>name,"stage"=>"source_reserve_benders","mode"=>request["mode"],
            "round"=>request["round"],"pid"=>getpid(),"epoch_seconds"=>time(),"remaining_work_seconds"=>deadline-time()),details)
        atomic_json(joinpath(output,"progress",lpad(string(sequence),8,'0')*".json"),record)
        println("GO3_PROGRESS ",JSON.json(record));flush(stdout)
    end
    native_backend=native_highs_identity(config)
    event("reserve_benders_worker_started",Dict("raw_case_parsed"=>false,"native_backend"=>native_backend))
    result=if request["mode"]=="master"
        policy=get(config,"scheduling_benders_primal_policy","off")
        policy in ("off",RB_COLD_PRIMAL_POLICY) || error("Unknown Benders primal policy")
        policy=="off" ? rb_master_round(ctx,config,request,directory;deadline=deadline,on_event=event) :
            rb_cold_master_round(ctx,config,request,directory;deadline=deadline,on_event=event)
    elseif request["mode"]=="recourse"
        rb_recourse_round(ctx,config,request,directory;deadline=deadline,on_event=event)
    else
        error("Unknown Benders stage")
    end
    result["request_sha256"]=spool_sha(request_path)
    result["native_backend"]=native_backend
    atomic_json(joinpath(directory,"result.json"),result)
    event("reserve_benders_stage_complete",Dict("result_sha256"=>spool_sha(joinpath(directory,"result.json"))))
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==5 || error("output config request stage_directory absolute_deadline required")
    run_benders_stage(ARGS[1],ARGS[2],ARGS[3],ARGS[4],parse(Float64,ARGS[5]))
end
