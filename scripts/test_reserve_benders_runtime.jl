using Test, SparseArrays
include(joinpath(@__DIR__,"..","src","solve_reserve_benders_worker.jl"))
const RB_RUNTIME_TEST_ROOT=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="reserve_runtime_tests_")

@testset "Native reserve LP dual and feasibility certificates" begin
    # y >= 1-x, y <= x. Its recourse is infeasible at x=0 and feasible at x=1.
    # The master cannot drop a continuous x region with a binary no-good cut.
    A=sparse(reshape([1.0,1.0],2,1));P=sparse(reshape([1.0,-1.0],2,1))
    lp=(;A,P,c=[3.0],lower=[1.0,-Inf],upper=[Inf,0.0],y_upper=[Inf],record=Dict("period"=>1))
    for x in (0.0,0.25,0.5,0.75,1.0)
        result=rb_lp_solve(lp,[x],joinpath(RB_RUNTIME_TEST_ROOT,"cost_$x.log");
            deadline=time()+30,limit=10,on_event=(a,b)->nothing)
        if x<0.5
            @test result.statistics["native_status"]==8
            @test !result.statistics["has_primal"]
            phase=rb_lp_solve(lp,[x],joinpath(RB_RUNTIME_TEST_ROOT,"phase_$x.log");
                deadline=time()+30,limit=10,on_event=(a,b)->nothing,phase_one=true)
            @test phase.statistics["has_primal"]
            @test phase.statistics["maximum_residual"]<=1e-8
            cut=reserve_benders_cut(phase.A,lp.P,phase.c,lp.lower,lp.upper,phase.Y,[0.0],[1.0],phase.dual)
            cut=reserve_solver_safe_cut(cut,[0.0],[1.0])
            @test reserve_cut_lower_value(cut,[x])>1e-8
            for feasible in (0.5,0.6,0.75,1.0)
                @test reserve_cut_lower_value(cut,[feasible])<=1e-12
            end
        else
            @test result.statistics["has_primal"]
            @test result.statistics["objective"]≈3*(1-x) atol=1e-8
            cut=reserve_benders_cut(A,P,lp.c,lp.lower,lp.upper,lp.y_upper,[0.0],[1.0],result.dual)
            @test reserve_cut_lower_value(cut,[x])<=result.statistics["objective"]+1e-8
            @test result.statistics["objective"]-reserve_cut_lower_value(cut,[x])<1e-7
        end
    end
    @test_throws Exception rb_lp_solve(lp,[0.5],joinpath(RB_RUNTIME_TEST_ROOT,"expired.log");
        deadline=time()-1,limit=10,on_event=(a,b)->nothing)
end

@testset "Benders native cut encoding and hash-bound arrays" begin
    ctx=(;identity=Dict("test"=>"identity"),record=Dict("periods"=>[1,2]),master=Dict("source_variables"=>3))
    cut=Dict{String,Any}("kind"=>"cost","period"=>2,"identity"=>ctx.identity,
        "parameter_ids"=>[1,3],"coefficients"=>[2.0,-1.0],"intercept"=>3.0,
        "certificate"=>Dict("valid_lower_cut"=>true))
    row=rb_cut_row(cut,ctx)
    @test row.index==Int32[0,2,4]
    @test row.values==[-2.0,1.0,1.0]
    @test row.lower==3
    cut["kind"]="feasibility";row=rb_cut_row(cut,ctx)
    @test row.index==Int32[0,2]
    @test row.values==[-2.0,1.0]
    for (key,value) in (("period",3),("parameter_ids",[3,1]),("coefficients",[1e-10,-1.0]),
                        ("kind","invalid"),("intercept",NaN),("identity",Dict("test"=>"wrong")))
        bad=copy(cut);bad[key]=value
        @test_throws Exception rb_cut_row(bad,ctx)
    end
    ref=rb_binary(joinpath(RB_RUNTIME_TEST_ROOT,"values.bin"),[1.0,2.0])
    @test rb_vector(ref,2)==[1.0,2.0]
    @test_throws Exception rb_vector(ref,3)
    @test_throws Exception rb_binary(ref["path"],[1.0,2.0])
    other=copy(ref);other["sha256"]="wrong"
    @test_throws Exception rb_vector(other,2)
end
