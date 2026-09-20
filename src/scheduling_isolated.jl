# Cold native solve and result-only restoration in disjoint OS processes.
# No raw-case parsing, GOC3Benchmark, Ipopt, or extraction metadata in the solver.
const ISOLATED_STORAGE_POLICY="disk_isolated_native_v1"
include(joinpath(@__DIR__,"native_highs_policy.jl"))

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
    presolve_policy=get(config,"scheduling_native_presolve_policy","default")
    presolve_policy in ("default","skip_parallel_rows_cols_v1") || error("Unknown native presolve policy")
    if presolve_policy=="skip_parallel_rows_cols_v1"
        # Pinned HiGHS 1.15.1 rule 13. Disables an optional reduction pass,
        # not constraints, presolve as a whole, or feasibility tolerances.
        options["presolve_rule_off"]=8192
    end
    policy=get(config,"scheduling_native_backend_policy","upstream_jll_v1")
    policy=="upstream_jll_v1" || haskey(NATIVE_GUARD_MANIFESTS,policy) || error("Unknown native backend")
    if haskey(NATIVE_GUARD_MANIFESTS,policy)
        cap=get(config,"scheduling_native_objective_clique_max_size",nothing)
        cap isa Integer && !(cap isa Bool) && 0<=cap<=4096 || error("Invalid objective-clique cap")
        options["mip_objective_clique_max_size"]=cap
    elseif haskey(config,"scheduling_native_objective_clique_max_size")
        error("Objective-clique cap requires the registered native backend")
    end
    if policy==NATIVE_ROOT_MEMORY_POLICY
        get(config,"scheduling_native_analytic_center",nothing)===false ||
            error("Root-memory guard requires analytic center disabled")
        options["mip_compute_analytic_center"]=false
    elseif haskey(config,"scheduling_native_analytic_center")
        error("Analytic-center control requires the root-memory backend")
    end
    options
end

