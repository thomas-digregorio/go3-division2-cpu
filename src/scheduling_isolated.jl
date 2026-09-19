# Cold native solve and result-only restoration in disjoint OS processes.
# No raw-case parsing, GOC3Benchmark, Ipopt, or extraction metadata in the solver.
const ISOLATED_STORAGE_POLICY="disk_isolated_native_v1"

function isolated_termination(status)
    get(Dict(7=>MOI.OPTIMAL,8=>MOI.INFEASIBLE,9=>MOI.INFEASIBLE_OR_UNBOUNDED,
        10=>MOI.DUAL_INFEASIBLE,11=>MOI.OBJECTIVE_LIMIT,12=>MOI.OBJECTIVE_LIMIT,
        13=>MOI.TIME_LIMIT,14=>MOI.ITERATION_LIMIT,16=>MOI.SOLUTION_LIMIT,
        17=>MOI.INTERRUPTED),Int(status),MOI.OTHER_ERROR)
end

function isolated_options(config)
    options=Dict{String,Any}("threads"=>get(config,"scheduling_native_threads",config["highs_threads"]),
        "mip_rel_gap"=>config["scheduling_relative_gap"],"mip_feasibility_tolerance"=>1e-9,
        "primal_feasibility_tolerance"=>1e-9,"random_seed"=>0,
        "mip_lp_solver"=>get(config,"scheduling_mip_lp_solver","choose"),
        "log_dev_level"=>get(config,"scheduling_log_dev_level",0),
        "highs_analysis_level"=>get(config,"scheduling_analysis_level",0))
    if haskey(config,"scheduling_native_parallel")
        config["scheduling_native_parallel"] in ("off","choose","on") || error("Invalid native parallel option")
        options["parallel"]=config["scheduling_native_parallel"]
    end
    options
end

