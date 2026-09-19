using Test
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))

@testset "GO3 isolated native option and status contracts" begin
    config=JSON.parsefile(joinpath(@__DIR__,"..","config","tiny_isolated_scheduling.json"))
    before=deepcopy(config)
    options=isolated_options(config)
    @test config==before
    @test options["threads"]==1
    @test options["parallel"]=="off"
    @test options["mip_rel_gap"]==config["scheduling_relative_gap"]
    @test options["mip_feasibility_tolerance"]==1e-9
    @test options["primal_feasibility_tolerance"]==1e-9
    @test options["highs_analysis_level"]==384
    native=HiGHS.Optimizer()
    try
        for (key,value) in options
            MOI.set(native,MOI.RawOptimizerAttribute(key),value)
            @test MOI.get(native,MOI.RawOptimizerAttribute(key))==value
        end
        @test MOI.get(native,MOI.RawOptimizerAttribute("presolve"))=="choose"
    finally
        finalize(native)
    end
    for (status,expected) in ((7,MOI.OPTIMAL),(8,MOI.INFEASIBLE),(13,MOI.TIME_LIMIT),
            (17,MOI.INTERRUPTED),(0,MOI.OTHER_ERROR))
        @test isolated_termination(status)==expected
    end
    config["scheduling_native_parallel"]="bad"
    @test_throws Exception isolated_options(config)
    @test_throws Exception schedule_source_balances((;);optimizer=HiGHS.Optimizer,time_limit=1,
        storage_policy=ISOLATED_STORAGE_POLICY)
    stats=Dict{String,Any}("termination_code"=>MOI.OPTIMAL,"has_primal"=>true,"objective"=>2.5)
    result=isolated_result_facade([2.5],stats,Dict{String,Any}("threads"=>1))
    @test termination_status(result)==MOI.OPTIMAL
    @test primal_status(result)==MOI.FEASIBLE_POINT
    @test value(VariableRef(result,MOI.VariableIndex(1)))==2.5
    @test objective_value(result)==2.5
end
