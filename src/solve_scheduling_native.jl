# This entry point deliberately does not include pilot_worker or GOC3Benchmark.
using HiGHS, JuMP, JSON
const MOI=JuMP.MOI
include(joinpath(@__DIR__,"scheduling_spool.jl"))
include(joinpath(@__DIR__,"scheduling_isolated.jl"))

function atomic_json(path,object)
    path=spool_local(path);ispath(path) && error("Immutable artifact exists: $path")
    mkpath(dirname(path));temp=path*".pending"
    open(io->JSON.print(io,object),temp,"w");mv(temp,path)
end

function run_native(case_path,output,config_path,deadline;diagnostic_spool=nothing,diagnostic_options=Dict())
    any(m->nameof(m) in (:GOC3Benchmark,:Ipopt),values(Base.loaded_modules)) &&
        error("Native process must not import network/AC packages")
    output=spool_local(output);config=JSON.parsefile(spool_local(config_path))
    directory=diagnostic_spool===nothing ? joinpath(output,"scheduling_spool") : spool_local(diagnostic_spool)
    manifest=JSON.parsefile(joinpath(directory,"manifest.json"))
    manifest["identity"]["input_sha256"]==spool_sha(spool_local(case_path)) || error("Source identity mismatch")
    sequence=maximum([0;[parse(Int,splitext(f)[1]) for f in
        (isdir(joinpath(output,"progress")) ? readdir(joinpath(output,"progress")) : String[])
        if occursin(r"^\d+\.json$",f)]])
    started=time()
    function event(name,details)
        sequence+=1;file=lpad(string(sequence),8,'0')*".json"
        message=merge(Dict("event"=>name,"stage"=>"isolated_native_scheduling","pid"=>getpid(),
            "epoch_seconds"=>time(),"elapsed_native_worker_seconds"=>time()-started,
            "remaining_work_seconds"=>deadline-time()),details)
        atomic_json(joinpath(output,"progress",file),message)
        atomic_json(joinpath(output,"statistics","scheduling_events",file),message)
        println("GO3_PROGRESS ",JSON.json(message));flush(stdout)
    end
    event("isolated_native_worker_started",Dict("raw_case_parsed"=>false))
    isolated_native_solve(directory,output,config;deadline=deadline,
        diagnostic=diagnostic_spool!==nothing,diagnostic_options=diagnostic_options,on_event=event)
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS) in (4,5,6) || error("case output config absolute_deadline [diagnostic_spool [diagnostic_options]] required")
    try
        run_native(ARGS[1],ARGS[2],ARGS[3],parse(Float64,ARGS[4]);
            diagnostic_spool=length(ARGS)>=5 ? ARGS[5] : nothing,
            diagnostic_options=length(ARGS)==6 ? JSON.parsefile(spool_local(ARGS[6])) : Dict())
    catch e
        atomic_json(joinpath(ARGS[2],"worker_error.json"),Dict("stage"=>"isolated_native_scheduling",
            "error"=>sprint(showerror,e),"backtrace"=>sprint(showerror,e,catch_backtrace())))
        rethrow()
    end
end
