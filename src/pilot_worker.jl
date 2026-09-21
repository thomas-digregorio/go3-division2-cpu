# Project-owned orchestration of the unmodified, pinned LANL model functions.
using GOC3Benchmark, JuMP, HiGHS, Ipopt, JSON, LinearAlgebra
const GO3 = GOC3Benchmark
const MOI = JuMP.MOI
LinearAlgebra.BLAS.set_num_threads(1)
include(joinpath(@__DIR__,"consumer_dominance.jl"))
include(joinpath(@__DIR__,"startup_windows.jl"))
include(joinpath(@__DIR__,"scheduling_seed.jl"))
include(joinpath(@__DIR__,"scheduling_storage.jl"))
include(joinpath(@__DIR__,"scheduling_spool.jl"))
include(joinpath(@__DIR__,"scheduling_compaction.jl"))
include(joinpath(@__DIR__,"scheduling_isolated.jl"))
include(joinpath(@__DIR__,"scheduling.jl"))
include(joinpath(@__DIR__,"ac_primal_start.jl"))
include(joinpath(@__DIR__,"ac_interval_start.jl"))
include(joinpath(@__DIR__,"ac_ramp_bounds.jl"))
include(joinpath(@__DIR__,"ac_recovery.jl"))
include(joinpath(@__DIR__,"ac_primal_guard.jl"))
include(joinpath(@__DIR__,"ac_numerics.jl"))
include(joinpath(@__DIR__,"reserve_ac.jl"))
include(joinpath(@__DIR__,"reserve_storage.jl"))
include(joinpath(@__DIR__,"ac_correction.jl"))
include(joinpath(@__DIR__,"ac_correction_pipeline.jl"))

function atomic_json(path, object)
    occursin("onedrive", lowercase(abspath(path))) && error("OneDrive output forbidden")
    isfile(path) && error("Refusing to replace an immutable artifact: $path")
    mkpath(dirname(path))
    temp = path * ".pending"
    open(io -> JSON.print(io, object), temp, "w")
    mv(temp, path)
end

function safe_stat(f)
    try
        value = f()
        value isa Real && !isfinite(value) && return nothing
        return value
    catch
        return nothing
    end
end

function model_stats(model;include_bound_and_gap=true)
    has_primal = primal_status(model)==FEASIBLE_POINT
    Dict("termination" => string(termination_status(model)),
         "primal_status" => string(primal_status(model)),
         "objective" => has_primal ? safe_stat(() -> objective_value(model)) : nothing,
         "bound" => include_bound_and_gap ? safe_stat(() -> objective_bound(model)) : nothing,
         "relative_gap" => include_bound_and_gap && has_primal ? safe_stat(() -> relative_gap(model)) : nothing,
         "native_relative_gap" => include_bound_and_gap ? safe_stat(() -> relative_gap(model)) : nothing,
         "bound_and_gap_queried"=>include_bound_and_gap,
         "solve_seconds" => safe_stat(() -> solve_time(model)),
         "simplex_iterations" => safe_stat(() -> MOI.get(model, MOI.SimplexIterations())),
         "barrier_iterations" => safe_stat(() -> MOI.get(model, MOI.BarrierIterations())),
         "nodes" => safe_stat(() -> MOI.get(model, MOI.NodeCount())))
end

function put_reserves!(solution, awards)
    mapping = ["p_reg_res_up"=>:p_rgu, "p_reg_res_down"=>:p_rgd,
               "p_syn_res"=>:p_scr, "p_nsyn_res"=>:p_nsc,
               "p_ramp_res_up_online"=>:p_rru_on, "p_ramp_res_down_online"=>:p_rrd_on,
               "p_ramp_res_up_offline"=>:p_rru_off, "p_ramp_res_down_offline"=>:p_rrd_off,
               "q_res_up"=>:q_qru, "q_res_down"=>:q_qrd]
    for sdd in solution["time_series_output"]["simple_dispatchable_device"]
        for (field, symbol) in mapping
            sdd[field] = getproperty(awards, symbol)[sdd["uid"]]
        end
    end
