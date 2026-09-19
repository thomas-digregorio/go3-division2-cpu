using Test, JSON
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

function ramp_fixture()
    ids=["g1","g2"]
    p0=6.371034820222844
    ramp=1.5525000000000002
    lookup=Dict(u=>Dict{String,Any}("bus"=>"b","device_type"=>"producer",
        "initial_status"=>Dict("on_status"=>1,"p"=>p0),
        "p_ramp_up_ub"=>ramp,"p_ramp_down_ub"=>ramp,
        "p_startup_ramp_ub"=>0.15525000000000003,"p_shutdown_ramp_ub"=>7.452000000000001)
        for u in ids)
    ts=Dict(u=>Dict("p_lb"=>[0.0,0.0],"p_ub"=>fill(7.452000000000001,2)) for u in ids)
    input=(sdd_ids=ids,periods=1:2,dt=[1.0,1.0],sdd_lookup=lookup,sdd_ts_lookup=ts)
    schedule=(on_status=Dict(u=>[1,1] for u in ids),
        real_power=Dict(u=>[p0-ramp,p0-2*ramp] for u in ids))
    input,schedule
end

@testset "GO3 exact ramp intersections prevent accumulated export imbalance" begin
    input,schedule=ramp_fixture()
    original=deepcopy(input)
    audits=Dict()
    for policy in AC_RAMP_BOUND_POLICIES
        working=tighten_ac_horizon_bounds(input,schedule;policy=policy)
        previous=Dict(u=>working.sdd_ts_lookup[u]["p_lb"][1]+7e-9 for u in input.sdd_ids)
        statuses=Dict(u=>1 for u in input.sdd_ids)
        tighten_ac_interval_bounds!(working,2,statuses,previous,statuses;policy=policy)
        data=Dict("time_series_output"=>Dict{String,Any}(
            "shunt"=>Any[],"simple_dispatchable_device"=>[
                Dict{String,Any}("uid"=>u,"on_status"=>[1,1],"q"=>[0.0,0.0],
                    "p_on"=>[previous[u],working.sdd_ts_lookup[u]["p_lb"][2]+1e-12])
                for u in input.sdd_ids]))
        _,projections=GO3.postprocess_solution_data(data,input,schedule)
        # Apply the corrected guard to both results to expose the legacy failure.
        audit=ac_export_projection_audit(input,projections,2;policy="exact_source_intersections_v1")
        audits[policy]=audit
        @test input==original
        @test input.sdd_ts_lookup["g1"]["p_lb"]==[0.0,0.0]
        @test !audit["source_bounds_changed"]
        @test !audit["official_tolerance_changed"]
        if policy=="legacy_tolerance_v1"
            @test audit["maximum_refined_bus_injection_change_pu"]>1e-8
            @test !audit["within_guard"]
            @test_throws ErrorException require_ac_export_projection(audit)
        else
            @test audit["maximum_refined_bus_injection_change_pu"]==0.0
            @test audit["within_guard"]
            @test isnothing(require_ac_export_projection(audit))
            for u in input.sdd_ids
                @test working.sdd_ts_lookup[u]["p_lb"][2]==
                    previous[u]-input.sdd_lookup[u]["p_ramp_down_ub"]
            end
        end
    end
    @test ac_ramp_bound_tolerance("exact_source_intersections_v1")==0.0
    @test ac_ramp_bound_tolerance("legacy_tolerance_v1")==1e-8
    @test_throws ErrorException ac_ramp_bound_tolerance("relax_source_bounds")
    @test_throws ErrorException ac_export_projection_audit(input,[],3)
    @test_throws ErrorException ac_export_projection_audit(input,[],1.5)
    @test_throws ErrorException ac_export_projection_audit(input,[("g1",0,0.0)],1)
    @test_throws ErrorException ac_export_projection_audit(input,[("g1",1,NaN)],1)
end

@testset "GO3 exact ramp intersections preserve positive PMIN and reject empty domains" begin
    input,schedule=ramp_fixture()
    for u in input.sdd_ids
        input.sdd_ts_lookup[u]["p_lb"]=[4.7,3.1]
    end
    original=deepcopy(input)
    working=tighten_ac_horizon_bounds(input,schedule;policy="exact_source_intersections_v1")
    @test input==original
    for u in input.sdd_ids
        @test all(working.sdd_ts_lookup[u]["p_lb"].>=input.sdd_ts_lookup[u]["p_lb"])
        @test all(working.sdd_ts_lookup[u]["p_ub"].<=input.sdd_ts_lookup[u]["p_ub"])
    end
    for u in working.sdd_ids
        working.sdd_ts_lookup[u]["p_lb"][2]=1.0
        working.sdd_ts_lookup[u]["p_ub"][2]=2.0
        working.sdd_lookup[u]["p_ramp_up_ub"]=0.0
    end
    status=Dict(u=>1 for u in input.sdd_ids)
    previous=Dict(u=>1.0-5e-9 for u in input.sdd_ids)
    @test_throws ErrorException tighten_ac_interval_bounds!(working,2,status,previous,status;
        policy="exact_source_intersections_v1")
    @test input==original
    future=ac_export_projection_audit(input,[("g1",2,0.1)],1;
        policy="exact_source_intersections_v1")
    @test future["within_guard"]
    @test future["maximum_unfinished_bus_injection_change_pu"]==0.1
    input.sdd_lookup["g2"]["device_type"]="consumer"
    signed=ac_export_projection_audit(input,[("g1",1,2e-9),("g2",1,2e-9)],1;
        policy="exact_source_intersections_v1")
    @test signed["within_guard"]
    @test signed["maximum_refined_bus_injection_change_pu"]==0.0
end
