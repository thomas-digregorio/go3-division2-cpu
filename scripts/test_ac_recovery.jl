# Only tiny synthetic models. No competition case, prior run or POP is read.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const RECOVERY_POLICY="adaptive_barrier_on_failed_residual_v1"

@testset "GO3 numerical recovery triggers only on failed residuals" begin
    phases(r,status="TIME_LIMIT")=[Dict("complete_finite_point"=>true,
        "max_primal_residual"=>r,"termination"=>status)]
    @test !ac_recovery_required(Any[],"off")
    @test !ac_recovery_required(phases(0.0),RECOVERY_POLICY)
    @test !ac_recovery_required(phases(1e-8),RECOVERY_POLICY)
    @test ac_recovery_required(phases(1.001e-8,"LOCALLY_SOLVED"),RECOVERY_POLICY)
    @test ac_recovery_required(phases(NaN),RECOVERY_POLICY)
    @test_throws ErrorException ac_recovery_required(Any[],RECOVERY_POLICY)
    @test_throws ErrorException ac_recovery_required(phases(0.0),"unknown")
end

@testset "GO3 fresh recovery state preserves model and clears native starts" begin
    for legacy in (false,true), maximize in (false,true)
        opt=optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,
            "tol"=>1e-9,"constr_viol_tol"=>1e-9,"bound_relax_factor"=>0.0,
            "honor_original_bounds"=>"yes","max_iter"=>500)
        m=Model(opt)
        @variable(m,0 <= x <= 5,start=1.5)
        @variable(m,0 <= y <= 5,start=1.5)
        @variable(m,shunt == 1.0)
        @constraint(m,balance,x+y==3)
        cap=legacy ? @NLconstraint(m,x^2 <= 4) : @constraint(m,x^2 <= 4)
        @objective(m,Min,-x+0.1*(y-1.0)^2)
        maximize && @objective(m,Max,x-0.1*(y-1.0)^2)
        optimize!(m)
        point=capture_complete_ac_primal(m)
        saved_bounds=ac_variable_bounds(m)
        saved_objective=objective_function(m)
        saved_rows=all_constraints(m;include_variable_in_set_constraints=true)
        if legacy
            set_nonlinear_dual_start_value(m,[1e9])
        else
            set_dual_start_value(cap,1e9)
        end
        set_dual_start_value(balance,-1e9)
        set_optimizer_attribute(m,"warm_start_init_point","yes")
        r=prepare_ac_recovery!(m,opt,point;seconds=10.0,deadline=time()+30.0)
        @test r["attempted"]===true
        @test r["fresh_optimizer_instantiated"]===true
        @test r["complete_primal_start"]["accepted_interface_count"]==num_variables(m)
        @test r["complete_primal_start"]["source"]=="failed_rounded_shunt_solve_in_same_interval_and_attempt"
        @test r["dual_starts_cleared"]==length(saved_rows)
        @test dual_start_value(balance)===nothing
        @test legacy ? nonlinear_dual_start_value(m)===nothing : dual_start_value(cap)===nothing
        @test ac_variable_bounds(m)==saved_bounds
        @test all_constraints(m;include_variable_in_set_constraints=true)==saved_rows
        @test JuMP.isequal_canonical(objective_function(m),saved_objective)
        @test get_optimizer_attribute(m,"mu_strategy")=="adaptive"
        @test get_optimizer_attribute(m,"warm_start_init_point")=="no"
        @test get_optimizer_attribute(m,"bound_relax_factor")==0.0
        @test get_optimizer_attribute(m,"constr_viol_tol")==1e-9
        @test r["source_bounds_changed"]===false && r["objective_changed"]===false
        # A zero-iteration native call must consume the complete primal. The
        # previous 1e9 dual attributes must not survive into this fresh solve.
        set_optimizer_attribute(m,"max_iter",0)
        optimize!(m)
        @test termination_status(m)==MOI.ITERATION_LIMIT
        @test value.(point.variables)≈point.values atol=1e-8
        @test abs(dual(balance))<1e8
        set_optimizer_attribute(m,"max_iter",500)
        optimize!(m)
        @test termination_status(m) in (MOI.LOCALLY_SOLVED,MOI.ALMOST_LOCALLY_SOLVED)
        @test ac_primal_residual(m,capture_complete_ac_primal(m))<=1e-8
        @test value(x)≈2.0 atol=1e-7
        @test value(shunt)==1.0
        @test_throws ErrorException prepare_ac_recovery!(m,opt,point;
            seconds=10.0,deadline=time()-1)
        @test_throws ErrorException prepare_ac_recovery!(m,opt,point;
            seconds=10.0,deadline=Inf,max_iter=0)
        @test_throws ErrorException prepare_ac_recovery!(m,opt,
            (variables=point.variables,values=fill(NaN,length(point.variables)));
            seconds=10.0,deadline=Inf)
    end
