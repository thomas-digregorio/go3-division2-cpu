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

@testset "GO3 memory-conscious native presolve contract" begin
    config=JSON.parsefile(joinpath(@__DIR__,"..","config","tiny_compacted_scheduling.json"))
    @test config["scheduling_native_presolve_policy"]=="skip_parallel_rows_cols_v1"
    baseline=copy(config);delete!(baseline,"scheduling_native_presolve_policy")
    options=isolated_options(config)
    @test options["presolve_rule_off"]==8192
    @test filter(p->first(p)!="presolve_rule_off",options)==isolated_options(baseline)
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
    for policy in ("default","skip_parallel_rows_cols_v1"), infeasible in (false,true)
        fixture=Model(HiGHS.Optimizer);set_silent(fixture)
        config["scheduling_native_presolve_policy"]=policy
        for (key,value) in isolated_options(config)
            set_optimizer_attribute(fixture,key,value)
        end
        @variable(fixture,u[1:2],Bin)
        @variable(fixture,0<=p[1:2]<=4)
        @constraint(fixture,[j=1:2],p[j]>=2*u[j])
        @constraint(fixture,[j=1:2],p[j]<=4*u[j])
        @constraint(fixture,sum(p)==(infeasible ? 9 : 5))
        @constraint(fixture,2*sum(p)==(infeasible ? 18 : 10))
        @objective(fixture,Min,sum(p)+0.25*sum(u))
        optimize!(fixture)
        @test termination_status(fixture)==(infeasible ? MOI.INFEASIBLE : MOI.OPTIMAL)
        if !infeasible
            @test objective_value(fixture)≈5.5
            @test sum(value.(p))≈5
            @test value.(u)≈[1.0,1.0]
        end
    end
    config["scheduling_native_presolve_policy"]="unknown"
    @test_throws Exception isolated_options(config)
end
