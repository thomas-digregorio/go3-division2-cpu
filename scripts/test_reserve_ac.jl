# Tiny synthetic component tests. No competition input or saved solution is read.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const RES_TINY=joinpath(@__DIR__,"..","tmp","official_tiny","dominance_problem.json")
@assert occursin("official_tiny",RES_TINY)
const RES_OPT=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,
    "primal_feasibility_tolerance"=>1e-9,"dual_feasibility_tolerance"=>1e-9,
    "time_limit"=>10.0,"output_flag"=>false)

function reserve_test_curves(input;su=Dict(),sd=Dict())
    nt=length(input.periods)
    psu=Dict(u=>fill(Float64(get(su,u,0.0)),nt) for u in input.sdd_ids)
    psd=Dict(u=>fill(Float64(get(sd,u,0.0)),nt) for u in input.sdd_ids)
    (p_su=psu,p_sd=psd,supc_status=Dict(u=>Int.(psu[u].>0) for u in input.sdd_ids),
        sdpc_status=Dict(u=>Int.(psd[u].>0) for u in input.sdd_ids))
end

function reserve_reference(input,i,p,q,on,curves)
    opf=Dict("simple_dispatchable_device"=>Dict(u=>Dict(
        "p_on"=>p[u]-curves.p_su[u][i]-curves.p_sd[u][i],"q"=>q[u]) for u in input.sdd_ids))
    GO3.make_reserve_model(input,i,opf,on,
        Dict(u=>curves.supc_status[u][i] for u in input.sdd_ids),
        Dict(u=>curves.sdpc_status[u][i] for u in input.sdd_ids),
        Dict(u=>curves.p_su[u][i] for u in input.sdd_ids),
        Dict(u=>curves.p_sd[u][i] for u in input.sdd_ids))
end

@testset "GO3 source reserve LP equivalence and all products" begin
    raw=JSON.parsefile(RES_TINY)
    # Nonzero prices, high requirements and headroom scarcity exercise all ten
    # products and all eight penalized shortages on unequal interval lengths.
    for d in raw["network"]["simple_dispatchable_device"]
        for key in keys(d)
            startswith(key,"p_") && endswith(key,"_ub") && occursin("res",key) && (d[key]=4.0)
        end
    end
    zone=only(raw["network"]["active_zonal_reserve"])
    for (key,val) in (("REG_UP",0.5),("REG_DOWN",0.3),("SYN",1.3),("NSYN",0.8))
        zone[key]=val
    end
    for ts in raw["time_series_input"]["simple_dispatchable_device"]
        ts["p_lb"]=fill(0.1,3)
        ts["p_ub"]=fill(ts["uid"]=="g" ? 3.0 : 2.0,3)
        for (j,key) in enumerate(sort(filter(k->endswith(k,"_cost"),collect(keys(ts)))))
            ts[key]=[0.01j,0.02j,0.03j]
        end
    end
    for (section,keys_) in (("active_zonal_reserve",("RAMPING_RESERVE_UP","RAMPING_RESERVE_DOWN")),
            ("reactive_zonal_reserve",("REACT_UP","REACT_DOWN")))
        for ts in raw["time_series_input"][section], key in keys_
            ts[key]=[2.0,3.0,5.0]
        end
    end
    source_copy=deepcopy(raw)
    input=GO3.process_input_data(raw)
    for state in 1:4, i in input.periods
        on=Dict("g"=>(state in (1,3) ? 1 : 0),"d"=>(state in (1,2) ? 1 : 0))
        curves=reserve_test_curves(input;
            su=state==2 ? Dict("g"=>0.15) : Dict(),
            sd=state==3 ? Dict("d"=>0.1) : Dict())
        p=Dict(u=>(on[u]==1 ? (u=="g" ? 0.7 : 0.5) : curves.p_su[u][i]+curves.p_sd[u][i])
            for u in input.sdd_ids)
        q=Dict(u=>(on[u]+curves.supc_status[u][i]+curves.sdpc_status[u][i]>0 ? 0.15 : 0.0)
            for u in input.sdd_ids)
        reference=reserve_reference(input,i,p,q,on,curves)
        set_optimizer(reference,RES_OPT)
        optimize!(reference)
        model=Model(RES_OPT)
        r=add_source_reserve_allocation!(model,input,i,p,q,on,curves)
        @objective(model,Min,r.cost)
        optimize!(model)
        @test termination_status(reference)==MOI.OPTIMAL
        @test termination_status(model)==MOI.OPTIMAL
        @test objective_value(model) ≈ -objective_value(reference) atol=1e-7
        # Cross-check both optimal points against the other formulation, not
        # merely matching an objective that could mask an omitted constraint.
        byname=Dict(name(v)=>value(v) for v in all_variables(model))
        witness=Dict(v=>byname[name(v)] for v in all_variables(reference))
        @test isempty(primal_feasibility_report(reference,witness;atol=1e-8))
        refvalues=Dict(name(v)=>value(v) for v in all_variables(reference))
        back=Dict(v=>(haskey(refvalues,name(v)) ? refvalues[name(v)] : maximum(p[u] for u in input.sdd_ids_producer))
            for v in all_variables(model))
        @test isempty(primal_feasibility_report(model,back;atol=1e-8))
        @test coefficient(r.cost,model[:p_rgu]["g"]) ==
            input.dt[i]*input.sdd_ts_lookup["g"]["p_reg_res_up_cost"][i]
        @test coefficient(r.cost,model[:p_scr_slack]["pr"]) == input.dt[i]*zone["SYN_vio_cost"]
    end
    @test raw==source_copy
