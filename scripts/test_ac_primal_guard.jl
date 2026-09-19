# Tiny synthetic models only. No competition data or prior result is loaded.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 primal guard objective and policy gates" begin
    @test ac_objective_stable([1e7,1e7+0.1],1e-7)
    @test ac_objective_stable([-1e7,-1e7+0.1],1e-7)
    @test ac_objective_stable([0.0,1e-9],1e-7)
    @test !ac_objective_stable([1.0,1.01],1e-7)
    @test !ac_objective_stable([Inf,Inf],1e-7)
    @test !ac_objective_stable([NaN,0.0],1e-7)
    @test !ac_objective_stable([1.0],1e-7)
    m=Model(Ipopt.Optimizer)
    @variable(m,0<=shunt_step[["s"]]<=2)
    @test_throws ErrorException install_ac_primal_guard!(m;policy="unknown",phase="rounded_shunts")
    @test_throws ErrorException install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,phase="continuous_shunts")
    @test_throws ErrorException install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,phase="rounded_shunts")
    fix(shunt_step["s"],1;force=true)
    for extra in ((min_iterations=-1,),(min_iterations=true,),(window=1,),(window=true,),
            (objective_relative_range=Inf,),(objective_relative_range=-1,),
            (primal_tolerance=0.0,),(primal_tolerance=1e-7,),(primal_tolerance=NaN,))
        @test_throws ErrorException install_ac_primal_guard!(m;
            policy=AC_PRIMAL_GUARD_POLICY,phase="rounded_shunts",extra...)
    end
    off=install_ac_primal_guard!(m;policy="off",phase="rounded_shunts")
    @test !off.record["enabled"]
    @test !off.record["stop_requested"]
end

@testset "GO3 native guarded stop returns the audited complete primal" begin
    for legacy in (false,true), maximize in (false,true)
        m=Model(optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,
            "tol"=>1e-12,"constr_viol_tol"=>1e-12,"bound_relax_factor"=>0.0,
            "honor_original_bounds"=>"yes","max_iter"=>300))
        @variable(m,deleted)
        delete(m,deleted) # Native mapping must not assume original index==column.
        @variable(m,0<=x<=5,start=1.2)
        @variable(m,0<=y<=5,start=1.8)
        @variable(m,shunt==1.0)
        @constraint(m,x+y==3.0)
        legacy ? @NLconstraint(m,x^2<=4.0) : @constraint(m,x^2<=4.0)
        @objective(m,Min,(x-2)^2+0.1*(y-1)^2)
        maximize && @objective(m,Max,-(x-2)^2-0.1*(y-1)^2)
        bounds=ac_variable_bounds(m)
        rows=all_constraints(m;include_variable_in_set_constraints=true)
        objective=objective_function(m)
        # Relax only this TEST's objective-stability trigger to deterministically
        # exercise an early callback; never relax the primal residual threshold.
        g=install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,phase="rounded_shunts",
            min_iterations=0,window=2,objective_relative_range=1e100)
        optimize!(m)
        r=finish_ac_primal_guard!(m,g)
        @test termination_status(m)==MOI.INTERRUPTED
        @test r["stop_requested"] && r["returned_point_passed_local_screen"]
        @test r["native_mapping_complete"] && r["native_variable_count"]==3
        @test r["variable_count"]==num_variables(m)
        @test r["model_residual_at_stop"]<=1e-8
        @test r["returned_model_residual"]<=1e-8
        @test r["returned_point_max_change"]<=1e-8
        @test value.(g.point[].variables)≈g.point[].values atol=1e-8
        @test r["model_objective_at_stop"]≈objective_value(m) atol=1e-8
        @test value(shunt)==1.0
        @test ac_variable_bounds(m)==bounds
        @test all_constraints(m;include_variable_in_set_constraints=true)==rows
        @test JuMP.isequal_canonical(objective_function(m),objective)
        @test !r["external_solution_read"] && !r["source_bounds_changed"]
        @test occursin("no KKT",r["certificate_scope"])
        # Installing a second phase starts with fresh callback history. The
        # completed record must not silently change as the next solve proceeds.
        old=deepcopy(r)
        set_start_value(x,1.1);set_start_value(y,1.9)
        g2=install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,phase="numerical_recovery",
            min_iterations=0,window=2,objective_relative_range=1e100,primal_tolerance=1e-10)
        optimize!(m)
        r2=finish_ac_primal_guard!(m,g2)
        @test r2["stop_requested"] && r2["returned_point_passed_local_screen"]
        @test r==old
        @test r2["phase"]=="numerical_recovery"
        @test r2["primal_residual_limit"]==1e-10
        @test r2["model_residual_at_stop"]<=1e-10
        @test r2["returned_point_passed_internal_target"]
    end
end

@testset "GO3 primal guard allows normal convergence before its trigger" begin
    m=Model(optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,"tol"=>1e-9))
    @variable(m,x,start=0.0)
    @objective(m,Min,(x-2)^2)
    g=install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,phase="rounded_shunts",
        min_iterations=10000)
    optimize!(m)
    r=finish_ac_primal_guard!(m,g)
    @test termination_status(m)==MOI.LOCALLY_SOLVED
    @test !r["stop_requested"]
    @test r["callback_count"]>0
    @test r["audit_count"]==0
    @test value(x)≈2.0 atol=1e-8
end

@testset "GO3 unfixed-shunt guard certifies only an intermediate candidate" begin
    m=Model(optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,
        "tol"=>1e-12,"constr_viol_tol"=>1e-12,"bound_relax_factor"=>0.0))
    @variable(m,0<=shunt_step[["s"]]<=2,start=0.1)
    @variable(m,0<=p<=3,start=0.0)
    @constraint(m,shunt_step["s"]==0.4)
    @constraint(m,p+shunt_step["s"]==1.4)
    @objective(m,Max,-p)
    @test_throws ErrorException install_ac_primal_guard!(m;policy=AC_PRIMAL_GUARD_POLICY,
        phase="rounded_shunts")
    @test_throws ErrorException install_ac_primal_guard!(m;policy=AC_CANDIDATE_GUARD_POLICY,
        phase="rounded_shunts")
    guard=install_ac_primal_guard!(m;policy=AC_CANDIDATE_GUARD_POLICY,phase="continuous_shunt_candidate",
        min_iterations=0,window=2,objective_relative_range=1e100,primal_tolerance=1e-10)
    optimize!(m)
    record=finish_ac_primal_guard!(m,guard)
    @test record["stop_requested"] && record["candidate_only"]
    @test !record["discrete_solution_claimed"]
    @test occursin("not an admissible discrete solution",record["certificate_scope"])
    @test record["returned_point_passed_internal_target"]
    @test !is_fixed(shunt_step["s"]) && !isinteger(value(shunt_step["s"]))
    @test value(shunt_step["s"])≈0.4 atol=1e-10
    @test lower_bound(shunt_step["s"])==0 && upper_bound(shunt_step["s"])==2
end
