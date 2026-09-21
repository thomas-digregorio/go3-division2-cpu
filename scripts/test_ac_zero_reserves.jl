# Tiny synthetic component tests only. Never a competition-case solve.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "Exact reserve zero propagation and original-row audits" begin
    m=Model()
    @variable(m,x>=0);@variable(m,y>=0);@variable(m,z>=0)
    @variable(m,dispatch>=0.125)
    a=@constraint(m,x+y<=0)
    b=@constraint(m,z-x<=0)
    @constraint(m,dispatch>=0.2)
    @objective(m,Min,dispatch+2x+3y+4z)
    original_rows=all_constraints(m;include_variable_in_set_constraints=true)
    original_variables=all_variables(m);objective=objective_function(m)
    record=compact_ac_zero_reserves!(m,[x,y,z];policy=AC_ZERO_RESERVES_POLICY)
    @test record["implied_zero_variables"]==3
    @test record["constant_satisfied_rows_removed"]==2
    @test record["proof_replayed"] && record["proof_tolerance"]==0.0
    @test !record["source_feasible_set_changed"] && !record["dispatch_or_PMIN_modified"]
    @test all(v->is_fixed(v) && fix_value(v)==0.0,[x,y,z])
    @test lower_bound(dispatch)==0.125 && !is_fixed(dispatch)
    @test all_variables(m)==original_variables
    @test JuMP.isequal_canonical(objective_function(m),objective)
    proof=m.ext[:ac_zero_reserve_proof]
    @test verify_ac_zero_reserve_proof!(m,proof.data)
    @test !is_valid(m,a) && !is_valid(m,b)
    point=Dict(x=>0.0,y=>0.0,z=>0.0,dispatch=>0.2)
    @test ac_removed_zero_rows_residual(m,point)==0.0
    point[x]=0.1
    @test ac_removed_zero_rows_residual(m,point)≈0.1
    @test ac_primal_residual(m,(variables=original_variables,values=[point[v] for v in original_variables]))≈0.1
    @test record["original_row_audits"]==3
    # Deliberately corrupt the induction order. The final fixed bounds cannot
    # substitute for the missing proof that x was zero before z was inferred.
    bad=merge(proof.data,(steps=reverse(proof.data.steps),))
    @test_throws ErrorException verify_ac_zero_reserve_proof!(m,bad)
    @test_throws ErrorException compact_ac_zero_reserves!(m,[x];policy=AC_ZERO_RESERVES_POLICY)
end

@testset "Exact zero reduction rejects approximate or circular inferences" begin
    m=Model()
    @variable(m,x>=0);@variable(m,y>=0);@variable(m,z>=0)
    @variable(m,nearzero>=0);@variable(m,negative>=-1)
    @variable(m,source_dispatch>=0)
    @constraint(m,x-y<=0);@constraint(m,y-x<=0)
    @constraint(m,nearzero<=1e-12)
    @constraint(m,negative+z<=0)
    @constraint(m,source_dispatch<=0)
    @objective(m,Min,x+y+z+nearzero)
    variables=all_variables(m);rows=all_constraints(m;include_variable_in_set_constraints=true)
    bounds=ac_variable_bounds(m)
    record=compact_ac_zero_reserves!(m,[x,y,z,nearzero,negative];policy=AC_ZERO_RESERVES_POLICY)
    @test record["implied_zero_variables"]==0
    @test record["constant_satisfied_rows_removed"]==0
    @test all_variables(m)==variables && ac_variable_bounds(m)==bounds
    @test all_constraints(m;include_variable_in_set_constraints=true)==rows
    @test !is_fixed(source_dispatch) # Dispatch is not an eligible auxiliary.
    @test_throws ErrorException compact_ac_zero_reserves!(Model(),VariableRef[];policy="typo")
    b=Model();@variable(b,binary,Bin);@objective(b,Min,binary)
    @test_throws ErrorException compact_ac_zero_reserves!(b,[binary];policy=AC_ZERO_RESERVES_POLICY)
    @test compact_ac_zero_reserves!(Model(),VariableRef[])["policy"]=="off"
    # Greater-than, equality, signed zero and explicit fixed-zero support.
    n=Model();@variable(n,f==0);@variable(n,a>=-0.0);@variable(n,b>=0)
    @constraint(n,-a>=-0.0);@constraint(n,b-f==0);@objective(n,Min,a+b)
    rec=compact_ac_zero_reserves!(n,[a,b];policy=AC_ZERO_RESERVES_POLICY)
    @test rec["implied_zero_variables"]==2 && rec["constant_satisfied_rows_removed"]==2
    # A constant INCONSISTENT row is retained, never repaired or discarded.
    inconsistent=Model();@variable(inconsistent,w>=0)
    badrow=@constraint(inconsistent,0.0*w<=-1.0)
    @objective(inconsistent,Min,w)
    rec=compact_ac_zero_reserves!(inconsistent,[w];policy=AC_ZERO_RESERVES_POLICY)
    @test rec["constant_satisfied_rows_removed"]==0 && is_valid(inconsistent,badrow)
    @test ac_primal_residual(inconsistent,(variables=[w],values=[0.0]))==1.0
    @test_throws ErrorException compact_ac_zero_reserves!(Model(),VariableRef[];
        policy=AC_ZERO_RESERVES_POLICY,max_passes=0)
    boxed=Model();@variable(boxed,0<=fixed_by_bounds<=0);@variable(boxed,derived>=0)
    @constraint(boxed,derived-fixed_by_bounds<=0);@objective(boxed,Min,derived)
    network_report=@constraint(boxed,fixed_by_bounds<=0)
    rec=compact_ac_zero_reserves!(boxed,[derived];policy=AC_ZERO_RESERVES_POLICY)
    @test rec["original_exact_zero_domains"]==1 && rec["implied_zero_variables"]==1
    @test is_valid(boxed,network_report) && rec["constant_satisfied_rows_removed"]==1
    @test !is_fixed(fixed_by_bounds) && lower_bound(fixed_by_bounds)==upper_bound(fixed_by_bounds)==0.0
    proof=boxed.ext[:ac_zero_reserve_proof].data
    bad_domains=copy(proof.initial_zero_domains)
    bad_domains[fixed_by_bounds]=(fixed=nothing,lower=0.0,upper=1.0)
    @test_throws ErrorException verify_ac_zero_reserve_proof!(boxed,
        merge(proof,(initial_zero_domains=bad_domains,)))
