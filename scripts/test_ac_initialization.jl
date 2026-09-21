# Tiny synthetic models only. No full case, saved solution or external start.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

function initialization_optimizer(;iterations=0)
    optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,"max_iter"=>iterations,
        "max_wall_time"=>15.0,"tol"=>1e-9,"constr_viol_tol"=>1e-9,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes")
end

@testset "Primal-only pushes preserve actual native initialization and exact model" begin
    changes=Float64[]
    for small_pushes in (false,true)
        m=Model(initialization_optimizer())
        @variable(m,deleted);delete(m,deleted)
        @variable(m,0<=x<=1,start=0.0)
        @variable(m,0<=y<=2,start=1.0)
        @variable(m,z==1,start=1.0)
        @constraint(m,x+y==1)
        @constraint(m,sin(x)<=0.5)
        @objective(m,Min,(x+1)^2+y^2)
        bounds=ac_variable_bounds(m);rows=all_constraints(m;include_variable_in_set_constraints=true)
        objective=objective_function(m)
        configure_ac_numerics!(m,AC_NUMERICS_POLICY)
        if small_pushes
            options=preserve_ac_primal_initialization!(m)
            @test options["warm_start_init_point"]=="no"
            @test options["bound_push"]==options["slack_bound_push"]==1e-8
        end
        expected=complete_requested_ac_start(m)
        guard=install_ac_primal_guard!(m;policy=AC_CANDIDATE_GUARD_POLICY,
            phase="continuous_shunt_candidate",expected_start=expected,
            audit_only=true,audit_initial_residual=true,
            residual_screen="native_original_unscaled",min_iterations=0,window=2,
            objective_relative_range=1e100)
        optimize_audited_ac!(m;policy=AC_NUMERICS_POLICY,interval=1,phase="fixture",deadline=time()+30)
        record=finish_ac_primal_guard!(m,guard)
        native=record["native_initialization"]
        push!(changes,native["maximum_absolute_change_from_requested_start"])
        @test termination_status(m)==MOI.ITERATION_LIMIT
        @test record["audit_only"] && !record["stop_requested"]
        @test record["audit_count"]==0 && record["native_original_probe_count"]==1
        @test record["native_mapping_complete"] && record["native_variable_count"]==3
        @test native["complete_mapping"] && native["iteration"]==0
        @test native["original_unscaled_residual"]≈ac_primal_residual(m,capture_complete_ac_primal(m)) atol=1e-12
        @test native["maximum_relative_change_from_requested_start"]≈changes[end] atol=1e-12
        @test ac_variable_bounds(m)==bounds
        @test all_constraints(m;include_variable_in_set_constraints=true)==rows
        @test JuMP.isequal_canonical(objective_function(m),objective)
        @test get_optimizer_attribute(m,"bound_relax_factor")==0.0
        @test get_optimizer_attribute(m,"constr_viol_tol")==1e-9
    end
    @test changes[1]≈0.01 atol=1e-12
    @test changes[2]<=1.01e-8
    @test changes[1]>100000*changes[2]
    m=Model(initialization_optimizer());@variable(m,x)
    @test_throws ErrorException complete_requested_ac_start(m)
    for flags in ((audit_only=true,),(audit_initial_residual=true,),(audit_only=1,))
        @test_throws ErrorException install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,
            phase="rounded_shunts",flags...)
    end
end

function tiny_schedule(input)
    products=(:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,:p_rru_off,
        :p_rrd_on,:p_rrd_off,:q_qru,:q_qrd)
    base=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),
        reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
    merge(base,NamedTuple{products}(Tuple(Dict(u=>zeros(3) for u in input.sdd_ids) for _ in products)))
end

