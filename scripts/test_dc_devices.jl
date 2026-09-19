# Original two-bus fixture only. No competition input or optimized external start.
using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const DC_TINY=joinpath(@__DIR__,"..","tmp","official_tiny","dc_problem.json")

@testset "GO3 DC source initialization and exact terminal domains" begin
    raw=JSON.parsefile(DC_TINY)
    original=deepcopy(raw)
    input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),
        reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
    candidate=candidate_from_schedule(input,schedule)
    d=only(candidate["time_series_output"]["dc_line"])
    source=only(raw["network"]["dc_line"])
    for k in ("pdc_fr","qdc_fr","qdc_to")
        @test d[k]==fill(source["initial_status"][k],3)
        @test all(opf_view(candidate,input.periods)[i]["dc_line"]["dc0"][k]==d[k][i] for i in 1:3)
    end
    curves=fixed_schedule_power_curves(input,schedule)
    model,_=build_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves)
    fr=("dc0","b0","b1"); to=("dc0","b1","b0")
    for key in (fr,to)
        @test lower_bound(model[:p_branch][key])==-source["pdc_ub"]
        @test upper_bound(model[:p_branch][key])==source["pdc_ub"]
        @test !is_fixed(model[:p_branch][key])
    end
    for (key,side) in ((fr,"fr"),(to,"to"))
        @test lower_bound(model[:q_branch][key])==source["qdc_"*side*"_lb"]
        @test upper_bound(model[:q_branch][key])==source["qdc_"*side*"_ub"]
    end
    conservation=[c for c in all_constraints(model,AffExpr,MOI.EqualTo{Float64})
        if normalized_coefficient(c,model[:p_branch][fr])==1.0 &&
           normalized_coefficient(c,model[:p_branch][to])==1.0 && normalized_rhs(c)==0.0]
    @test length(conservation)==1
    @test raw==original
end

@testset "GO3 optimized DC link survives AC export and within-run starts" begin
    raw=JSON.parsefile(DC_TINY)
    original=deepcopy(raw)
    input=GO3.process_input_data(raw)
    schedule=(on_status=Dict(u=>ones(Int,3) for u in input.sdd_ids),
        real_power=Dict(u=>ones(3) for u in input.sdd_ids),
        reactive_power=Dict(u=>zeros(3) for u in input.sdd_ids))
    curves=fixed_schedule_power_curves(input,schedule)
    opt=optimizer_with_attributes(Ipopt.Optimizer,"linear_solver"=>"mumps",
        "bound_relax_factor"=>0.0,"honor_original_bounds"=>"yes","tol"=>1e-9,
        "constr_viol_tol"=>1e-9,"max_wall_time"=>15.0,"max_iter"=>1000,"print_level"=>0)
    model,sol=compute_reserve_aware_ac(deepcopy(input),input,1;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves,
        optimizer=opt,set_silent=true,shunt_primal_start="within_interval_primal_dual_v1",
        audit_phases=true,rounded_seconds=15.0)
    @test !ac_requires_stop(model.ext[:reserve_ac],true)
    dc=sol["dc_line"]["dc0"]
    @test dc["pdc_fr"]>0.05  # Not accidentally fixed at zero or the source initial value.
    @test abs(dc["pdc_fr"]-0.35)>1e-4
    @test abs(value(model[:p_branch][("dc0","b0","b1")])+
              value(model[:p_branch][("dc0","b1","b0")]))<=1e-8
    results=[deepcopy(sol) for _ in input.periods]
    exported,_=construct_audited_ac_solution(input,schedule,results,3;
        policy="exact_source_intersections_v1")
    d=only(JSON.parse(JSON.json(exported))["time_series_output"]["dc_line"])
    for k in ("pdc_fr","qdc_fr","qdc_to")
        @test d[k]==fill(dc[k],3)
    end
    seed=capture_ac_interval_start(model,input,1)
    next_model,_=build_reserve_aware_ac(deepcopy(input),input,2;
        on_status=Dict(u=>1 for u in input.sdd_ids),
        real_power=Dict(u=>1.0 for u in input.sdd_ids),curves=curves)
    set_optimizer(next_model,opt)
    record=apply_ac_interval_start!(next_model,input,2,seed,Dict(u=>1.0 for u in input.sdd_ids))
    @test record["complete_current_primal_vector"]
    for symbol in (:p_branch,:q_branch), key in (("dc0","b0","b1"),("dc0","b1","b0"))
        @test start_value(next_model[symbol][key])≈value(model[symbol][key]) atol=1e-12
    end
    @test raw==original
end
