using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 native import warnings, retained logs and model readback" begin
    # A native warning is not infeasibility. Reproduce one with an intentionally
    # tiny candidate-matrix entry, then bound the import's complete row effect.
    A=sparse([1,1],[1,2],[1.0,5e-13],1,2)
    original=copy(A)
    point,stats=correction_native_lp(A,[1.0,0.0],[0.0,0.0],[1.0,1.0],[-Inf],[1.0],[0.0,0.0];seconds=10)
    @test stats["import_status"]==HiGHS.kHighsStatusWarning
    @test stats["import_audit"]["pass"]
    @test stats["import_audit"]["domains_exact"] && stats["import_audit"]["objective_exact"]
    @test stats["import_audit"]["changed_nonzeros"]==1
    @test stats["import_audit"]["maximum_bounded_row_error"]==5e-13
    @test stats["native_optimizations"]==1 && point!==nothing
    @test maximum(A*point.-[1.0])<=1e-9
    @test isfile(stats["native_log_file"]*".json")
    @test occursin("WARNING",read(stats["native_log_file"],String))
    @test stats["native_warning_error_count"]==1
    @test !any(occursin("P-D objective error",s) for s in stats["native_warning_error_excerpt"])
    @test A==original
    # Small coefficient does not imply harmless: wide or unbounded domains
    # can amplify it. Refuse that LP before optimization, preserving the point.
    for upper in (1e10,Inf)
        point,stats=correction_native_lp(A,[1.0,0.0],[0.0,0.0],[1.0,upper],[-Inf],[1.0],[0.0,0.0];seconds=10)
        @test point===nothing && !stats["import_audit"]["pass"]
        @test stats["native_optimizations"]==0
        @test stats["reason"]=="native_import_changed_linearization_beyond_audited_limit"
    end
    # Source finite bounds must never silently become native infinity.
    point,stats=correction_native_lp(sparse([1.0;;]),[1.0],[0.0],[1e25],[-Inf],[1.0],[0.0];seconds=10)
    @test point===nothing && !stats["import_audit"]["domains_exact"]
    @test stats["native_optimizations"]==0
    # True native errors remain errors and retain their diagnostic record.
    logs=mktempdir(joinpath(@__DIR__,"..","tmp");cleanup=false)
    @test_throws ErrorException correction_native_lp(sparse([1e16;;]),[1.0],[0.0],[1.0],[-Inf],[1.0],[0.0];seconds=10,log_dir=logs)
    record=JSON.parsefile(only(filter(p->endswith(p,".json"),readdir(logs;join=true))))
    @test record["import_status"]==HiGHS.kHighsStatusError
    @test haskey(record,"error") && record["native_warning_error_count"]>0
    @test_throws ErrorException correction_native_lp(A,[1.0,0.0],[0.0,0.0],[1.0,1.0],[-Inf],[1.0],[0.0,0.0];seconds=10,log_dir="C:/OneDrive/forbidden")
end

@testset "GO3 AC correction original equations, Jacobian, bounds, rollback" begin
    m=Model();@variable(m,0.5<=v<=1.5,start=1.0)
    @variable(m,-0.5<=a<=0.5,start=0.0)
    @variable(m,0<=p<=2,start=1.0)
    @constraint(m,v*sin(a)==0.1)
    @constraint(m,v^2+p==2.0)
    @constraint(m,p>=0.2)
    @objective(m,Max,10p-v)
    o=correction_oracle(m);x=[1.0,0.0,1.0]
    pt=(variables=all_variables(m),values=x)
    @test correction_residual(o,x)≈ac_primal_residual(m,pt)
    lin=correction_linearization(o,x);d=[0.13,-0.11,0.02];h=1e-6
    @test norm((correction_values(o,x+h*d)-correction_values(o,x-h*d))/(2h)-lin.J*d,Inf)<1e-8
    @test all(lin.lower[1:length(o.al)].==o.al)
    result,stats=ac_linear_correction(m,pt;deadline=time()+15,max_rounds=12,lp_seconds=2)
    @test stats["max_primal_residual"]<=1e-8
    @test stats["accepted_steps"]>0
    @test all(!r["native_stored_start"] && r["complete_start_api_status"]===nothing &&
        r["presolve_requested"]=="on" && !r["native_useful_basis_bypassed_presolve"] for r in stats["rounds"])
    @test lower_bound(v)==0.5 && upper_bound(v)==1.5
    expired,record=ac_linear_correction(m,pt;deadline=time()-1)
    @test record["termination"]=="correction_deadline"
    @test expired.values==pt.values
    @test isempty(record["rounds"])
    # Inconsistent linearized subproblem never changes the original point/model.
    bad=Model();@variable(bad,0<=z<=1,start=0.5)
    @constraint(bad,z>=2);@objective(bad,Max,z)
    point=(variables=all_variables(bad),values=[0.5])
    stopped,record=ac_linear_correction(bad,point;deadline=time()+5)
    @test stopped.values==point.values
    @test record["termination"]=="linearized_solve_failed"
    @test record["max_primal_residual"]>1e-8