function isolated_native_solve(directory,output,config;deadline,diagnostic=false,
        diagnostic_options=Dict(),on_event=(n,d)->nothing)
    directory=spool_local(directory);output=spool_local(output)
    ispath(joinpath(output,"native_result.json")) && error("Native result already exists; no retry")
    get(config,"scheduling_seed_policy","off")=="off" || error("Isolated scheduling must start cold")
    get(config,"scheduling_decomposition_policy","off")=="off" || error("A decomposed schedule must use its registered coordinator")
    record=validate_scheduling_spool(directory;deadline=deadline)
    record["identity"]["config"]==config || error("Isolated native configuration mismatch")
    diagnostic || get(config,"scheduling_storage_policy","")==ISOLATED_STORAGE_POLICY ||
        error("Unregistered isolated storage policy")
    compaction=get(config,"scheduling_compaction_policy","off")
    overrides=copy(diagnostic_options)
    if haskey(overrides,"compaction_policy")
        diagnostic || error("Diagnostic compaction cannot enter a benchmark")
        compaction=pop!(overrides,"compaction_policy")
    end
    compaction in ("off",COMPACTION_POLICY) || error("Unknown exact compaction policy")
    compact_directory=joinpath(output,"compact_spool")
    compact=nothing
    if compaction!= "off"
        compact=validate_compact_spool(directory,compact_directory;deadline=deadline)
        proof=JSON.parsefile(joinpath(compact_directory,"proof_verification.json"))
        exited=JSON.parsefile(joinpath(output,"compaction_exit.json"))
        (proof["pass"] && proof["complete"] &&
            proof["compact_manifest_sha256"]==spool_sha(joinpath(compact_directory,"manifest.json")) &&
            exited["returncode"]==0 && exited["exited_before_native_launch"]===true &&
            exited["proof_sha256"]==spool_sha(joinpath(compact_directory,"proof_verification.json"))) ||
            error("Compactor must exit after complete original-model proof verification")
    end
    options=isolated_options(config)
    if !isempty(overrides)
        diagnostic || error("Diagnostic overrides cannot enter a benchmark")
        all(k->k in ("threads","parallel","highs_analysis_level"),keys(overrides)) ||
            error("Unapproved diagnostic option override")
        merge!(options,overrides)
    end
    native=HiGHS.Optimizer()
    released=false
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
        loaded=compact===nothing ? record : compact
        load_spool_native!(native,compact===nothing ? directory : compact_directory,loaded)
        GC.gc(true)
        import_seconds=time()-started
        on_event("isolated_native_import_complete",Dict("variables"=>loaded["variables"],
            "rows"=>loaded["rows"],"nonzeros"=>loaded["nonzeros"],"seconds"=>import_seconds))
        reserve=compact===nothing ? 1 : 15
        spool_check_deadline(deadline-reserve)
        limit=min(Float64(config["scheduling_seconds"]),deadline-time()-reserve)
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
        primal=has_primal ? Vector{Float64}(undef,loaded["variables"]) : Float64[]
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
        finalize(native);released=true
        on_event("native_model_released",Dict("pid"=>getpid()))
        original_audit=nothing
        if compact!==nothing && has_primal
            mapping=spool_array(compact_directory,"original_to_compact",Int32,record["variables"])
            primal=[j==0 ? 0.0 : primal[j] for j in mapping]
            original_audit=check_original_spool_point(directory,record,primal;deadline=deadline)
            original_audit["objective_agreement"]=abs(original_audit["objective"]-stats["objective"])<=
                max(1e-6,1e-10*max(1.0,abs(stats["objective"])))
            atomic_json(joinpath(output,"original_scheduling_audit.json"),original_audit)
        end
        primal_path=joinpath(output,"native_primal.bin")
        ispath(primal_path) && error("Native primal already exists")
        open(io->write(io,primal),primal_path,"w")
        storage=Dict("policy"=>ISOLATED_STORAGE_POLICY,"whole_model_copy"=>compact===nothing,
            "builder_exited_before_native_load"=>true,"builder_solve_calls"=>0,"cold_unsolved"=>true,
            "variables"=>record["variables"],"rows"=>record["rows"],"nonzeros"=>record["nonzeros"],
            "rows_or_columns_eliminated"=>record["variables"]+record["rows"]-loaded["variables"]-loaded["rows"],
            "source_values_changed"=>false,"compaction_policy"=>compaction,
            "native_variables"=>loaded["variables"],"native_rows"=>loaded["rows"],"native_nonzeros"=>loaded["nonzeros"],
            "original_scheduling_audit"=>original_audit,
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
        if original_audit!==nothing
            original_audit["pass"] && original_audit["objective_agreement"] ||
                error("Native primal failed the unchanged original scheduling model audit")
        end
        result
    finally
        released || finalize(native)
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
    audit=get(result["storage"],"original_scheduling_audit",nothing)
    decomposition=get(record["identity"]["config"],"scheduling_decomposition_policy","off")
    if decomposition!="off"
        decomposition=="source_reserve_benders_v1" && result["storage"]["decomposition_policy"]==decomposition ||
            error("Unknown or mismatched scheduling decomposition")
        ref=result["storage"]["decomposition_summary"]
        spool_sha(spool_local(ref["path"]))==ref["sha256"] || error("Decomposition summary identity mismatch")
        summary=JSON.parsefile(ref["path"])
        summary["complete"] && summary["incumbent"]!==nothing &&
            summary["identity"]["source_manifest_sha256"]==result["spool_manifest_sha256"] &&
            summary["objective"]==result["statistics"]["objective"] &&
            summary["native_master_and_recourse_processes_never_overlap"] || error("Incomplete decomposition evidence")
    end
    if get(record["identity"]["config"],"scheduling_compaction_policy","off")!= "off"
        audit!==nothing && audit["complete"] && audit["pass"] && audit["objective_agreement"] ||
            error("Compacted primal has no passing original-model audit")
    end
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
