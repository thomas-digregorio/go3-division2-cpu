using Test
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_certificate.jl"))
include(joinpath(@__DIR__,"..","src","reserve_benders_partition.jl"))
const RB_TEST_ROOT=mktempdir(joinpath(@__DIR__,"..","tmp");prefix="reserve_partition_tests_")

function rb_fixture(model,label)
    directory=joinpath(RB_TEST_ROOT,label);original=joinpath(directory,"original")
    compact=joinpath(directory,"compact");partition=joinpath(directory,"partition")
    source=write_scheduling_spool(model,original)
    reduced=compact_scheduling_spool(original,compact;require_exit=false)
    proof=verify_compaction_proof(original,compact)
    @test proof["pass"]
    record=partition_reserve_spool(original,compact,partition)
    audit=verify_reserve_partition(compact,partition)
    @test audit["pass"]
    @test audit["source_rows_checked"]==reduced["rows"]
    @test audit["source_columns_checked"]==reduced["variables"]
    (;original,compact,partition,source,reduced,record)
end

function rb_test_row!(model,expression,lower,upper)
    if lower==upper
        @constraint(model,expression==lower)
    elseif lower== -Inf
        @constraint(model,expression<=upper)
    elseif upper==Inf
        @constraint(model,expression>=lower)
    else
        @constraint(model,lower<=expression<=upper)
    end
end

@testset "Source reserve partition exact recomposition and lower cuts" begin
    for fixture in ("source_features_problem.json","dc_problem.json")
        raw=JSON.parsefile(joinpath(@__DIR__,"..","tmp","official_tiny",fixture));before=deepcopy(raw)
        input=GO3.process_input_data(raw)
        reference=build_source_scheduling(input;include_reserves=true,consumer_dominance=true)
        f=rb_fixture(reference,fixture)
        @test raw==before
        @test f.record["periods"]==collect(input.periods)
        master,ma=rb_load_part(joinpath(f.partition,"master"))
        @test master["variables"]<f.reduced["variables"]
        optimizer=optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false,
            "mip_feasibility_tolerance"=>1e-9,"primal_feasibility_tolerance"=>1e-9)
        m=Model(optimizer)
        @variable(m,ma.lo[j]<=x[j in 1:master["variables"]]<=ma.hi[j])
        for j in eachindex(x);ma.integer[j]!=0 && set_integer(x[j]);end
        for i in 1:master["rows"]
            e=sum(ma.value[k]*x[Int(ma.index[k])+1] for k in Int(ma.start[i])+1:Int(ma.start[i+1]);init=0.0)
            rb_test_row!(m,e,ma.rl[i],ma.ru[i])
        end
        @objective(m,Max,master["objective_offset"]+sum(ma.cost[j]*x[j] for j in eachindex(x)))
        optimize!(m)
        @test termination_status(m)==MOI.OPTIMAL
        master_upper=objective_value(m)
        recourse=Dict{Int,Any}();models=Dict{Int,Any}()
        for (position,t) in enumerate(f.record["periods"])
            lp=load_reserve_partition_lp(joinpath(f.partition,"hour_"*lpad(string(t),4,'0')))
            @test size(lp.P,1)==size(lp.A,1)==lp.record["rows"]
            ys=@variable(m,[j in eachindex(lp.c)],lower_bound=0,upper_bound=lp.y_upper[j])
            for i in eachindex(lp.lower)
                e=sum(lp.A[i,j]*ys[j] for j in eachindex(ys))+
                    sum(lp.P[i,k]*x[lp.parameter_ids[k]] for k in eachindex(lp.parameter_ids))
                rb_test_row!(m,e,lp.lower[i],lp.upper[i])
            end
            theta=x[master["source_variables"]+position]
            @constraint(m,theta>=sum(lp.c[j]*ys[j] for j in eachindex(ys)))
            recourse[t]=ys;models[t]=lp
        end
        optimize!(m);set_optimizer(reference,optimizer);optimize!(reference)
        @test termination_status(m)==termination_status(reference)==MOI.OPTIMAL
        @test objective_value(m)≈objective_value(reference) atol=1e-8
        @test master_upper+1e-8>=objective_value(reference)
        groups=spool_array(f.partition,"column_group",Int32,f.reduced["variables"])
        local_id=spool_array(f.partition,"column_local",Int32,f.reduced["variables"])
        compact_point=[groups[j]==0 ? value(x[local_id[j]]) : value(recourse[Int(groups[j])][local_id[j]])
            for j in eachindex(groups)]
        @test check_original_spool_point(f.compact,f.reduced,compact_point)["pass"]
        mapping=spool_array(f.compact,"original_to_compact",Int32,f.source["variables"])
        source_point=[j==0 ? 0.0 : compact_point[j] for j in mapping]
        @test check_original_spool_point(f.original,f.source,source_point)["pass"]
        # Actual source reserve LPs supply their row duals, not a fabricated
        # certificate. The cut must reproduce each generating recourse cost.
        for (t,lp) in models
            local_x=value.(x[lp.parameter_ids]);shift=lp.P*local_x
            rm=Model(optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false,
                "primal_feasibility_tolerance"=>1e-9,"dual_feasibility_tolerance"=>1e-9))
            @variable(rm,0<=ys[j in eachindex(lp.c)]<=lp.y_upper[j])
            rows=[rb_test_row!(rm,sum(lp.A[i,j]*ys[j] for j in eachindex(ys)),
                lp.lower[i]-shift[i],lp.upper[i]-shift[i]) for i in eachindex(lp.lower)]
            @objective(rm,Min,sum(lp.c[j]*ys[j] for j in eachindex(ys)));optimize!(rm)
            @test termination_status(rm)==MOI.OPTIMAL
            cut=reserve_benders_cut(lp.A,lp.P,lp.c,lp.lower,lp.upper,lp.y_upper,
                ma.lo[lp.parameter_ids],ma.hi[lp.parameter_ids],dual.(rows))
            bound=reserve_cut_lower_value(cut,local_x)
            @test bound<=objective_value(rm)+1e-8
            @test objective_value(rm)-bound<1e-6
            @test !cut.certificate["dual_repair"]["zero_fallback"]
        end
        # Hash binding prevents a subsequent native process consuming changed
        # partition coefficients while referring to an older proof record.
        open(io->write(io,UInt8(0)),joinpath(f.partition,"master","a_value.bin"),"a")
        @test_throws Exception verify_reserve_partition(f.compact,f.partition)
    end