end

function force_source_topology!(solution, input)
    # An explicit candidate-search restriction, not a change to official domains.
    nt = length(input.periods)
    for (section, lookup) in (("ac_line",input.ac_line_lookup), ("two_winding_transformer",input.twt_lookup))
        for branch in solution["time_series_output"][section]
            prior = lookup[branch["uid"]]["initial_status"]
            branch["on_status"] = fill(prior["on_status"],nt)
            if section == "two_winding_transformer"
                branch["tm"] = fill(prior["tm"],nt)
                branch["ta"] = fill(prior["ta"],nt)
            end
        end
    end
end

function candidate_from_schedule(input, schedule)
    solution = GO3.construct_solution_dict(input, schedule; include_reserves=false,
                                            postprocess=true, print_projected_devices=false)
    force_source_topology!(solution,input)
    # Source initial voltages are allowed; no saved optimized solution is read.
    for b in solution["time_series_output"]["bus"]
        source = input.bus_lookup[b["uid"]]
        b["vm"] = fill(source["initial_status"]["vm"],length(input.periods))
        b["va"] = fill(source["initial_status"]["va"],length(input.periods))
    end
    # A cold candidate uses source initial terminal flows, not an imported
    # optimized point. AC refinement keeps each DC link freely controllable.
    for link in solution["time_series_output"]["dc_line"]
        prior = input.dc_line_lookup[link["uid"]]["initial_status"]
        for field in ("pdc_fr", "qdc_fr", "qdc_to")
            link[field] = fill(prior[field],length(input.periods))
        end
    end
    solution
end

function opf_view(solution, periods)
    [Dict(section => Dict(d["uid"] => Dict(k=>v[i] for (k,v) in d if k!="uid")
                          for d in records) for (section,records) in solution["time_series_output"])
     for i in periods]
end

function checkpoint_ac_interval!(output,input,schedule,results,i;must_stop=false,
        ramp_policy="legacy_tolerance_v1")
    partial,audit=construct_audited_ac_solution(input,schedule,results,i;policy=ramp_policy)
    force_source_topology!(partial,input)
    path=joinpath(output,"checkpoints","candidate_ac_"*lpad(string(i),4,'0')*".json")
    atomic_json(path,partial)
    atomic_json(joinpath(output,"statistics","export_projection_"*lpad(string(i),4,'0')*".json"),audit)
    require_ac_export_projection(audit)
    # Save the diagnostic point BEFORE signalling failure. The controller can
    # independently verify it and keep a better already-verified incumbent.
    must_stop && error("AC interval $i failed the explicit $(AC_POINT_RESIDUAL_TOLERANCE) primal residual screen; checkpoint saved; no later intervals attempted")
    path
end

