# Project-owned orchestration of the unmodified, pinned LANL model functions.
using GOC3Benchmark, JuMP, HiGHS, Ipopt, JSON, LinearAlgebra
const GO3 = GOC3Benchmark
const MOI = JuMP.MOI
LinearAlgebra.BLAS.set_num_threads(1)
include(joinpath(@__DIR__,"consumer_dominance.jl"))
include(joinpath(@__DIR__,"scheduling.jl"))
include(joinpath(@__DIR__,"reserve_ac.jl"))

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

function model_stats(model)
    has_primal = primal_status(model)==FEASIBLE_POINT
    Dict("termination" => string(termination_status(model)),
         "primal_status" => string(primal_status(model)),
         "objective" => has_primal ? safe_stat(() -> objective_value(model)) : nothing,
         "bound" => safe_stat(() -> objective_bound(model)),
         "relative_gap" => has_primal ? safe_stat(() -> relative_gap(model)) : nothing,
         "native_relative_gap" => safe_stat(() -> relative_gap(model)),
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
    solution
end

function opf_view(solution, periods)
    [Dict(section => Dict(d["uid"] => Dict(k=>v[i] for (k,v) in d if k!="uid")
                          for d in records) for (section,records) in solution["time_series_output"])
     for i in periods]
end

function run_worker(case_path, output, config, work_deadline)
    started = time()
    timings, statistics = Dict{String,Any}(), Dict{String,Any}()
    progress_sequence=0
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
    ac_reserve_policy=get(config,"ac_reserve_policy","off")
    ac_reserve_policy in ("off","source_joint_reserves_in_ac_v1") || error("Unknown AC reserve policy")

    progress("scheduling")
    stage = time()
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "threads"=>config["highs_threads"],
        "mip_rel_gap"=>config["scheduling_relative_gap"], "mip_feasibility_tolerance"=>1e-9,
        "primal_feasibility_tolerance"=>1e-9, "random_seed"=>0,
        "mip_lp_solver"=>get(config,"scheduling_mip_lp_solver","choose"),
        "log_dev_level"=>get(config,"scheduling_log_dev_level",0))
    get(config,"scheduling_balance_penalties","")=="source_pq_duration_weighted" || error("Missing registered scheduling penalty policy")
    dominance_policy=get(config,"scheduling_consumer_dominance","off")
    dominance_policy in ("off","guarded_online_v1") || error("Unknown consumer dominance policy")
    model, schedule = schedule_source_balances(input; optimizer=optimizer,
        time_limit=available(config["scheduling_seconds"]),
        include_reserves=get(config,"scheduling_include_reserves",true),
        consumer_dominance=dominance_policy=="guarded_online_v1")
    statistics["scheduling"] = model_stats(model)
    merge!(statistics["scheduling"],model.ext[:scheduling_formulation])
    statistics["scheduling"]["mip_lp_solver_requested"]=get(config,"scheduling_mip_lp_solver","choose")
    statistics["scheduling"]["mip_lp_solver_option"]=get_optimizer_attribute(model,"mip_lp_solver")
    statistics["scheduling"]["log_dev_level"]=get_optimizer_attribute(model,"log_dev_level")
    statistics["scheduling"]["bound_scope"] = "approximate_copperplate_subproblem_only_not_full_GO3"
    timings["scheduling"] = time()-stage
    atomic_json(joinpath(output,"statistics","scheduling.json"),statistics["scheduling"])
    schedule === nothing && error("No feasible whole-horizon UC schedule; no fixed-initial fallback")
    atomic_json(joinpath(output,"schedule_balance.json"),schedule_balance_summary(input,model))
    # Only extracted within-run schedules and compact statistics are needed below.
    # Do not retain the large scheduling model during AC solves and verification.
    model=nothing
    GC.gc()

    stage = time()
    initial = candidate_from_schedule(input,schedule)
    initial_reserves = GO3.calculate_reserves_from_generation(input,initial;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>config["highs_threads"],
            "time_limit"=>available(config["reserve_seconds_per_interval"]),
            "primal_feasibility_tolerance"=>1e-9))
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
    working = GO3.tighten_bounds_using_ramp_limits(input,schedule.on_status,schedule.real_power)
    working = deepcopy(working)
    power_curves = ac_reserve_policy=="off" ? nothing : fixed_schedule_power_curves(input,schedule)
    results = opf_view(initial,input.periods)
    ac_stats = Any[]
    for i in input.periods
        if work_deadline-time() < config["reserve_finish_seconds"] + 3
            progress("ac_budget_exhausted";extra=Dict("intervals_finished"=>i-1))
            break
        end
        progress("ac_optimization";extra=Dict("interval"=>i,"interval_count"=>length(input.periods)))
        current_on = Dict(uid=>schedule.on_status[uid][i] for uid in input.sdd_ids)
        current_p = Dict(uid=>schedule.real_power[uid][i] for uid in input.sdd_ids)
        if i > 1
            GO3.tighten_bounds_at_interval_using_ramp_limits!(working,i,
                Dict(uid=>schedule.on_status[uid][i-1] for uid in input.sdd_ids),
                Dict(uid=>results[i-1]["simple_dispatchable_device"][uid]["p_on"] for uid in input.sdd_ids),
                current_on)
        end
        ipopt = optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
            "honor_original_bounds"=>"yes", "bound_relax_factor"=>0.0,
            "tol"=>1e-9,"constr_viol_tol"=>1e-9,"acceptable_tol"=>1e-8,
            "acceptable_constr_viol_tol"=>1e-9,"max_iter"=>500,
            "max_wall_time"=>available(config["ac_seconds_per_solve"]),"print_level"=>3)
        ac_start = time()
        if ac_reserve_policy=="source_joint_reserves_in_ac_v1"
            ac_model,result=compute_reserve_aware_ac(working,input,i;
                on_status=current_on,real_power=current_p,curves=power_curves,
                optimizer=ipopt)
        else
            ac_model, result = GO3.compute_optimal_power_flow_at_interval(working,i;
                on_status=current_on,real_power=current_p,optimizer=ipopt,
                allow_switching=false,resolve_rounded_shunts=true,fix_shunt_steps=false,
                relax_power_balance=true,relax_thermal_limits=true,
                penalize_power_deviation=true,fix_real_power=false)
        end
        results[i] = result
        stats = model_stats(ac_model)
        stats["interval"] = i
        stats["wall_seconds"] = time()-ac_start
        stats["reserve_policy"] = ac_reserve_policy
        if haskey(ac_model.ext,:reserve_ac)
            stats["reserve_ac"] = ac_model.ext[:reserve_ac]
        end
        stats["warm_start"] = "flat voltage and source shunt starts; within-run UC/deviation targets; no supplied primal, dual or basis start"
        push!(ac_stats,stats)
        statistics["ac_intervals"] = ac_stats
        atomic_json(joinpath(output,"statistics","ac_"*lpad(string(i),4,'0')*".json"),stats)
        # Complete-horizon serialization includes still-scheduled future intervals;
        # it is a candidate only and must be rechecked after projection.
        if i % get(config,"checkpoint_every_intervals",1) == 0 || i == length(input.periods)
            partial = GO3.construct_solution_dict(input,schedule;opf_data=results,
                include_reserves=false,postprocess=true,print_projected_devices=false)
            force_source_topology!(partial,input)
            atomic_json(joinpath(output,"checkpoints","candidate_ac_"*lpad(string(i),4,'0')*".json"),partial)
        end
    end
    timings["ac_optimization"] = time()-stage
    stage = time()
    final = GO3.construct_solution_dict(input,schedule;opf_data=results,
        include_reserves=false,postprocess=true,print_projected_devices=false)
    force_source_topology!(final,input)
    atomic_json(joinpath(output,"candidate_before_final_reserves.json"),final)
    progress("reserves")
    awards = GO3.calculate_reserves_from_generation(input,final;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>config["highs_threads"],
            "time_limit"=>available(config["reserve_seconds_per_interval"]),
            "primal_feasibility_tolerance"=>1e-9))
    put_reserves!(final,awards)
    timings["final_reserves_and_postprocess"] = time()-stage
    atomic_json(joinpath(output,"candidate_final.json"),final)
    timings["worker_total"] = time()-started
    atomic_json(joinpath(output,"timings.json"),timings)
    atomic_json(joinpath(output,"solver_statistics.json"),statistics)
    progress("complete")
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
