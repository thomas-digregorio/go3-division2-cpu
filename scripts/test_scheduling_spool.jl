# Tiny fixtures only. Every original scalar row, cost, bound, domain and name
# is compared with the binary disk model and the native (unpresolved) model.
using Test, SparseArrays
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
const SPOOL_TEST_ROOT=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="scheduling_spool_tests_")
const SPOOL_OPT=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>4,"mip_rel_gap"=>1e-6,
    "mip_feasibility_tolerance"=>1e-9,"primal_feasibility_tolerance"=>1e-9,
    "mip_lp_solver"=>"simplex","output_flag"=>false)

function assert_spool_native_exact(model,native,dir,record)
    n=record["variables"];m=record["rows"];nz=record["nonzeros"]
    dims=[Ref{HiGHS.HighsInt}() for _ in 1:5];offset=Ref{Float64}()
    cost=zeros(n);lo=zeros(n);hi=zeros(n);rl=zeros(m);ru=zeros(m)
    start=zeros(HiGHS.HighsInt,m+1);idx=zeros(HiGHS.HighsInt,nz);v=zeros(nz);integrality=zeros(HiGHS.HighsInt,n)
    @test HiGHS.Highs_getModel(native,HiGHS.kHighsMatrixFormatRowwise,0,dims...,offset,
        cost,lo,hi,rl,ru,start,idx,v,C_NULL,C_NULL,C_NULL,integrality)==HiGHS.kHighsStatusOk
    @test [d[] for d in dims[1:3]]==[n,m,nz]
    @test HiGHS.Highs_getHessianNumNz(native)==0
    # C API returns starts[1:m], not the extra CSR sentinel.
    start[end]=nz
    @test dims[5][]==(objective_sense(model)==MOI.MAX_SENSE ? -1 : 1)
    original=objective_function(model)
    @test offset[]==constant(original)
    for j in 1:n
        var=VariableRef(model,MOI.VariableIndex(j))
        @test cost[j]==coefficient(original,var)
        l=is_fixed(var) ? fix_value(var) : has_lower_bound(var) ? lower_bound(var) : -Inf
        u=is_fixed(var) ? fix_value(var) : has_upper_bound(var) ? upper_bound(var) : Inf
        if is_binary(var);l=max(0.0,l);u=min(1.0,u);end
        @test lo[j]==l
        @test hi[j]==u
        @test integrality[j]==(is_binary(var)||is_integer(var) ? 1 : 0)
    end
    src=backend(model);row=0
    for S in SPOOL_SETS
        for ci in MOI.get(src,MOI.ListOfConstraintIndices{SPOOL_F,S}())
            row+=1;f=MOI.get(src,MOI.ConstraintFunction(),ci)
            l,u=spool_bounds(MOI.get(src,MOI.ConstraintSet(),ci))
            @test rl[row]==l-f.constant
            @test ru[row]==u-f.constant
            expected=Dict{Int,Float64}()
            for t in f.terms;expected[t.variable.value-1]=get(expected,t.variable.value-1,0.0)+t.coefficient;end
            actual=Dict(Int(idx[k])=>v[k] for k in start[row]+1:start[row+1])
            @test actual==expected
        end
    end
    @test row==m
    for (file,actual,T) in (("col_cost",cost,Float64),("col_lower",lo,Float64),("col_upper",hi,Float64),
            ("row_lower",rl,Float64),("row_upper",ru,Float64),("integrality",integrality,HiGHS.HighsInt))
        @test collect(spool_array(dir,file,T,length(actual)))==actual
    end
    open(joinpath(dir,"column_names.bin"),"r") do io
        for j in 1:n
            @test read(io,Int64)==j
            @test String(read(io,read(io,Int32)))==name(VariableRef(model,MOI.VariableIndex(j)))
        end
        @test eof(io)
    end
    open(joinpath(dir,"row_names.bin"),"r") do io
        for S in SPOOL_SETS,ci in MOI.get(src,MOI.ListOfConstraintIndices{SPOOL_F,S}())
            @test read(io,Int64)==ci.value
            @test String(read(io,read(io,Int32)))==MOI.get(src,MOI.ConstraintName(),ci)
        end
        @test eof(io)
    end
end