end

@testset "Reserve partition rejects unsupported recourse rather than dropping it" begin
    for invalid in ("negative_cost","nonzero_lower","cross_period")
        m=Model();@variable(m,0<=x<=1)
        @variable(m,p_rgu[u in ["a"],t in 1:2]>=0)
        invalid=="nonzero_lower" && set_lower_bound(p_rgu["a",1],0.1)
        @constraint(m,p_rgu["a",1]+x>=0.3)
        @constraint(m,p_rgu["a",2]+x>=0.3)
        invalid=="cross_period" && @constraint(m,p_rgu["a",1]+p_rgu["a",2]>=1.0)
        @objective(m,Max,x+(invalid=="negative_cost" ? 1.0 : -1.0)*sum(p_rgu))
        original=joinpath(RB_TEST_ROOT,invalid,"original");compact=joinpath(RB_TEST_ROOT,invalid,"compact")
        write_scheduling_spool(m,original);compact_scheduling_spool(original,compact;require_exit=false)
        @test_throws Exception partition_reserve_spool(original,compact,joinpath(RB_TEST_ROOT,invalid,"partition"))
    end
    @test rb_name_period("p_rgu[device,48]")==48
    @test rb_name_period("cost_block_p[device,48,10]")==0
    @test_throws Exception rb_name_period("p_rgu[device,0]")
end

@testset "Only original-domain redundant master projections are omitted" begin
    # r <= 0.00001*u and r <= 0.00001*(1-u) both project to facts already
    # implied by 0 <= u <= 1. A genuine p+r <= 0.5*u headroom row remains.
    m=Model();@variable(m,0<=u<=1);@variable(m,0<=dispatch<=2)
    @variable(m,p_rgu[d in ["a"],t in [1]]>=0)
    r=p_rgu["a",1]
    @constraint(m,r<=0.00001*u);@constraint(m,r<=0.00001*(1-u))
    @constraint(m,dispatch+r<=0.5*u);@objective(m,Max,dispatch-r)
    f=rb_fixture(m,"redundant_projection")
    @test f.record["box_redundant_master_projections"]==2
    @test f.record["master_implied_projection_rows"]==1
    # Outward activity arithmetic is independently checked, including source
    # binary bounds whose products are exactly representable without rounding.
    for a in (-0.3,-1e-5,0.0,0.1,1.0,1e15), b in (-2.1,-1.0,0.0,1.0,2.3)
        exact=BigFloat(a)*BigFloat(b)
        @test BigFloat(rb_domain_product(a,b,false))<=exact
        @test BigFloat(rb_domain_product(a,b,true))>=exact
    end
end