end

@testset "GO3 forced tiny hourly recovery preserves source physics" begin
    path=joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json")
    raw=JSON.parsefile(path)
    original=deepcopy(raw)
    input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids))
    curves=fixed_schedule_power_curves(input,schedule)
    opt=optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,"max_iter"=>0,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes",
        "tol"=>1e-9,"constr_viol_tol"=>1e-9,"max_wall_time"=>10.0)
    results=Dict{String,Dict}[]
    for i in input.periods
        m,sol=compute_reserve_aware_ac(deepcopy(input),input,i;
            on_status=Dict(u=>1 for u in input.sdd_ids),
            real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves,
            optimizer=opt,set_silent=true,shunt_primal_start="within_interval_primal_dual_v1",
            audit_phases=true,rounded_seconds=10.0,rounded_max_iter=0,
            numerical_recovery=RECOVERY_POLICY,recovery_seconds=20.0,
            recovery_max_iter=1000,work_deadline=time()+60.0,
            primal_guard=AC_PRIMAL_GUARD_POLICY)
        push!(results,sol)
        info=m.ext[:reserve_ac]
        @test length(info["phases"])==3
        @test info["phases"][2]["max_primal_residual"]>1e-8
        @test info["phases"][3]["phase"]=="numerical_recovery"
        @test info["phases"][3]["max_primal_residual"]<=1e-8
        @test info["numerical_recovery"]["attempted"]===true
        @test info["primal_guard"]["policy"]==AC_PRIMAL_GUARD_POLICY
        @test length(info["primal_guard"]["phases"])==2
        @test info["primal_guard"]["phases"][2]["callback_count"]>0
        @test !ac_requires_stop(info,true)
        @test raw==original
        @test all(isinteger,value.(m[:shunt_step]))
        for key in (:p_balance_slack_pos,:p_balance_slack_neg,:q_balance_slack_pos,:q_balance_slack_neg)
            @test all(v->lower_bound(v)==0.0 && upper_bound(v)==0.0,m[key])
        end
    end
    solution=GO3.construct_solution_dict(input,schedule;opf_data=results,
        include_reserves=false,postprocess=true,print_projected_devices=false)
    force_source_topology!(solution,input)
    awards=GO3.calculate_reserves_from_generation(input,solution;
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,
            "output_flag"=>false,"primal_feasibility_tolerance"=>1e-9))
    put_reserves!(solution,awards)
    out=isempty(ARGS) ? mktempdir(joinpath(@__DIR__,"..","tmp");prefix="ac_recovery_fixture_") : first(ARGS)
    atomic_json(joinpath(out,"candidate_final.json"),solution)
    atomic_json(joinpath(out,"audit.json"),Dict("forced_recovery_intervals"=>3,
        "first_two_solves_max_iterations"=>0,"source_unchanged"=>raw==original,
        "competition_case_loaded"=>false))
    println("GO3_RECOVERY_FIXTURE_OUTPUT ",abspath(out))
end