end

@testset "GO3 fresh presolve rejects inherited-start path and audits returned LP point" begin
    A=sparse([1.0 1.0 0.0;2.0 2.0 0.0;1e-10 0.0 8e4])
    c=[3e6,0.1,0.0];lb=[0.0,0.0,0.5];ub=[1.0,1.0,0.5]
    rhs=[1.0,2.0,4e4+1e-10]
    # Deliberately poor reference point is NOT installed into native HiGHS.
    reference=[1e10,-1e10,0.0];original=copy(reference)
    point,stats=correction_native_lp(A,c,lb,ub,rhs,rhs,reference;seconds=10)
    @test point!==nothing
    @test stats["native_model_status"]==HiGHS.kHighsModelStatusOptimal
    @test stats["native_presolve_observed"]
    @test !stats["native_useful_basis_bypassed_presolve"]
    @test stats["complete_start_api_status"]===nothing && !stats["native_stored_start"]
    @test stats["original_linearization_residual"]<=1e-8
    @test maximum(abs.(A*point-rhs))<=1e-8
    @test dot(c,point)≈3e6 atol=1e-5
    @test reference==original
    @test stats["import_audit"]["domains_exact"] && stats["import_audit"]["objective_exact"]
end

@testset "GO3 adaptive correction shares protect future hours and finalization" begin
    cfg=Dict("ac_correction_budget_policy"=>"remaining_horizon_v1",
        "ac_correction_hour_seconds"=>600.0,"ac_correction_seconds"=>45.0,
        "ac_correction_min_hour_seconds"=>60.0,"ac_correction_share_multiplier"=>1.5,
        "ac_correction_future_hour_floor_seconds"=>20.0)
    budget=correction_interval_budget(cfg,48,6200.0;now=100.0)
    @test budget["hour_allowance_seconds"]≈1.5*6100/48
    @test budget["hour_allowance_seconds"]>45
    @test budget["hour_deadline"]<=6200.0-budget["future_hours_reserved_seconds"]
    @test budget["slp_seconds"]==45.0
    @test !budget["global_deadline_reset"]
    last=correction_interval_budget(cfg,1,6200.0;now=100.0)
    @test last["hour_allowance_seconds"]==600.0
    tight=correction_interval_budget(cfg,48,110.0;now=100.0)
    @test 0<=tight["hour_allowance_seconds"]<=10/48+1e-12
    @test tight["hour_deadline"]<=110.0
    expired=correction_interval_budget(cfg,48,99.0;now=100.0)
    @test expired["hour_allowance_seconds"]==0
    @test correction_fallback_budget(120.0,300.0;now=100.0,adaptive=true)==120.0
    @test correction_fallback_budget(120.0,180.0;now=100.0,adaptive=true)==58.5
    @test correction_fallback_budget(120.0,99.0;now=100.0,adaptive=true)==0.0
    @test correction_fallback_budget(12.0,180.0;now=100.0)==12.0
    fixed=correction_interval_budget(Dict(),48,6200.0;now=100.0)
    @test fixed["hour_allowance_seconds"]==45.0 && fixed["slp_seconds"]==15.0
    @test_throws ErrorException correction_interval_budget(cfg,0,6200.0;now=100.0)
    @test_throws ErrorException correction_interval_budget(merge(cfg,Dict("ac_correction_budget_policy"=>"unknown")),48,6200.0;now=100.0)
    @test_throws ErrorException correction_interval_budget(merge(cfg,Dict("ac_correction_share_multiplier"=>NaN)),48,6200.0;now=100.0)
end

