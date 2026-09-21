# Tiny fixtures only. No competition input, saved run or external solution.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

function test_opt(;iterations=0)
    optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,"max_iter"=>iterations,
        "max_wall_time"=>15.0,"tol"=>1e-9,"constr_viol_tol"=>1e-9,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes")
end

@testset "Modern interface ignores legacy keyword; explicit backend is consumed" begin
    m=Model(test_opt())
    @variable(m,0.2<=x<=2,start=0.7)
    @constraint(m,sin(x)<=0.9)
    @objective(m,Min,(x-0.5)^2)
    @test isempty(all_nonlinear_constraints(m))
    optimize!(m,_differentiation_backend=GO3.MathOptSymbolicAD.DefaultBackend())
    @test MOI.get(unsafe_backend(m),MOI.AutomaticDifferentiationBackend()) isa MOI.Nonlinear.SparseReverseMode
    rows=all_constraints(m;include_variable_in_set_constraints=true)
    bounds=ac_variable_bounds(m); objective=objective_function(m)
    configure_ac_numerics!(m,AC_NUMERICS_POLICY)
    record=optimize_audited_ac!(m;policy=AC_NUMERICS_POLICY,interval=1,phase="fixture",deadline=time()+30)
    @test record["native_backend_confirmed"]
    @test occursin("SymbolicMode",record["effective_native_backend"])
    @test occursin("SymbolicAD.Evaluator",record["effective_native_evaluator"])
    @test record["mu_strategy"]=="adaptive"
    @test record["floating_point_bits"]==64
    @test ac_variable_bounds(m)==bounds
    @test all_constraints(m;include_variable_in_set_constraints=true)==rows
    @test JuMP.isequal_canonical(objective_function(m),objective)
    @test get_optimizer_attribute(m,"bound_relax_factor")==0.0
    @test get_optimizer_attribute(m,"constr_viol_tol")==1e-9
    @test_throws ErrorException configure_ac_numerics!(m,"unknown")
    legacy=Model(test_opt());@variable(legacy,y);@NLconstraint(legacy,sin(y)<=1)
    @test_throws ErrorException configure_ac_numerics!(legacy,AC_NUMERICS_POLICY)
end

function derivative_snapshot(model,x)
    data=MOI.get(unsafe_backend(model),MOI.NLPBlock())
    evaluator=data.evaluator
    n=length(x); m=length(data.constraint_bounds)
    g=zeros(m);MOI.eval_constraint(evaluator,g,x)
    js=MOI.jacobian_structure(evaluator);jv=zeros(length(js))
    MOI.eval_constraint_jacobian(evaluator,jv,x)
    jac=zeros(m,n)
    for ((r,c),v) in zip(js,jv);jac[r,c]+=v;end
    hs=MOI.hessian_lagrangian_structure(evaluator);hv=zeros(length(hs))
    multipliers=[0.2+0.01i for i in 1:m]
    MOI.eval_hessian_lagrangian(evaluator,hv,x,1.0,multipliers)
    hess=zeros(n,n)
    for ((r,c),v) in zip(hs,hv);hess[r,c]+=v;end
    # Normalize either permitted triangular representation.
    hess=hess+transpose(hess)-Diagonal(diag(hess))
    (;g,jac,hess,bounds=data.constraint_bounds)
end

@testset "Source AC expressions Jacobians and Hessians agree across backends" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    original=deepcopy(raw);input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids))
    curves=fixed_schedule_power_curves(input,schedule)
    models=Any[]
    for policy in ("legacy_v1",AC_NUMERICS_POLICY)
        m,_=build_reserve_aware_ac(deepcopy(input),input,1;
            on_status=Dict(u=>1 for u in input.sdd_ids),
            real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves)
        set_optimizer(m,test_opt())
        rows=all_constraints(m;include_variable_in_set_constraints=true)
        bounds=ac_variable_bounds(m);objective=objective_function(m)
        configure_ac_numerics!(m,policy)
        optimize_audited_ac!(m;policy,interval=1,phase="derivative_fixture",deadline=time()+30)
        @test rows==all_constraints(m;include_variable_in_set_constraints=true)
        @test bounds==ac_variable_bounds(m)
        @test JuMP.isequal_canonical(objective_function(m),objective)
        push!(models,m)
    end
    @test num_variables(models[1])==num_variables(models[2])
    @test name.(all_variables(models[1]))==name.(all_variables(models[2]))
    @test ac_variable_bounds(models[1])==ac_variable_bounds(models[2])
    for probe in (0.3,0.7,1.1)
        x=[is_fixed(v) ? fix_value(v) : clamp(probe,
            has_lower_bound(v) ? lower_bound(v) : -Inf,
            has_upper_bound(v) ? upper_bound(v) : Inf) for v in all_variables(models[1])]
        a,b=[derivative_snapshot(m,x) for m in models]
        @test a.bounds==b.bounds
        @test a.g≈b.g atol=1e-10 rtol=1e-10
        @test a.jac≈b.jac atol=1e-10 rtol=1e-10
        @test a.hess≈b.hess atol=1e-10 rtol=1e-10
        @test all(isfinite,a.hess) && all(isfinite,b.hess)
    end
    @test raw==original

    # Force the two initial phases to iteration-limit, proving that a fresh
    # recovery optimizer also gets the requested backend, not its default.
    m,_=compute_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves,
        optimizer=test_opt(),set_silent=true,audit_phases=true,
        shunt_primal_start="within_interval_primal_dual_v1",
        rounded_seconds=15.0,rounded_max_iter=0,work_deadline=time()+90,
        numerical_recovery="adaptive_barrier_on_failed_residual_v1",
        recovery_seconds=30.0,recovery_max_iter=1000,numerics_policy=AC_NUMERICS_POLICY)
    info=m.ext[:reserve_ac]
    @test length(info["phases"])==3
    @test !ac_requires_stop(info,true)
    @test info["phases"][3]["max_primal_residual"]<=1e-8
    @test all(r->occursin("SymbolicMode",r["effective_native_backend"]),info["numerical_calls"])
    @test all(r->occursin("SymbolicAD.Evaluator",r["effective_native_evaluator"]),info["numerical_calls"])
    @test all(r->r["native_backend_confirmed"],info["numerical_calls"])
    @test all(r->r["mu_strategy"]=="adaptive",info["numerical_calls"])
    @test info["model_build_seconds"]>=0
    @test all(r->r["residual_audit_seconds"]>=0,info["phases"])
    @test raw==original
end
