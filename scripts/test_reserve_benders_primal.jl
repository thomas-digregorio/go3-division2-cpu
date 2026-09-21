using Test
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_partition.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_certificate.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_runtime.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_primal.jl"))
const COLD_TEST_ROOT=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="cold_primal_tests_")

function cold_fixture(model,label)
    output=joinpath(COLD_TEST_ROOT,label);mkpath(output)
    config=JSON.parsefile(joinpath(@__DIR__,"..","config","tiny_reserve_benders_cold_primal.json"))
    # Component math also covers the unchanged stock backend.
    for key in ("scheduling_native_backend_policy","scheduling_native_objective_clique_max_size",
            "scheduling_native_analytic_center","scheduling_native_root_presolve_only","scheduling_native_root_lp_logging")
        delete!(config,key)
    end
    original=joinpath(output,"scheduling_spool");compact=joinpath(output,"compact_spool")
    partition=joinpath(output,"reserve_decomposition","reserve_partition")
    write_scheduling_spool(model,original;identity=Dict("config"=>config,"fixture"=>label))
    compact_scheduling_spool(original,compact;require_exit=false)
    proof=verify_compaction_proof(original,compact);@test proof["pass"]
    atomic_json(joinpath(compact,"proof_verification.json"),proof)
    partition_reserve_spool(original,compact,partition)
    proof=verify_reserve_partition(compact,partition);@test proof["pass"]
    atomic_json(joinpath(partition,"proof_verification.json"),proof)
    ctx=rb_context(output,config)
    directory=joinpath(output,"master");mkpath(directory)
    request=Dict("mode"=>"master","round"=>1,"identity"=>ctx.identity,"recourse_history"=>[],"start"=>nothing)
    atomic_json(joinpath(directory,"request.json"),request)
    (;ctx,config,request,directory)
end

@testset "Cold construction preserves PMIN transitions and economic bound scope" begin
    m=Model();@variable(m,p_on_status[d in ["a","unavailable"],t in 1:2],Bin)
    @variable(m,0<=p[d in ["a","unavailable"],t in 1:2]<=1)
    @variable(m,u_su[d in ["a","unavailable"],t in 1:2],Bin)
    @variable(m,u_sd[d in ["a","unavailable"],t in 1:2],Bin)
    @variable(m,p_rgu[d in ["a"],t in 1:2]>=0)
    for d in ["a","unavailable"],t in 1:2
        @constraint(m,p[d,t]>=0.4p_on_status[d,t])
        @constraint(m,p[d,t]<=p_on_status[d,t])
        @constraint(m,p_on_status[d,t]-(t==1 ? 0.0 : p_on_status[d,t-1])==u_su[d,t]-u_sd[d,t])
        @constraint(m,u_su[d,t]+u_sd[d,t]<=1)
        d=="unavailable" && fix(p_on_status[d,t],0;force=true)
    end
    @constraint(m,p_on_status["a",1]==p_on_status["a",2]) # exact alias mapping
    @constraint(m,sum(u_su["a",t] for t in 1:2)<=1)
    for t in 1:2;@constraint(m,p_rgu["a",t]+p["a",t]>=0.6);end
    @objective(m,Max,-20p_on_status["a",1]-0.5sum(p)-3sum(p_rgu)+0.125)
    f=cold_fixture(m,"preserved");cost,inventory=rb_online_objective(f.ctx)
    @test inventory["source_online_columns"]==4
    @test inventory["eliminated_zero_online_columns"]==2
    @test sum(cost)==2 && count(!iszero,cost)==1
    result=rb_cold_master_round(f.ctx,f.config,f.request,f.directory;deadline=time()+30)
    @test result["audit"]["pass"] && result["statistics"]["has_primal"]
    @test result["statistics"]["bound"]===result["statistics"]["relative_gap"]===nothing
    @test result["solve_calls"]==2
    @test length(result["phases"])==2
    @test result["phases"][2]["presolve"]=="on"
    @test !result["phases"][2]["start_or_basis_supplied"]
    @test result["phases"][2]["fresh_native_model"]
    @test result["phases"][2]["integer_columns_fixed"]==count(!iszero,f.ctx.ma.integer)
    saved=JSON.parsefile(joinpath(f.directory,"construction_result.json"))
    @test saved["audit"]["pass"] && saved["solve_calls"]==1
    @test saved["request_sha256"]==spool_sha(joinpath(f.directory,"request.json"))
    # In-process math fixture: recompose explicitly. The separate integration
    # test exercises the real builder-exit requirement; never forge that proof.
    x=rb_vector(result["primal"],f.ctx.master["variables"])
    compact_point=zeros(f.ctx.reduced["variables"])
    ids=spool_array(f.ctx.master_directory,"source_columns",Int32,f.ctx.master["source_variables"])
    compact_point[ids]=x[1:f.ctx.master["source_variables"]]
    for t in 1:2
        part=joinpath(f.ctx.partition,"hour_"*lpad(string(t),4,'0'))
        lp=load_reserve_partition_lp(part)
        recourse=rb_lp_solve(lp,x[lp.parameter_ids],joinpath(f.directory,"reserve_$t.log");
            deadline=time()+30,limit=5,on_event=(a,b)->nothing)
        @test recourse.statistics["has_primal"] && recourse.statistics["maximum_residual"]<=1e-8
        ids=spool_array(part,"source_columns",Int32,lp.record["variables"])
        compact_point[ids]=recourse.primal
    end
    mapping=spool_array(f.ctx.compact,"original_to_compact",Int32,f.ctx.source["variables"])
    point=[j==0 ? 0.0 : compact_point[j] for j in mapping]
    original_audit=check_original_spool_point(f.ctx.original,f.ctx.source,point)
    @test original_audit["pass"]
    for t in 1:2
        @test point[index(p_on_status["a",t]).value]==1
        @test point[index(p_on_status["unavailable",t]).value]==0
        @test point[index(p["a",t]).value]≈0.4 atol=1e-8
    end
    @test point[index(u_su["a",1]).value]==1
    @test point[index(u_su["a",2]).value]==0
    @test original_audit["objective"]≈-21.475 atol=1e-8
    set_optimizer(m,optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false))
    optimize!(m)
    @test termination_status(m)==MOI.OPTIMAL
    @test objective_value(m)>original_audit["objective"]+1 # heuristic is deliberately suboptimal
    bad=copy(f.request);bad["start"]=Dict("path"=>"unapproved")
    @test_throws Exception rb_cold_master_round(f.ctx,f.config,bad,f.directory;deadline=time()+30)
    @test_throws Exception rb_online_objective(f.ctx;deadline=time()-1) # tiny loop checks below
end

@testset "Cold construction never fabricates an infeasible schedule" begin
    m=Model();@variable(m,p_on_status[d in ["a"],t in [1]],Bin)
    @variable(m,p_rgu[d in ["a"],t in [1]]>=0)
    @constraint(m,p_on_status["a",1]>=0.7);@constraint(m,p_on_status["a",1]<=0.8)
    @constraint(m,p_rgu["a",1]>=0.1)
    @objective(m,Max,-p_on_status["a",1]-p_rgu["a",1])
    f=cold_fixture(m,"infeasible")
    result=rb_cold_master_round(f.ctx,f.config,f.request,f.directory;deadline=time()+30)
    @test !result["statistics"]["has_primal"]
    @test result["audit"]===nothing && result["solve_calls"]==1
    @test !isfile(joinpath(f.directory,"construction_result.json"))
    @test result["statistics"]["bound"]===nothing
end