@testset "GO3 source AC correction, discrete shunts, reserves and fallback" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","source_features_problem.json"))
    for (j,b) in enumerate(raw["network"]["bus"])
        b["initial_status"]["vm"]=1.0-0.005*j
        b["initial_status"]["va"]=0.04+0.01*j
    end
    original=deepcopy(raw);input=GO3.process_input_data(raw)
    scheduler=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"mip_rel_gap"=>1e-6,
        "primal_feasibility_tolerance"=>1e-9,"mip_feasibility_tolerance"=>1e-9)
    _,schedule=schedule_source_balances(input;optimizer=scheduler,time_limit=10,
        set_silent=true,include_reserves=true,consumer_dominance=true)
    curves=fixed_schedule_power_curves(input,schedule)
    working=GO3.tighten_bounds_using_ramp_limits(input,schedule.on_status,schedule.real_power)
    opt=optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps","print_level"=>0,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes","tol"=>1e-9,"constr_viol_tol"=>1e-9)
    seed=nothing;previous=nothing
    on0=Dict(u=>schedule.on_status[u][1] for u in input.sdd_ids)
    p0=Dict(u=>schedule.real_power[u][1] for u in input.sdd_ids)
    initial_model,_=build_reserve_aware_ac(working,input,1;on_status=on0,real_power=p0,curves)
    set_optimizer(initial_model,opt)
    initial_record=initialize_ac_correction!(initial_model,input,1,p0,
        Dict(u=>schedule.reactive_power[u][1] for u in input.sdd_ids),nothing)
    @test initial_record["branch_flow_starts_recomputed"]==3
    @test initial_record["source_angle_reference_shift"]!=0
    oracle=correction_oracle(initial_model)
    gx=correction_values(oracle,[start_value(v) for v in oracle.variables])
    balances=Set([c for group in (initial_model[:p_balance],initial_model[:q_balance]) for c in group])
    branch_equalities=0
    for (k,cref) in enumerate(oracle.nl_refs)
        if constraint_object(cref).set isa MOI.EqualTo && !(cref in balances)
            @test abs(gx[k]-oracle.nl_lower[k])<1e-10
            branch_equalities+=1
        end
    end
    @test branch_equalities==12
    for i in input.periods
        on=Dict(u=>schedule.on_status[u][i] for u in input.sdd_ids)
        power=Dict(u=>schedule.real_power[u][i] for u in input.sdd_ids)
        if i>1
            GO3.tighten_bounds_at_interval_using_ramp_limits!(working,i,
                Dict(u=>schedule.on_status[u][i-1] for u in input.sdd_ids),
                Dict(u=>previous["simple_dispatchable_device"][u]["p_on"] for u in input.sdd_ids),on)
        end
        m,result=compute_corrected_ac(working,input,i;on_status=on,real_power=power,
            reactive_power=Dict(u=>schedule.reactive_power[u][i] for u in input.sdd_ids),curves,
            optimizer=opt,deadline=time()+40,interval_seed=seed,
            max_rounds=i==2 ? 0 : 8,slp_seconds=8,fallback_seconds=10,adaptive_budget=true)
        @test raw==original
        @test !ac_requires_stop(m.ext[:reserve_ac],true)
        @test all(isinteger,[d["step"] for d in values(result["shunt"])])
        @test m.ext[:reserve_ac]["original_bounds"]
        @test m.ext[:reserve_ac]["products"]==10
        @test ac_primal_residual(m,m.ext[:correction_point])<=1e-8
        if i==2
            # A previous-hour point can already be valid, so explicitly perturb
            # a voltage to exercise the bounded fallback without faking status.
            valid=m.ext[:correction_point]
            bad=(variables=valid.variables,values=copy(valid.values))
            voltage=m[:vm][first(input.bus_ids)]
            k=findfirst(==(voltage),bad.variables)
            bad.values[k]=max(lower_bound(voltage),bad.values[k]-0.01)
            @test ac_primal_residual(m,bad)>1e-8
            repaired,phase=correction_ipopt_fallback!(m,opt,bad;deadline=time()+15,seconds=10)
            @test phase["fallback"]
            @test phase["max_primal_residual"]<=1e-8
            @test phase["start"]["complete_primal_start"]["complete"]
            @test ac_primal_residual(m,repaired)<=1e-8
        end
        for u in input.sdd_ids
            p=result["simple_dispatchable_device"][u]["p_on"]
            @test p>=input.sdd_ts_lookup[u]["p_lb"][i]*on[u]-1e-8
            @test p<=input.sdd_ts_lookup[u]["p_ub"][i]*on[u]+1e-8
        end
        o=correction_oracle(m);point=m.ext[:correction_point]
        @test correction_residual(o,point.values)≈ac_primal_residual(m,point) atol=1e-10
        lin=correction_linearization(o,point.values)
        direction=[sin(k) for k in eachindex(point.values)];h=1e-6
        @test norm((correction_values(o,point.values+h*direction)-correction_values(o,point.values-h*direction))/(2h)-lin.J*direction,Inf)<1e-6
        seed=capture_ac_interval_start(m,input,i;point)
        previous=result
    end
end
