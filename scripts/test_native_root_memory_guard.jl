using Test
include(joinpath(@__DIR__,"..","src","solve_reserve_benders_worker.jl"))

config=JSON.parsefile(joinpath(@__DIR__,"..","config","tiny_reserve_benders_root_memory.json"))
identity=native_highs_identity(config)
println("NATIVE_ROOT_MEMORY_IDENTITY ",JSON.json(identity))
directory=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="native_root_memory_math_")

@testset "Optional analytic center and root-only presolve preserve enumerated optima" begin
    for n in (5,7,9,11)
        expected=Inf
        for bits in 0:(2^n-1)
            x=[Float64((bits>>(j-1))&1) for j in 1:n]
            all(x[j]+x[mod1(j+1,n)]<=1 for j in 1:n) || continue
            expected=min(expected,-sum(x)+0.375*max(0,2-sum(x)))
        end
        for analytic in (true,false), root_only in (true,false)
            model=direct_model(HiGHS.Optimizer())
            path=joinpath(directory,"n$(n)_center$(analytic)_rootonly$(root_only).log")
            try
                for (key,value) in ("threads"=>1,"parallel"=>"off","presolve"=>"off",
                    "mip_objective_clique_max_size"=>0,"mip_compute_analytic_center"=>analytic,
                    "mip_root_presolve_only"=>root_only,
                    "mip_heuristic_run_feasibility_jump"=>false,"mip_heuristic_effort"=>0.0,
                    "mip_detect_symmetry"=>false,"mip_rel_gap"=>1e-9,
                    "highs_analysis_level"=>384,
                    "mip_feasibility_tolerance"=>1e-9,"log_dev_level"=>1,
                    "log_file"=>path,"log_to_console"=>false)
                    set_optimizer_attribute(model,key,value)
                    @test get_optimizer_attribute(model,key)==value
                end
                set_time_limit_sec(model,10)
                @variable(model,x[1:n],Bin)
                @variable(model,y>=0)
                @constraint(model,[j=1:n],x[j]+x[mod1(j+1,n)]<=1)
                @constraint(model,y>=2-sum(x))
                @objective(model,Min,-sum(x)+0.375*y)
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
            @test occursin("GO3-HIGHS-Root stage=first_lp_begin",log)
            @test occursin("GO3-HIGHS-Root stage=first_lp_complete",log)
            @test occursin("optional_analytic_center_skipped",log)==!analytic
            @test occursin("starting analytic centre calculation",log)==analytic
        end
    end
end

@testset "Root memory guard keeps infeasible integer models infeasible" begin
    for analytic in (true,false), root_only in (true,false)
        model=direct_model(HiGHS.Optimizer())
        try
            set_optimizer_attribute(model,"threads",1)
            set_silent(model)
            set_optimizer_attribute(model,"mip_compute_analytic_center",analytic)
            set_optimizer_attribute(model,"mip_root_presolve_only",root_only)
            set_time_limit_sec(model,10)
            @variable(model,x[1:5],Bin)
            @constraint(model,sum(x)==2.5)
            @objective(model,Min,sum(x))
            optimize!(model)
            @test termination_status(model)==MOI.INFEASIBLE
            @test primal_status(model)==MOI.NO_SOLUTION
        finally
            finalize(backend(model))
        end
    end
end
@testset "Root-only presolve API contract retains the initial MIP presolve" begin
    options=isolated_options(config)
    @test options["mip_root_presolve_only"]===true
    @test options["mip_compute_analytic_center"]===false
    @test !haskey(options,"presolve")
    model=HiGHS.Optimizer()
    try
        for (key,value) in options
            MOI.set(model,MOI.RawOptimizerAttribute(key),value)
            @test MOI.get(model,MOI.RawOptimizerAttribute(key))==value
        end
        @test MOI.get(model,MOI.RawOptimizerAttribute("presolve"))=="choose"
    finally
        finalize(model)
    end
    for bad in (0,1,"true",nothing)
        invalid=copy(config);invalid["scheduling_native_root_presolve_only"]=bad
        @test_throws Exception isolated_options(invalid)
    end
    for policy in (NATIVE_SETUP_GUARD_POLICY,"upstream_jll_v1")
        invalid=copy(config);invalid["scheduling_native_backend_policy"]=policy
        delete!(invalid,"scheduling_native_analytic_center")
        policy=="upstream_jll_v1" && delete!(invalid,"scheduling_native_objective_clique_max_size")
        @test_throws Exception isolated_options(invalid)
    end
end
println("NATIVE_ROOT_MEMORY_MATH_PASS ",JSON.json(Dict("tiny_only"=>true,"full_case_runs"=>0,
    "known_optimum_fixtures"=>4,"feasible_solves"=>16,"infeasible_solves"=>4,"identity"=>identity)))