@testset "Complete current-attempt seed preserves source bounds cost blocks and reserves" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    for ts in raw["time_series_input"]["simple_dispatchable_device"]
        ts["cost"][1]=ts["uid"]=="g" ? [[10.0,0.4],[20.0,2.6]] : [[1000.0,0.3],[900.0,1.7]]
    end
    original=deepcopy(raw);input=GO3.process_input_data(raw);schedule=tiny_schedule(input)
    schedule.p_rgu["g"][1]=0.01
    curves=fixed_schedule_power_curves(input,schedule)
    on=Dict(u=>1 for u in input.sdd_ids);p=Dict(u=>1.0 for u in input.sdd_ids)
    m,r=build_reserve_aware_ac(deepcopy(input),input,1;on_status=on,real_power=p,curves)
    bounds=ac_variable_bounds(m);rows=all_constraints(m;include_variable_in_set_constraints=true)
    objective=objective_function(m)
    record,point=initialize_ac_from_current_schedule!(m,r,input,1,schedule,p)
    @test record["complete_current_primal_vector"] && all(isfinite,point.values)
    @test record["variable_count"]==num_variables(m)
    @test record["source"]=="current_attempt_joint_schedule"
    @test record["optimization_calls"]==0 && !record["external_solution_read"]
    @test !record["feasibility_claimed"] && !record["source_bounds_changed"]
    @test record["reserve_values_initialized"]==10*length(input.sdd_ids)
    @test all(start_value(m[:p_sdd][u])==1.0 for u in input.sdd_ids)
    @test all(start_value(m[:q_sdd][u])==0.0 for u in input.sdd_ids)
    @test start_value(r.variables.p_rgu["g"])==0.01
    blocks=ac_cost_block_map(m,input,1)
    for (uid,vs) in blocks
        @test sum(start_value,vs)≈1.0 atol=1e-12
        ordered=sort(vs;by=v->-coefficient(objective,v))
        @test start_value(ordered[1])==upper_bound(ordered[1])
        @test start_value(ordered[2])≈1-upper_bound(ordered[1]) atol=1e-12
        @test start_value(m[:p_slack_pos][uid])==start_value(m[:p_slack_neg][uid])==0
    end
    @test ac_variable_bounds(m)==bounds
    @test all_constraints(m;include_variable_in_set_constraints=true)==rows
    @test JuMP.isequal_canonical(objective_function(m),objective)
    @test raw==original
    @test_throws ErrorException initialize_ac_from_current_schedule!(m,r,input,2,schedule,p)
    bad=deepcopy(schedule);bad.real_power["g"][1]=NaN
    @test_throws ErrorException initialize_ac_from_current_schedule!(m,r,input,1,bad,p)
    @test_throws ErrorException initialize_ac_from_current_schedule!(m,r,input,1,
        (real_power=schedule.real_power,reactive_power=schedule.reactive_power),p)
    off=deepcopy(schedule);off.on_status["d"].=0
    off_curves=fixed_schedule_power_curves(input,off)
    off_power=Dict("g"=>1.0,"d"=>0.0)
    off_model,off_reserve=build_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict("g"=>1,"d"=>0),real_power=off_power,curves=off_curves)
    @test !("d" in axes(off_model[:p_sdd],1))
    @test_throws ErrorException initialize_ac_from_current_schedule!(off_model,off_reserve,input,1,off,off_power)
end

@testset "Complete start and native audit survive rounded solve and fresh recovery" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    original=deepcopy(raw);input=GO3.process_input_data(raw);schedule=tiny_schedule(input)
    curves=fixed_schedule_power_curves(input,schedule)
    m,_=compute_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves,
        optimizer=initialization_optimizer(),set_silent=true,audit_phases=true,
        shunt_primal_start="within_interval_primal_dual_v1",
        rounded_seconds=15.0,rounded_max_iter=0,work_deadline=time()+90,
        numerical_recovery="adaptive_barrier_on_failed_residual_v1",
        recovery_seconds=30.0,recovery_max_iter=1000,numerics_policy=AC_NUMERICS_POLICY,
        initialization_policy=AC_INITIALIZATION_POLICY,schedule_seed=schedule,
        primal_guard=AC_PRIMAL_GUARD_POLICY)
    info=m.ext[:reserve_ac]
    @test length(info["phases"])==3
    @test !ac_requires_stop(info,true)
    @test info["phases"][3]["max_primal_residual"]<=1e-8
    @test info["numerical_recovery"]["fresh_optimizer_instantiated"]
    @test info["numerical_recovery"]["options"]["bound_push"]==1e-8
    @test info["numerical_recovery"]["options"]["slack_bound_push"]==1e-8
    @test info["numerical_recovery"]["options"]["warm_start_init_point"]=="no"
    @test !info["shunt_primal_start"]["dual_transfer_used"]
    @test length(info["primal_guard"]["phases"])==3
    for record in info["primal_guard"]["phases"]
        @test record["native_initialization"]["complete_mapping"]
        @test isfinite(record["native_initialization"]["original_unscaled_residual"])
        @test record["residual_screen"]=="native_original_unscaled"
        @test !record["discrete_solution_claimed"]
    end
    @test info["primal_guard"]["phases"][1]["audit_only"]
    @test all(r->r["native_backend_confirmed"] && r["floating_point_bits"]==64,info["numerical_calls"])
    @test raw==original
end