function isolated_native_solve(directory,output,config;deadline,diagnostic=false,
        diagnostic_options=Dict(),on_event=(n,d)->nothing)
    directory=spool_local(directory);output=spool_local(output)
    ispath(joinpath(output,"native_result.json")) && error("Native result already exists; no retry")
    get(config,"scheduling_seed_policy","off")=="off" || error("Isolated scheduling must start cold")
    record=validate_scheduling_spool(directory;deadline=deadline)
    record["identity"]["config"]==config || error("Isolated native configuration mismatch")
    diagnostic || get(config,"scheduling_storage_policy","")==ISOLATED_STORAGE_POLICY ||
        error("Unregistered isolated storage policy")
    options=isolated_options(config)
    if !isempty(diagnostic_options)
        diagnostic || error("Diagnostic overrides cannot enter a benchmark")
        all(k->k in ("threads","parallel","highs_analysis_level"),keys(diagnostic_options)) ||
            error("Unapproved diagnostic option override")
        merge!(options,diagnostic_options)
    end
    native=HiGHS.Optimizer()
    started=time()
    try
        for (key,value) in options
            MOI.set(native,MOI.RawOptimizerAttribute(key),value)
            MOI.get(native,MOI.RawOptimizerAttribute(key))==value || error("Native option rejected: $key")
        end
        log_path=spool_local(joinpath(output,"statistics","scheduling_economic_native.log"))
        mkpath(dirname(log_path))
        MOI.set(native,MOI.RawOptimizerAttribute("log_file"),log_path)
        on_event("isolated_native_import_begin",Dict("pid"=>getpid(),"options"=>options,
            "raw_case_parsed"=>false,"extraction_metadata_loaded"=>false))
        load_spool_native!(native,directory,record)
        GC.gc(true)
        import_seconds=time()-started
        on_event("isolated_native_import_complete",Dict("variables"=>record["variables"],
            "rows"=>record["rows"],"nonzeros"=>record["nonzeros"],"seconds"=>import_seconds))
        spool_check_deadline(deadline-1)
        limit=min(Float64(config["scheduling_seconds"]),deadline-time()-1)
        MOI.set(native,MOI.TimeLimitSec(),limit)
        on_event("economic_solve_begin",Dict("actual_solver_limit_seconds"=>limit))
        solve_started=time()
        HiGHS.Highs_zeroAllClocks(native)==HiGHS.kHighsStatusOk || error("Native clock reset failed")
        ret=HiGHS.Highs_run(native) # exactly one call, no starts and no hidden retries
        wall=time()-solve_started
        on_event("economic_solve_returned",Dict("wall_seconds"=>wall,"native_returncode"=>ret))
        status=HiGHS.Highs_getModelStatus(native)
        ret==HiGHS.kHighsStatusError && error("Native solve error: $status")
        has_primal=spool_native_info(native,"primal_solution_status",HiGHS.HighsInt)==HiGHS.kHighsSolutionStatusFeasible
        primal=has_primal ? Vector{Float64}(undef,record["variables"]) : Float64[]
        if has_primal
            HiGHS.Highs_getSolution(native,primal,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk ||
                error("Native primal extraction failed")
            all(isfinite,primal) || error("Nonfinite native primal")
        end
        finite_value(x)=isfinite(x) ? x : nothing
        stats=Dict("native_status"=>Int(status),"termination"=>string(isolated_termination(status)),
            "has_primal"=>has_primal,"objective"=>has_primal ? HiGHS.Highs_getObjectiveValue(native) : nothing,
            "bound"=>finite_value(spool_native_info(native,"mip_dual_bound")),
            "relative_gap"=>finite_value(spool_native_info(native,"mip_gap")),
            "solve_seconds"=>HiGHS.Highs_getRunTime(native),"solve_wall_seconds"=>wall,
            "simplex_iterations"=>spool_native_info(native,"simplex_iteration_count",HiGHS.HighsInt),
            "barrier_iterations"=>spool_native_info(native,"ipm_iteration_count",HiGHS.HighsInt),
            "nodes"=>spool_native_info(native,"mip_node_count",Int64))
        primal_path=joinpath(output,"native_primal.bin")
        ispath(primal_path) && error("Native primal already exists")
        open(io->write(io,primal),primal_path,"w")
        storage=Dict("policy"=>ISOLATED_STORAGE_POLICY,"whole_model_copy"=>true,
            "builder_exited_before_native_load"=>true,"builder_solve_calls"=>0,"cold_unsolved"=>true,
            "variables"=>record["variables"],"rows"=>record["rows"],"nonzeros"=>record["nonzeros"],
            "rows_or_columns_eliminated"=>0,"source_values_changed"=>false,
            "native_julia_per_row_metadata"=>false,"raw_case_parsed_in_native_process"=>false,
            "extraction_metadata_loaded_in_native_process"=>false,"solve_calls"=>1,
            "import_seconds"=>import_seconds,"options"=>options)
        result=Dict("schema"=>"go3_isolated_native_result_v1","complete"=>true,
            "diagnostic_only"=>diagnostic,"pid"=>getpid(),"identity"=>record["identity"],
            "spool_manifest_sha256"=>spool_sha(joinpath(directory,"manifest.json")),
            "primal_sha256"=>spool_sha(primal_path),"primal_bytes"=>filesize(primal_path),
            "statistics"=>stats,"storage"=>storage,"options"=>options)
        atomic_json(joinpath(output,"native_result.json"),result)
        atomic_json(joinpath(output,"statistics","original_economic_mip.json"),stats)
        result
    finally
        finalize(native)
        on_event("isolated_native_destroyed",Dict("pid"=>getpid()))
    end
end

function isolated_result_facade(primal,stats,options)
    facade=SpoolResult(Float64[],Dict{String,Any}(),Dict{String,Any}())
    model=direct_model(facade) # JuMP requires an empty backend at construction.
    facade.primal=primal;facade.stats=stats;facade.options=options
    model
end

function restore_isolated_scheduling(input,directory;include_reserves=true,on_event=(n,d)->nothing)
    directory=spool_local(directory);output=dirname(directory)
    result_path=joinpath(output,"native_result.json")
    result=JSON.parsefile(result_path)
    record=JSON.parsefile(joinpath(directory,"manifest.json"))
    exited=JSON.parsefile(joinpath(output,"native_exit.json"))
    (result["schema"]=="go3_isolated_native_result_v1" && result["complete"] &&
        !result["diagnostic_only"] && result["identity"]==record["identity"] &&
        result["options"]==isolated_options(record["identity"]["config"]) &&
        result["spool_manifest_sha256"]==spool_sha(joinpath(directory,"manifest.json")) &&
        exited["returncode"]==0 && exited["pid"]==result["pid"] && exited["pid"]!=getpid() &&
        exited["exited_before_ac_launch"]===true && exited["result_sha256"]==spool_sha(result_path)) ||
        error("Isolated native result is incomplete, diagnostic, mismatched, or has no successful process exit")
    path=joinpath(output,"native_primal.bin")
    n=result["statistics"]["has_primal"] ? record["variables"] : 0
    (filesize(path)==result["primal_bytes"]==8*n && spool_sha(path)==result["primal_sha256"]) ||
        error("Isolated primal hash/length mismatch")
    primal=Vector{Float64}(undef,n);open(io->read!(io,primal),path,"r")
    all(isfinite,primal) || error("Nonfinite restored primal")
    extraction_path=joinpath(directory,"extraction.bin")
    spool_sha(extraction_path)==record["files"]["extraction.bin"]["sha256"] || error("Extraction identity changed")
    metadata=open(deserialize,extraction_path)
    metadata.ext[:scheduling_formulation]["include_reserves"]==include_reserves || error("Reserve contract mismatch")
    stats=Dict{String,Any}(result["statistics"])
    stats["termination_code"]=isolated_termination(stats["native_status"])
    model=isolated_result_facade(primal,stats,Dict{String,Any}(result["options"]))
    merge!(model.ext,metadata.ext)
    model.ext[:scheduling_storage]=merge(result["storage"],Dict(
        "native_exited_before_ac_load"=>true,"native_process_wall_seconds"=>exited["process_wall_seconds"],
        "native_result_sha256"=>exited["result_sha256"]))
    for (symbol,indices) in metadata.extraction
        model[symbol]=spool_map(i->VariableRef(model,MOI.VariableIndex(Int(i))),indices)
    end
    schedule=stats["has_primal"] ? GO3._process_schedule_data(input,
        GO3.extract_data_from_scheduling_model(input,model;include_reserves=include_reserves)) : nothing
    on_event("isolated_result_restored",Dict("native_exited"=>true,"optimization_calls"=>0))
    model,schedule
end