@testset "GO3 disk spool exact model and unchanged upstream extraction" begin
    for fixture in ("source_features_problem.json","dc_problem.json"), reserves in (false,true)
        raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny",fixture));before=deepcopy(raw)
        input=GO3.process_input_data(raw)
        cached=build_source_scheduling(input;include_reserves=reserves,consumer_dominance=true)
        release_scheduling_construction_metadata!(cached)
        dir=joinpath(SPOOL_TEST_ROOT,fixture*string(reserves))
        record=write_scheduling_spool(cached,dir)
        @test_throws Exception validate_scheduling_spool(dir)
        @test validate_scheduling_spool(dir;require_exit=false)["complete"]
        @test_throws Exception write_scheduling_spool(cached,dir)
        events=String[]
        result,schedule=solve_scheduling_spool(input,dir;optimizer=SPOOL_OPT,time_limit=15.0,
            include_reserves=reserves,require_exit=false,on_event=(n,d)->push!(events,n),
            on_loaded=n->assert_spool_native_exact(cached,n,dir,record))
        @test events==["disk_handoff_begin","disk_handoff_complete","economic_solve_begin","economic_solve_returned"]
        @test termination_status(result)==MOI.OPTIMAL
        @test raw==before
        baseline,old_schedule=schedule_source_balances(input;optimizer=SPOOL_OPT,time_limit=15.0,
            include_reserves=reserves,consumer_dominance=true,set_silent=true)
        @test objective_value(result)≈objective_value(baseline) atol=1e-7 rtol=1e-10
        @test model_stats(result)["relative_gap"]<=1e-6
        @test keys(schedule)==keys(old_schedule)
        @test schedule_balance_summary(input,result)["penalty_cost"]≈
            schedule_balance_summary(input,baseline)["penalty_cost"] atol=1e-7
        # The upstream extractor sees the exact indexed native primal, never
        # a rounded or reconstructed incomplete starting vector.
        for symbol in SCHEDULING_EXTRACTION_SYMBOLS
            haskey(object_dictionary(result),symbol) || continue
            @test all(isfinite,value.(result[symbol]))
        end
        @test_throws Exception optimize!(result) # facade cannot accidentally re-solve
        @test get_optimizer_attribute(result,"mip_lp_solver")=="simplex"
    end
end

@testset "GO3 spool all scalar domains offset senses and fail-closed guards" begin
    for sense in (MOI.MIN_SENSE,MOI.MAX_SENSE)
        model=Model()
        @variable(model,-4<=x<=8,Int)
        @variable(model,z,Bin)
        @variable(model,y)
        fix(y,1.23456789012345)
        @constraint(model,cl,x+2z<=7.777777777777)
        @constraint(model,cg,2x-z>=-3.333333333333)
        @constraint(model,ce,x+y==2.3)
        @constraint(model,ci,-8<=x+z<=9)
        set_objective_sense(model,sense);@objective(model,Min,3.141592653589793*x-2z+0.123456789012345)
        set_objective_sense(model,sense)
        dir=joinpath(SPOOL_TEST_ROOT,"general"*string(sense));record=write_scheduling_spool(model,dir)
        native=MOI.instantiate(SPOOL_OPT)
        try
            load_spool_native!(native,dir,record);assert_spool_native_exact(model,native,dir,record)
        finally;finalize(native);end
        @test_throws Exception validate_scheduling_spool(dir;require_exit=false,deadline=time()-1)
        open(joinpath(dir,"a_value.bin"),"a") do io;write(io,UInt8(1));end
        @test_throws Exception validate_scheduling_spool(dir;require_exit=false)
    end
    model=Model();@variable(model,x);@objective(model,Min,x)
    @constraint(model,x^2<=2)
    @test_throws Exception write_scheduling_spool(model,joinpath(SPOOL_TEST_ROOT,"quadratic"))
    @test !ispath(joinpath(SPOOL_TEST_ROOT,"quadratic"))
    @test_throws Exception spool_local(joinpath(SPOOL_TEST_ROOT,"OneDrive","bad"))
    model=Model();@variable(model,x);@objective(model,Min,1.0*x)
    set_start_value(x,0.0)
    @test_throws Exception write_scheduling_spool(model,joinpath(SPOOL_TEST_ROOT,"start"))
    @test_throws Exception schedule_source_balances((;);optimizer=SPOOL_OPT,time_limit=1,
        storage_policy="disk_backed_native_v1")
end

@testset "GO3 disk scheduling preserves infeasible empty rows" begin
    input=GO3.process_input_data(JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny","dc_problem.json")))
    model=build_source_scheduling(input)
    @constraint(model,0.0*model[:p]["g",1]>=1.0)
    dir=joinpath(SPOOL_TEST_ROOT,"infeasible");record=write_scheduling_spool(model,dir)
    result,schedule=solve_scheduling_spool(input,dir;optimizer=SPOOL_OPT,time_limit=10,
        require_exit=false,on_loaded=n->assert_spool_native_exact(model,n,dir,record))
    @test termination_status(result)==MOI.INFEASIBLE
    @test schedule===nothing
    @test model_stats(result)["objective"]===nothing
    @test model_stats(result)["primal_status"]=="NO_SOLUTION"
end