end

function zero_fixture_curves(input)
    (p_su=Dict(u=>zeros(3) for u in input.sdd_ids),p_sd=Dict(u=>zeros(3) for u in input.sdd_ids),
     supc_status=Dict(u=>zeros(Int,3) for u in input.sdd_ids),sdpc_status=Dict(u=>zeros(Int,3) for u in input.sdd_ids))
end

@testset "Reduced reserve LP agrees with every original source row" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    original_raw=deepcopy(raw);input=GO3.process_input_data(raw)
    opt=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false,
        "primal_feasibility_tolerance"=>1e-9,"dual_feasibility_tolerance"=>1e-9)
    for gu in (0,1),du in (0,1)
        on=Dict("g"=>gu,"d"=>du);p=Dict("g"=>Float64(gu),"d"=>Float64(du))
        q=Dict(u=>0.0 for u in input.sdd_ids)
        models=Model[]
        for reduce in (false,true)
            model=Model(opt)
            reserve=add_source_reserve_allocation!(model,input,1,p,q,on,zero_fixture_curves(input))
            @objective(model,Min,reserve.cost)
            if reduce
                record=compact_ac_zero_reserves!(model,
                    (v for group in values(reserve.variables) for v in group);policy=AC_ZERO_RESERVES_POLICY)
                @test record["implied_zero_variables"]>0
                @test record["constant_satisfied_rows_removed"]>0
            end
            optimize!(model)
            @test termination_status(model)==MOI.OPTIMAL
            @test ac_primal_residual(model,capture_complete_ac_primal(model))<=1e-8
            push!(models,model)
        end
        @test objective_value(models[1])≈objective_value(models[2]) atol=1e-8
        for (from,to) in ((models[1],models[2]),(models[2],models[1]))
            witness=Dict(name(v)=>value(v) for v in all_variables(from))
            @test isempty(primal_feasibility_report(to,Dict(v=>witness[name(v)] for v in all_variables(to));atol=1e-8))
        end
    end
    @test raw==original_raw
end

@testset "Exact reserve reduction survives AC rounding and fresh recovery" begin
    raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json"))
    original_raw=deepcopy(raw);input=GO3.process_input_data(raw)
    products=(:p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,:p_rru_off,:p_rrd_on,:p_rrd_off,:q_qru,:q_qrd)
    schedule=merge((on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids)),
        NamedTuple{products}(Tuple(Dict(u=>zeros(3) for u in input.sdd_ids) for _ in products)))
    optimizer=optimizer_with_attributes(Ipopt.Optimizer,"print_level"=>0,"max_iter"=>0,
        "max_wall_time"=>15.0,"tol"=>1e-9,"constr_viol_tol"=>1e-9,
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes")
    model,_=compute_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict(u=>1 for u in input.sdd_ids),real_power=Dict(u=>1.0 for u in input.sdd_ids),
        curves=fixed_schedule_power_curves(input,schedule),optimizer,set_silent=true,audit_phases=true,
        shunt_primal_start="within_interval_primal_dual_v1",rounded_seconds=15.0,rounded_max_iter=0,
        work_deadline=time()+120,numerical_recovery="adaptive_barrier_on_failed_residual_v1",
        recovery_seconds=30.0,recovery_max_iter=1000,numerics_policy=AC_NUMERICS_POLICY,
        initialization_policy=AC_INITIALIZATION_POLICY,schedule_seed=schedule,
        primal_guard=AC_PRIMAL_GUARD_POLICY,zero_reserve_policy=AC_ZERO_RESERVES_POLICY)
    info=model.ext[:reserve_ac]
    @test length(info["phases"])==3
    @test !ac_requires_stop(info,true)
    @test info["phases"][3]["max_primal_residual"]<=1e-8
    @test info["numerical_recovery"]["fresh_optimizer_instantiated"]
    @test info["zero_reserve_domains"]["proof_replayed"]
    @test info["zero_reserve_domains"]["original_row_audits"]>=3
    @test info["zero_reserve_domains"]["last_original_row_maximum_residual"]<=1e-8
    @test verify_ac_zero_reserve_proof!(model,model.ext[:ac_zero_reserve_proof].data)
    @test raw==original_raw
end
