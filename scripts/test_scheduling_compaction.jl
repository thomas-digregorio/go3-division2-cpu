using Test
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const COMPACT_TEST_ROOT=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="exact_compaction_tests_")

function compact_fixture(model,label)
    original=joinpath(COMPACT_TEST_ROOT,label,"original");compact=joinpath(COMPACT_TEST_ROOT,label,"compact")
    record=write_scheduling_spool(model,original)
    reduced=compact_scheduling_spool(original,compact;require_exit=false)
    audit=verify_compaction_proof(original,compact)
    @test audit["pass"]
    @test audit["original_rows_checked"]==record["rows"]
    @test audit["original_columns_checked"]==record["variables"]
    original,compact,record,reduced
end

@testset "GO3 exact zero alias compaction mathematical equivalence" begin
    for sense in (MOI.MIN_SENSE,MOI.MAX_SENSE)
        model=Model();@variable(model,0<=x<=1);@variable(model,y,binary=true)
        @variable(model,0<=z<=2);@variable(model,0<=t<=2);@variable(model,0<=s<=2)
        @constraint(model,x==y);@constraint(model,z+t<=0);@constraint(model,s>=x)
        @objective(model,Min,3x+0.25s+0.125);set_objective_sense(model,sense)
        original,compact,record,c=compact_fixture(model,"simple"*string(sense))
        @test c["variables"]==2
        @test c["zero_columns"]==2
        @test c["aliased_columns"]==1
        @test c["removed_tautologies"]==2
        mapping=spool_array(compact,"original_to_compact",Int32,5)
        @test collect(spool_array(compact,"integrality",Int32,2))==[1,0]
        for xv in (0.0,1.0),yv in (0.0,1.0),zv in (0.0,1.0),tv in (0.0,1.0),sv in (0.0,1.0,2.0)
            p=[xv,yv,zv,tv,sv];valid=check_original_spool_point(original,record,p)["pass"]
            @test valid==(xv==yv && zv==0 && tv==0 && sv>=xv)
            if valid
                cp=[xv,sv];@test [j==0 ? 0.0 : cp[j] for j in mapping]==p
                @test check_original_spool_point(compact,c,cp)["pass"]
            end
        end
        native=HiGHS.Optimizer()
        try
            MOI.set(native,MOI.RawOptimizerAttribute("threads"),1)
            MOI.set(native,MOI.RawOptimizerAttribute("output_flag"),false)
            load_spool_native!(native,compact,c)
            @test HiGHS.Highs_run(native)==HiGHS.kHighsStatusOk
            @test HiGHS.Highs_getModelStatus(native)==7
            cp=zeros(c["variables"])
            @test HiGHS.Highs_getSolution(native,cp,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk
            p=[j==0 ? 0.0 : cp[j] for j in mapping]
            @test check_original_spool_point(original,record,p)["pass"]
            set_optimizer(model,optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false))
            optimize!(model)
            @test objective_value(model)≈HiGHS.Highs_getObjectiveValue(native) atol=1e-12
        finally;finalize(native);end
        open(joinpath(compact,"original_to_compact.bin"),"a") do io;write(io,UInt8(1));end
        @test_throws Exception validate_compact_spool(original,compact)
    end
    # Signed variables may cancel: x+y=0 does NOT imply either is zero.
    model=Model();@variable(model,-2<=x<=2);@variable(model,-2<=y<=2)
    @constraint(model,x+y==0);@objective(model,Min,1.0*x)
    _,_,_,c=compact_fixture(model,"signed")
    @test c["zero_columns"]==0
    @test c["aliased_columns"]==0
    # Nonzero fixed values and empty infeasible rows are never discarded.
    model=Model();@variable(model,x);fix(x,2);@objective(model,Min,1.0*x)
    @constraint(model,0.0*x>=1)
    original,compact,record,c=compact_fixture(model,"infeasible")
    @test c["variables"]==1
    @test c["rows"]==1
    @test !check_original_spool_point(original,record,[2.0])["pass"]
    # Any rounded coefficient merger fails closed rather than changing math.
    model=Model();@variable(model,0<=x<=1);@variable(model,0<=y<=1)
    @constraint(model,x==y);@constraint(model,0.1*x+0.2*y<=1);@objective(model,Min,1.0*x)
    original=joinpath(COMPACT_TEST_ROOT,"inexact_original");write_scheduling_spool(model,original)
    @test_throws Exception compact_scheduling_spool(original,joinpath(COMPACT_TEST_ROOT,"inexact_compact");require_exit=false)
end

@testset "GO3 exact compaction source feature and DC fixtures" begin
    for fixture in ("source_features_problem.json","dc_problem.json"),reserves in (false,true)
        raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny",fixture));before=deepcopy(raw)
        input=GO3.process_input_data(raw)
        model=build_source_scheduling(input;include_reserves=reserves,consumer_dominance=true)
        original,compact,record,c=compact_fixture(model,fixture*string(reserves))
        @test raw==before
        native=HiGHS.Optimizer()
        try
            MOI.set(native,MOI.RawOptimizerAttribute("threads"),1)
            MOI.set(native,MOI.RawOptimizerAttribute("output_flag"),false)
            MOI.set(native,MOI.RawOptimizerAttribute("mip_feasibility_tolerance"),1e-9)
            load_spool_native!(native,compact,c)
            @test HiGHS.Highs_run(native)==HiGHS.kHighsStatusOk
            @test HiGHS.Highs_getModelStatus(native)==7
            cp=zeros(c["variables"])
            @test HiGHS.Highs_getSolution(native,cp,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk
            mapping=spool_array(compact,"original_to_compact",Int32,record["variables"])
            point=[j==0 ? 0.0 : cp[j] for j in mapping]
            checked=check_original_spool_point(original,record,point)
            @test checked["pass"]
            @test checked["objective"]≈HiGHS.Highs_getObjectiveValue(native) atol=1e-8
            set_optimizer(model,optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false,
                "mip_feasibility_tolerance"=>1e-9));optimize!(model)
            @test objective_value(model)≈checked["objective"] atol=1e-8
        finally;finalize(native);end
    end
end
