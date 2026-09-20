using Test, Random
include(joinpath(@__DIR__,"..","src","solve_reserve_benders_worker.jl"))

config=JSON.parsefile(joinpath(@__DIR__,"..","config","tiny_reserve_benders_native_guard.json"))
identity=native_highs_identity(config)
println("NATIVE_GUARD_IDENTITY ",JSON.json(identity))
directory=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="native_guard_math_")
rng=MersenneTwister(37)

@testset "Optional objective-clique cap retains exhaustive tiny MIP optima" begin
    for n in 5:12
        costs=Float64.(rand(rng,-8:8,n));costs[costs.==0].=1.0
        expected=Inf
        for bits in 0:(2^n-1)
            x=[Float64((bits>>(j-1))&1) for j in 1:n]
            all(x[j]+x[mod1(j+1,n)]<=1 for j in 1:n) || continue
            expected=min(expected,sum(costs.*x)+0.375*max(0,2-sum(x)))
        end
        for cap in (0,4096,typemax(Int32))
            model=direct_model(HiGHS.Optimizer())
            path=joinpath(directory,"n$(n)_cap$(cap).log")
            try
                set_optimizer_attribute(model,"threads",1)
                set_optimizer_attribute(model,"parallel","off")
                set_optimizer_attribute(model,"presolve","off")
                set_optimizer_attribute(model,"mip_objective_clique_max_size",cap)
                set_optimizer_attribute(model,"mip_rel_gap",1e-9)
                set_optimizer_attribute(model,"mip_feasibility_tolerance",1e-9)
                set_optimizer_attribute(model,"log_dev_level",1)
                set_optimizer_attribute(model,"log_file",path)
                set_optimizer_attribute(model,"log_to_console",false)
                set_time_limit_sec(model,10)
                @variable(model,x[1:n],Bin)
                @variable(model,y>=0)
                @constraint(model,[j=1:n],x[j]+x[mod1(j+1,n)]<=1)
                @constraint(model,y>=2-sum(x))
                @objective(model,Min,sum(costs[j]*x[j] for j in 1:n)+0.375*y)
                optimize!(model)
                @test termination_status(model)==MOI.OPTIMAL
                @test abs(objective_value(model)-expected)<=1e-8
                @test abs(objective_bound(model)-expected)<=1e-8
                @test all(abs.(value.(x).-round.(value.(x))).<=1e-8)
                @test all(value(x[j])+value(x[mod1(j+1,n)])<=1+1e-8 for j in 1:n)
                @test value(y)>=max(0,2-sum(value.(x)))-1e-8
            finally
                finalize(backend(model))
            end
            log=read(path,String)
            @test occursin("GO3-HIGHS-Setup stage=objective_clique_partition",log)
            @test occursin("optional_objective_clique_skipped",log)==(cap==0)
        end
    end
end

@testset "Optional objective-clique cap does not repair infeasibility" begin
    for cap in (0,4096,typemax(Int32))
        model=direct_model(HiGHS.Optimizer())
        try
            set_optimizer_attribute(model,"threads",1)
            set_silent(model)
            set_optimizer_attribute(model,"mip_objective_clique_max_size",cap)
            set_time_limit_sec(model,10)
            @variable(model,x[1:3],Bin)
            @constraint(model,sum(x)==0.5)
            @objective(model,Min,sum(x))
            optimize!(model)
            @test termination_status(model)==MOI.INFEASIBLE
            @test primal_status(model)==MOI.NO_SOLUTION
        finally
            finalize(backend(model))
        end
    end
end
println("NATIVE_GUARD_MATH_PASS ",JSON.json(Dict("tiny_only"=>true,"full_case_runs"=>0,
    "known_optimum_fixtures"=>8,"feasible_solves"=>24,"infeasible_solves"=>3,"identity"=>identity)))