end

@testset "GO3 reserve demand tracks optimized dispatch" begin
    raw=JSON.parsefile(RES_TINY)
    zone=only(raw["network"]["active_zonal_reserve"])
    for k in ("REG_UP","REG_DOWN","NSYN")
        zone[k]=0.0
    end
    zone["SYN"]=1.0
    zone["SYN_vio_cost"]=100.0
    zone["NSYN_vio_cost"]=0.0
    # No eligible reserve provider, so the shortage is exactly max generation.
    for d in raw["network"]["simple_dispatchable_device"], key in keys(d)
        startswith(key,"p_") && endswith(key,"_ub") && occursin("res",key) && (d[key]=0.0)
    end
    input=GO3.process_input_data(raw)
    model=Model(RES_OPT)
    @variable(model,0.2 <= pg <= 2.0)
    p=Dict("g"=>pg,"d"=>1.0)
    q=Dict("g"=>0.0,"d"=>0.0)
    on=Dict("g"=>1,"d"=>1)
    r=add_source_reserve_allocation!(model,input,2,p,q,on,reserve_test_curves(input))
    @objective(model,Min,r.cost)
    optimize!(model)
    @test termination_status(model)==MOI.OPTIMAL
    @test value(pg) ≈ 0.2 atol=1e-8
    @test value(r.peak["pr"]) ≈ 0.2 atol=1e-8
    @test value(model[:p_scr_slack]["pr"]) ≈ 0.2 atol=1e-8
    fix(pg,1.0;force=true)
    optimize!(model)
    @test objective_value(model) ≈ 100.0 atol=1e-7
    @test value(r.peak["pr"]) ≈ 1.0 atol=1e-8
    bad=deepcopy(input)
    bad.azr_lookup["pr"]["SYN"]=-1.0
    @test_throws ErrorException add_source_reserve_allocation!(Model(),bad,2,
        Dict("g"=>1.0,"d"=>1.0),q,on,reserve_test_curves(input))
end

@testset "GO3 AC reserve source bounds and original inputs" begin
    raw=JSON.parsefile(RES_TINY)
    saved=deepcopy(raw)
    input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids))
    curves=fixed_schedule_power_curves(input,schedule)
    @test all(x->all(iszero,x),values(curves.p_su))
    working=deepcopy(input)
    working.sdd_ts_lookup["g"]["p_ub"][2]=1.2
    ipopt=optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes","tol"=>1e-9,
        "constr_viol_tol"=>1e-9,"max_wall_time"=>15.0,"max_iter"=>500,"print_level"=>0)
    model,sol=compute_reserve_aware_ac(working,input,2;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves,
        optimizer=ipopt,set_silent=true)
    @test termination_status(model) in (MOI.LOCALLY_SOLVED,MOI.ALMOST_LOCALLY_SOLVED)
    @test model.ext[:reserve_ac]["original_bounds"]===true
    @test model.ext[:reserve_ac]["products"]==10
    @test model.ext[:reserve_ac]["physical_balance_policy"]=="zero_slack_candidate_restriction"
    for key in (:p_balance_slack_pos,:p_balance_slack_neg,:q_balance_slack_pos,:q_balance_slack_neg)
        @test all(v->lower_bound(v)==0.0 && upper_bound(v)==0.0,model[key])
    end
    @test upper_bound(model[:p_sdd]["g"])==1.2
    @test input.sdd_ts_lookup["g"]["p_ub"][2]==3.0
    @test haskey(sol,"bus")
    @test maximum(abs.(value.(model[:p_balance_slack_pos]))) < 1e-6
    @test raw==saved
    # A reserve allocation fixed to the AC solution must have the same optimal
    # cost under the unmodified original-bounds reference LP.
    p=Dict(u=>value(model[:p_sdd][u]) for u in input.sdd_ids)
    q=Dict(u=>value(model[:q_sdd][u]) for u in input.sdd_ids)
    reference=reserve_reference(input,2,p,q,Dict(u=>1 for u in input.sdd_ids),curves)
    set_optimizer(reference,RES_OPT)
    optimize!(reference)
    @test termination_status(reference)==MOI.OPTIMAL
    @test model.ext[:reserve_ac]["reserve_cost_at_solution"] ≈ -objective_value(reference) atol=1e-5
end