function run_worker(case_path, output, config, work_deadline)
    started = time()
    timings, statistics = Dict{String,Any}(), Dict{String,Any}()
    progress_sequence=maximum([0;[parse(Int,splitext(f)[1]) for f in
        (isdir(joinpath(output,"progress")) ? readdir(joinpath(output,"progress")) : String[])
        if occursin(r"^\d+\.json$",f)]])
    function progress(stage; extra=Dict())
        progress_sequence+=1
        message = merge(Dict("stage"=>stage, "elapsed_worker_seconds"=>time()-started,
                             "remaining_work_seconds"=>work_deadline-time()), extra)
        atomic_json(joinpath(output,"progress",lpad(string(progress_sequence),8,'0')*".json"),message)
        println("GO3_PROGRESS ", JSON.json(message)); flush(stdout)
    end
    function available(cap)
        remain = work_deadline-time()
        remain > 2 || error("Work deadline exhausted")
        min(Float64(cap),remain-1)
    end
    progress("loading")
    case = JSON.parsefile(case_path)
    input = GO3.process_input_data(case)
    timings["loading_and_preprocessing"] = time()-started
    isolated_scheduling=get(config,"scheduling_storage_policy","")=="disk_isolated_native_v1"
    disk_scheduling=get(config,"scheduling_storage_policy","cached_model_v1") in
        ("disk_backed_native_v1","disk_isolated_native_v1")
    spool_path=joinpath(output,"scheduling_spool")
    if disk_scheduling
        spool=JSON.parsefile(joinpath(spool_path,"manifest.json"))
        spool["identity"]["input_sha256"]==spool_sha(case_path) && spool["identity"]["config"]==config ||
            error("Disk scheduling source/config identity mismatch")
        timings["scheduling_builder"]=JSON.parsefile(joinpath(output,"scheduling_builder.json"))
        timings["scheduling_builder"]["process_wall_seconds"]=
            JSON.parsefile(joinpath(spool_path,"builder_exit.json"))["process_wall_seconds"]
    end
    ac_reserve_policy=get(config,"ac_reserve_policy","off")
    ac_reserve_policy in ("off","source_joint_reserves_in_ac_v1") || error("Unknown AC reserve policy")
    ac_shunt_primal_start=get(config,"ac_shunt_primal_start","off")
    ac_shunt_primal_start in ("off","within_interval_complete_v1","within_interval_primal_dual_v1") ||
        error("Unknown shunt start policy")
    ac_fail_fast=get(config,"ac_fail_fast_on_infeasible",false)
    ac_fail_fast isa Bool || error("AC fail-fast option must be Boolean")
    (ac_shunt_primal_start=="off" && !ac_fail_fast) ||
        ac_reserve_policy=="source_joint_reserves_in_ac_v1" ||
        error("Explicit AC starts/audits require the reserve-aware adapter")
    ac_interval_start=get(config,"ac_interval_primal_start","off")
    ac_interval_start in ("off","previous_screened_interval_v1") || error("Unknown AC interval start policy")
    ac_interval_start=="off" || (ac_reserve_policy=="source_joint_reserves_in_ac_v1" && ac_fail_fast) ||
        error("AC interval continuation requires the reserve-aware adapter and local residual checks")
    ac_ramp_policy=get(config,"ac_ramp_bound_policy","legacy_tolerance_v1")
    ramp_tolerance=ac_ramp_bound_tolerance(ac_ramp_policy)
    statistics["ac_ramp_bounds"]=Dict("policy"=>ac_ramp_policy,
        "bookkeeping_tolerance"=>ramp_tolerance,"source_bounds_changed"=>false,
        "official_tolerance_changed"=>false)
    reserve_storage_policy=get(config,"reserve_storage_policy","legacy_horizon_v1")
    reserve_storage_policy in RESERVE_STORAGE_POLICIES || error("Unknown reserve storage policy")
    ac_recovery=get(config,"ac_numerical_recovery","off")
    ac_recovery in ("off","adaptive_barrier_on_failed_residual_v1") || error("Unknown AC recovery policy")
    ac_recovery=="off" || (ac_reserve_policy=="source_joint_reserves_in_ac_v1" && ac_fail_fast) ||
        error("AC numerical recovery requires the reserve-aware adapter and local residual checks")
    ac_guard=get(config,"ac_primal_guard","off")
    ac_guard in ("off",AC_PRIMAL_GUARD_POLICY) || error("Unknown AC primal guard policy")
    ac_guard=="off" || (ac_reserve_policy=="source_joint_reserves_in_ac_v1" && ac_fail_fast) ||
        error("AC primal guard requires the reserve-aware adapter and local residual checks")
    ac_correction=get(config,"ac_correction_policy","off")
    ac_numerics=get(config,"ac_numerics_policy","legacy_v1")
    ac_numerics in ("legacy_v1",AC_NUMERICS_POLICY) || error("Unknown AC numerics policy")
    ac_numerics=="legacy_v1" || (ac_reserve_policy=="source_joint_reserves_in_ac_v1" &&
        ac_fail_fast && ac_correction=="off") || error("Explicit AC numerics requires audited reserve-aware AC")
    (ac_correction=="off" || ac_correction in AC_CORRECTION_POLICIES) || error("Unknown network correction policy")
    ac_correction=="off" || (ac_reserve_policy=="source_joint_reserves_in_ac_v1" && ac_fail_fast) ||
        error("Network corrections require the full reserve-aware AC model and residual screen")

    progress("scheduling")
    stage = time()
    scheduling_event_sequence=maximum([0;[parse(Int,splitext(f)[1]) for f in
        (isdir(joinpath(output,"statistics","scheduling_events")) ?
         readdir(joinpath(output,"statistics","scheduling_events")) : String[])
        if occursin(r"^\d+\.json$",f)]])
    function scheduling_event(name,details)
        scheduling_event_sequence+=1
        event=merge(Dict("event"=>name,"elapsed_scheduling_seconds"=>time()-stage),details)
        atomic_json(joinpath(output,"statistics","scheduling_events",
            lpad(string(scheduling_event_sequence),8,'0')*".json"),event)
        atomic_json(joinpath(output,"timing_snapshots","scheduling_events",
            lpad(string(scheduling_event_sequence),8,'0')*".json"),
            merge(timings,Dict("scheduling_elapsed_to_last_event"=>time()-stage,
                              "last_scheduling_event"=>name)))
        progress("scheduling_event";extra=event)
    end
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "threads"=>config["highs_threads"],
        "mip_rel_gap"=>config["scheduling_relative_gap"], "mip_feasibility_tolerance"=>1e-9,
        "primal_feasibility_tolerance"=>1e-9, "random_seed"=>0,
        "mip_lp_solver"=>get(config,"scheduling_mip_lp_solver","choose"),
        "log_dev_level"=>get(config,"scheduling_log_dev_level",0),
        "highs_analysis_level"=>get(config,"scheduling_analysis_level",0))
    get(config,"scheduling_balance_penalties","")=="source_pq_duration_weighted" || error("Missing registered scheduling penalty policy")
    dominance_policy=get(config,"scheduling_consumer_dominance","off")
    dominance_policy in ("off","guarded_online_v1") || error("Unknown consumer dominance policy")
    model, schedule = schedule_source_balances(input; optimizer=optimizer,
        time_limit=available(config["scheduling_seconds"]),
        include_reserves=get(config,"scheduling_include_reserves",true),
        consumer_dominance=dominance_policy=="guarded_online_v1",
        seed_policy=get(config,"scheduling_seed_policy","off"),
        storage_policy=get(config,"scheduling_storage_policy","cached_model_v1"),
        spool_path=disk_scheduling ? spool_path : nothing,
        construction_seconds=get(config,"scheduling_construction_seconds",0),
        cost_seconds=get(config,"scheduling_constructed_cost_seconds",0),
        cost_lp_solver=get(config,"scheduling_constructed_cost_lp_solver","simplex"),
        deadline=work_deadline,
        on_event=scheduling_event,
        native_log_path=joinpath(output,"statistics","scheduling_economic_native.log"),
        on_phase=record->begin
            atomic_json(joinpath(output,"statistics",record["phase"]*".json"),record)
            progress("scheduling_phase_complete";extra=Dict("phase"=>record["phase"],
                "primal_status"=>record["primal_status"]))
        end,
        on_seed=(schedule,audit,label)->begin
            atomic_json(joinpath(output,"scheduling_seeds",label*".json"),
                Dict("source"=>"constructed_within_this_cold_attempt","schedule"=>schedule,"audit"=>audit))
            scheduling_event("scheduling_seed_checkpoint_saved",Dict("label"=>label))
        end)
    statistics["scheduling"] = model_stats(model)
    if haskey(model.ext,:selected_schedule_audit)
        statistics["scheduling"]["native_economic_mip_statistics"]=copy(statistics["scheduling"])
        selected=model.ext[:selected_schedule_audit]
        statistics["scheduling"]["selected_schedule"]=selected
        statistics["scheduling"]["objective"]=selected["objective"]
        statistics["scheduling"]["primal_status"]="VERIFIED_ORIGINAL_SCHEDULING_POINT"
        bound=statistics["scheduling"]["bound"]
        statistics["scheduling"]["relative_gap"]=bound===nothing || bound<selected["objective"]-1e-6 ?
            nothing : max(0.0,bound-selected["objective"])/max(abs(selected["objective"]),1e-10)
    end
    merge!(statistics["scheduling"],model.ext[:scheduling_formulation])
    statistics["scheduling"]["storage"]=get(model.ext,:scheduling_storage,
        Dict("policy"=>"cached_model_v1"))
    statistics["scheduling"]["mip_lp_solver_requested"]=get(config,"scheduling_mip_lp_solver","choose")
    statistics["scheduling"]["mip_lp_solver_option"]=get_optimizer_attribute(model,"mip_lp_solver")
    statistics["scheduling"]["log_dev_level"]=get_optimizer_attribute(model,"log_dev_level")
    statistics["scheduling"]["highs_analysis_level"]=get_optimizer_attribute(model,"highs_analysis_level")
    statistics["scheduling"]["bound_scope"] = "approximate_copperplate_subproblem_only_not_full_GO3"
    timings["scheduling"] = time()-stage
    if disk_scheduling
        timings["scheduling_native_phase"]=timings["scheduling"]
        timings["scheduling"]+=timings["scheduling_builder"]["process_wall_seconds"]
        if isolated_scheduling
            timings["scheduling_result_restore"]=timings["scheduling_native_phase"]
            timings["scheduling_native_phase"]=JSON.parsefile(joinpath(output,"native_exit.json"))["process_wall_seconds"]
            timings["scheduling"]+=timings["scheduling_native_phase"]
            if isfile(joinpath(output,"compaction_exit.json"))
                timings["scheduling_compaction"]=JSON.parsefile(joinpath(output,"compaction_exit.json"))["process_wall_seconds"]
                timings["scheduling"]+=timings["scheduling_compaction"]
            end
            if isfile(joinpath(output,"reserve_partition_exit.json"))
                timings["scheduling_reserve_partition"]=JSON.parsefile(joinpath(output,"reserve_partition_exit.json"))["process_wall_seconds"]
                timings["scheduling"]+=timings["scheduling_reserve_partition"]
            end
        end
    end
    atomic_json(joinpath(output,"statistics","scheduling.json"),statistics["scheduling"])
    atomic_json(joinpath(output,"timing_snapshots","scheduling.json"),timings)
    schedule === nothing && error("No feasible whole-horizon UC schedule; no fixed-initial fallback")
    atomic_json(joinpath(output,"schedule_balance.json"),
        get(model.ext,:selected_schedule_balance,nothing)===nothing ?
        schedule_balance_summary(input,model) : model.ext[:selected_schedule_balance])
    # Only extracted within-run schedules and compact statistics are needed below.
    # Do not retain the large scheduling model during AC solves and verification.
    model=nothing
    GC.gc()

    stage = time()
    initial = candidate_from_schedule(input,schedule)
    initial_reserve_policy=get(config,"initial_reserve_policy","reallocate")
    initial_reserve_policy in ("reallocate","use_joint_schedule_unverified") || error("Unknown initial reserve policy")
    initial_reserves = if initial_reserve_policy=="use_joint_schedule_unverified"
        get(config,"scheduling_include_reserves",false) || error("Initial reserve reuse requires joint scheduling")
        awards,audit=current_schedule_reserve_handoff(input,schedule)
        statistics["initial_reserve_storage"]=audit
        progress("initial_reserve_handoff";extra=audit)
        awards # Explicitly unverified until the original full-case checks.
    else
        awards,audit=source_reserve_allocation(input,initial;policy=reserve_storage_policy,
            optimizer_for_interval=i->optimizer_with_attributes(HiGHS.Optimizer,"threads"=>config["highs_threads"],
                "time_limit"=>available(config["reserve_seconds_per_interval"]),
                "primal_feasibility_tolerance"=>1e-9),
            interval_callback=info->progress("initial_reserve_allocation";extra=info))
        statistics["initial_reserve_storage"]=audit
        awards
    end
    put_reserves!(initial,initial_reserves)
    timings["initial_reserves"] = time()-stage
    atomic_json(joinpath(output,"candidate_schedule.json"),initial)
    atomic_json(joinpath(output,"timing_snapshots","initial.json"),timings)
    progress("schedule_candidate_ready")
    if get(config,"handshake",true)
        while !isfile(joinpath(output,"continue_after_schedule"))
            available(1.0)
            sleep(0.1)
        end
    end

    stage = time()
    working = tighten_ac_horizon_bounds(input,schedule;policy=ac_ramp_policy)
    working = deepcopy(working)
    power_curves = ac_reserve_policy=="off" ? nothing : fixed_schedule_power_curves(input,schedule)
    results = opf_view(initial,input.periods)
    ac_stats = Any[]
    interval_seed=nothing
    refinement_deadline=ac_refinement_deadline(work_deadline,config["reserve_finish_seconds"])
    for i in input.periods
        if refinement_deadline-time() < 3
            progress("ac_budget_exhausted";extra=Dict("intervals_finished"=>i-1))
            break
        end
        progress("ac_optimization";extra=Dict("interval"=>i,"interval_count"=>length(input.periods)))
        current_on = Dict(uid=>schedule.on_status[uid][i] for uid in input.sdd_ids)
        current_p = Dict(uid=>schedule.real_power[uid][i] for uid in input.sdd_ids)
        if i > 1
            tighten_ac_interval_bounds!(working,i,
                Dict(uid=>schedule.on_status[uid][i-1] for uid in input.sdd_ids),
                Dict(uid=>results[i-1]["simple_dispatchable_device"][uid]["p_on"] for uid in input.sdd_ids),
                current_on;policy=ac_ramp_policy)
        end
        ipopt = optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
            "honor_original_bounds"=>"yes", "bound_relax_factor"=>0.0,
            "tol"=>1e-9,"constr_viol_tol"=>1e-9,"acceptable_tol"=>1e-8,
            "acceptable_constr_viol_tol"=>1e-9,"max_iter"=>500,
            "max_wall_time"=>rounded_ac_time_limit(i==first(input.periods) ?
                get(config,"ac_first_interval_seconds_per_solve",config["ac_seconds_per_solve"]) :
                config["ac_seconds_per_solve"],refinement_deadline),
            "print_level"=>get(config,"ac_print_level",3))
        ac_start = time()
        if ac_correction in AC_CORRECTION_POLICIES
            hour_budget=correction_interval_budget(config,length(input.periods)-i+1,refinement_deadline;now=ac_start)
            hour_deadline=hour_budget["hour_deadline"]
            correction_phase_event("hour_allocation","begin";details=merge(Dict("interval"=>i),hour_budget))
            ac_model,result=compute_corrected_ac(working,input,i;
                on_status=current_on,real_power=current_p,
                reactive_power=Dict(uid=>schedule.reactive_power[uid][i] for uid in input.sdd_ids),
                curves=power_curves,optimizer=ipopt,deadline=hour_deadline,interval_seed=interval_seed,
                slp_seconds=hour_budget["slp_seconds"],
                lp_seconds=get(config,"ac_correction_lp_seconds",4.0),
                max_rounds=get(config,"ac_correction_max_rounds",8),
                fallback_seconds=get(config,"ac_correction_fallback_seconds",12.0),
                threads=config["highs_threads"],adaptive_budget=hour_budget["policy"]=="remaining_horizon_v1",
                policy=ac_correction,lp_solver=get(config,"ac_correction_lp_solver","simplex"),
                recovery_deadline=ac_correction==AC_CORRECTION_RECOVERY_POLICY && ac_recovery!="off" ?
                    hour_budget["protected_recovery_deadline"] : hour_deadline,
                recovery_enabled=ac_recovery!="off",
                diagnostic_dir=joinpath(output,"native_correction","hour_"*lpad(string(i),4,'0')))
            ac_model.ext[:reserve_ac]["correction"]["hour_budget"]=hour_budget
        elseif ac_reserve_policy=="source_joint_reserves_in_ac_v1"
            ac_model,result=compute_reserve_aware_ac(working,input,i;
                on_status=current_on,real_power=current_p,curves=power_curves,
                optimizer=ipopt,shunt_primal_start=ac_shunt_primal_start,
                audit_phases=ac_fail_fast || ac_shunt_primal_start!="off",
                rounded_seconds=get(config,"ac_rounded_seconds_per_solve",nothing),
                rounded_max_iter=get(config,"ac_rounded_max_iterations",500),
                work_deadline=refinement_deadline,interval_seed=interval_seed,
                numerical_recovery=ac_recovery,
                recovery_seconds=get(config,"ac_recovery_seconds_per_solve",360.0),
                recovery_max_iter=get(config,"ac_recovery_max_iterations",1000),
                primal_guard=ac_guard,numerics_policy=ac_numerics)
        else
            ac_model, result = GO3.compute_optimal_power_flow_at_interval(working,i;
                on_status=current_on,real_power=current_p,optimizer=ipopt,
                allow_switching=false,resolve_rounded_shunts=true,fix_shunt_steps=false,
                relax_power_balance=true,relax_thermal_limits=true,
                penalize_power_deviation=true,fix_real_power=false)
        end
        results[i] = result
        correction_point=get(ac_model.ext,:correction_point,nothing)
        stats = if correction_point===nothing
            model_stats(ac_model)
        else
            mapped=Dict(zip(correction_point.variables,correction_point.values))
            Dict{String,Any}("termination"=>"HEURISTIC_CORRECTION_POINT",
                "primal_status"=>ac_model.ext[:reserve_ac]["correction"]["final_model_residual"]<=AC_POINT_RESIDUAL_TOLERANCE ?
                    "LOCALLY_FEASIBLE_CANDIDATE" : "FAILED_LOCAL_RESIDUAL",
                "objective"=>value(v->mapped[v],objective_function(ac_model)),
                "bound"=>nothing,"relative_gap"=>nothing,
                "solve_seconds"=>nothing,"native_relative_gap"=>nothing,
                "certificate_scope"=>"No local/global optimality claim; see individual native calls")
        end
        stats["interval"] = i
        stats["wall_seconds"] = time()-ac_start
        stats["reserve_policy"] = ac_reserve_policy
        stats["interval_start_policy"] = ac_interval_start
        if haskey(ac_model.ext,:reserve_ac)
            stats["reserve_ac"] = ac_model.ext[:reserve_ac]
        end
        stats["warm_start"] = ac_shunt_primal_start=="off" ?
            "flat voltage and source shunt starts; within-run UC/deviation targets; no supplied primal, dual or basis start" :
            "cold first AC solve; same-interval start policy $(ac_shunt_primal_start); exact primal/dual acceptance in reserve_ac log; no external, prior-interval or basis start"
        if ac_interval_start!="off"
            stats["warm_start"]="first interval cold; subsequent first phases use previous locally screened interval from this attempt; rounded phase uses $(ac_shunt_primal_start); no external solution or basis"
        end
        if correction_point!==nothing
            stats["warm_start"]="source voltages and current cold schedule for first interval; later intervals use previous locally screened primal from this attempt; fresh presolved native LP without primal/basis start; fallback uses complete same-attempt primal only; no supplied dual, basis, or external solution"
            if ac_correction in (AC_CORRECTION_HOT_REPAIR_POLICY,AC_CORRECTION_CONTINUATION_POLICY,
                    AC_CORRECTION_ORIGINAL_GUARD_POLICY,AC_CORRECTION_RECOVERY_POLICY)
                stats["warm_start"]="source voltages and current cold schedule; previous locally screened primal only within this attempt; fresh presolved native LP without primal/basis; rounded repair conditionally reuses audited complete same-interval primal/dual mapping; no external solution, cross-run start or basis; no dual certificate claimed"
                if ac_correction in (AC_CORRECTION_CONTINUATION_POLICY,AC_CORRECTION_ORIGINAL_GUARD_POLICY,AC_CORRECTION_RECOVERY_POLICY)
                    stats["warm_start"]*="; previous-hour primal initialization options preserved through fallback rebuild; first native Ipopt iterate audited"
                end
                if ac_correction in (AC_CORRECTION_ORIGINAL_GUARD_POLICY,AC_CORRECTION_RECOVERY_POLICY)
                    stats["warm_start"]*="; early-stop audit triggered by native original unscaled violations, not internal callback residual"
                end
                if ac_correction==AC_CORRECTION_RECOVERY_POLICY
                    stats["warm_start"]*="; dual transfer gated by original relative stationarity; one bounded primal-only adaptive recovery if needed"
                end
            end
        end
        push!(ac_stats,stats)
        statistics["ac_intervals"] = ac_stats
        atomic_json(joinpath(output,"statistics","ac_"*lpad(string(i),4,'0')*".json"),stats)
        # Complete-horizon serialization includes still-scheduled future intervals;
        # it is a candidate only and must be rechecked after projection.
        must_stop=ac_requires_stop(get(ac_model.ext,:reserve_ac,Dict()),ac_fail_fast)
        if must_stop
            progress("ac_refinement_failed";extra=Dict("interval"=>i,
                "reason"=>"final AC point failed explicit primal residual screen"))
        end
        if must_stop || i % get(config,"checkpoint_every_intervals",1) == 0 || i == length(input.periods)
            checkpoint_ac_interval!(output,input,schedule,results,i;must_stop=must_stop,
                ramp_policy=ac_ramp_policy)
        end
        if ac_interval_start!="off"
            interval_seed=capture_ac_interval_start(ac_model,input,i;point=correction_point)
        end
    end
    timings["ac_optimization"] = time()-stage
    stage = time()
    final,export_audit = construct_audited_ac_solution(input,schedule,results,length(ac_stats);
        policy=ac_ramp_policy)
    statistics["final_export_projection"]=export_audit
    force_source_topology!(final,input)
    atomic_json(joinpath(output,"candidate_before_final_reserves.json"),final)
    atomic_json(joinpath(output,"statistics","export_projection_final.json"),export_audit)
    require_ac_export_projection(export_audit)
    progress("reserves")
    awards,reserve_audit = source_reserve_allocation(input,final;policy=reserve_storage_policy,
        optimizer_for_interval=i->optimizer_with_attributes(HiGHS.Optimizer,"threads"=>config["highs_threads"],
            "time_limit"=>available(config["reserve_seconds_per_interval"]),
            "primal_feasibility_tolerance"=>1e-9),
        interval_callback=info->progress("final_reserve_allocation";extra=info))
    statistics["final_reserve_storage"]=reserve_audit
    put_reserves!(final,awards)
    timings["final_reserves_and_postprocess"] = time()-stage
    atomic_json(joinpath(output,"candidate_final.json"),final)
    timings["worker_total"] = time()-started
    atomic_json(joinpath(output,"timings.json"),timings)
    atomic_json(joinpath(output,"solver_statistics.json"),statistics)
    full_coverage=length(ac_stats)==length(input.periods) &&
        [s["interval"] for s in ac_stats]==collect(input.periods)
    progress(full_coverage ? "complete" : "partial_complete";
        extra=Dict("intervals_finished"=>length(ac_stats),
            "intervals_required"=>length(input.periods),"all_intervals_refined"=>full_coverage))
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error("case output config absolute_work_deadline_epoch required")
    config = JSON.parsefile(ARGS[3])
    try
        run_worker(abspath(ARGS[1]),abspath(ARGS[2]),config,parse(Float64,ARGS[4]))
    catch e
        atomic_json(joinpath(ARGS[2],"worker_error.json"),Dict("error"=>sprint(showerror,e),
                                                           "backtrace"=>sprint(showerror,e,catch_backtrace())))
        rethrow()
    end
end
