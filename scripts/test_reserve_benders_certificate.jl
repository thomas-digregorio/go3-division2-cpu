using Test, JuMP, HiGHS, SparseArrays, LinearAlgebra, Random
include(joinpath(@__DIR__,"..","src","reserve_benders_certificate.jl"))

function rb_test_solve(A,P,c,L,U,Y,x)
    m=Model(optimizer_with_attributes(HiGHS.Optimizer,"threads"=>1,"output_flag"=>false,
        "primal_feasibility_tolerance"=>1e-9,"dual_feasibility_tolerance"=>1e-9))
    @variable(m,0<=y[j in eachindex(c)]<=Y[j])
    rows=ConstraintRef[]
    for i in eachindex(L)
        shift=dot(P[i,:],x);e=sum(A[i,j]*y[j] for j in eachindex(c))
        if L[i]==U[i]
            push!(rows,@constraint(m,e==L[i]-shift))
        elseif L[i]==-Inf
            push!(rows,@constraint(m,e<=U[i]-shift))
        elseif U[i]==Inf
            push!(rows,@constraint(m,e>=L[i]-shift))
        else
            push!(rows,@constraint(m,L[i]-shift<=e<=U[i]-shift))
        end
    end
    @objective(m,Min,dot(c,y));optimize!(m)
    @test termination_status(m)==MOI.OPTIMAL
    (;objective=objective_value(m),dual=dual.(rows),primal=value.(y))
end

function rb_big_check(cut,A,P,c,L,U,Y,X)
    # Independent high-precision check of the supplied multiplier certificate,
    # including its box correction; does not reuse interval helpers.
    setprecision(BigFloat,256) do
        pi=BigFloat.(cut.dual);a=BigFloat.(Matrix(A));p=BigFloat.(Matrix(P))
        r=BigFloat.(c)-a'*pi
        constant=sum(pi[i]*(pi[i]>0 ? BigFloat(L[i]) : pi[i]<0 ? BigFloat(U[i]) : big"0")
            for i in eachindex(pi))
        for j in eachindex(c)
            @test isfinite(Y[j]) || r[j]>=0
            r[j]<0 && (constant+=r[j]*BigFloat(Y[j]))
        end
        gradient=-p'*pi
        for x in X
            bound=constant+dot(gradient,BigFloat.(x))
            represented=BigFloat(cut.intercept)+dot(BigFloat.(cut.coefficients),BigFloat.(x))
            @test represented<=bound
            @test BigFloat(reserve_cut_lower_value(cut,x))<=represented
        end
    end
end

@testset "Reserve lower cuts retain complete piecewise LP recourse cost" begin
    A=sparse(reshape([1.0,1.0],1,2));P=sparse(reshape([-1.0],1,1))
    c=[1.0,10.0];L=[0.0];U=[Inf];Y=[1.0,Inf];XL=[0.0];XU=[3.0]
    samples=[[x] for x in range(0.0,3.0,length=17)]
    for x in ([0.25],[2.0])
        result=rb_test_solve(A,P,c,L,U,Y,x)
        cut=reserve_benders_cut(A,P,c,L,U,Y,XL,XU,result.dual)
        @test cut.certificate["valid_lower_cut"]
        @test !cut.certificate["dual_repair"]["zero_fallback"]
        @test abs(reserve_cut_lower_value(cut,x)-result.objective)<1e-7
        rb_big_check(cut,A,P,c,L,U,Y,samples)
        for other in samples
            @test reserve_cut_lower_value(cut,other)<=rb_test_solve(A,P,c,L,U,Y,other).objective+1e-10
        end
    end
end

@testset "Zero-cost maximum-production auxiliary and imperfect dual repair" begin
    A=sparse([1.0 1.0 -1.0;0.0 0.0 1.0]);P=sparse(reshape([0.0,-1.0],2,1))
    c=[1.0,10.0,0.0];L=[0.0,0.0];U=[Inf,Inf];Y=[1.0,Inf,Inf]
    result=rb_test_solve(A,P,c,L,U,Y,[2.0])
    noisy=result.dual+[0.0,1e-7]
    cut=reserve_benders_cut(A,P,c,L,U,Y,[0.0],[3.0],noisy)
    @test cut.certificate["dual_repair"]["singleton_repairs"]>0
    @test !cut.certificate["dual_repair"]["zero_fallback"]
    @test abs(reserve_cut_lower_value(cut,[2.0])-result.objective)<1e-5
    rb_big_check(cut,A,P,c,L,U,Y,[[0.0],[0.5],[2.0],[3.0]])
end

@testset "Signed parameter domains, ranged rows, bad signs and fail-closed inputs" begin
    A=sparse(reshape([0.1],1,1));P=sparse(reshape([-0.3,0.7],1,2))
    c=[0.2];L=[-1.0];U=[4.0];Y=[100.0];XL=[-2.0,0.0];XU=[2.0,Inf]
    samples=[[x,z] for x in (-2.0,-0.7,0.0,0.3,2.0) for z in (0.0,1.0,2.0)]
    cut=reserve_benders_cut(A,P,c,L,U,Y,XL,XU,[2.0])
    rb_big_check(cut,A,P,c,L,U,Y,samples)
    @test cut.certificate["mixed_domain_correction"]<=0
    # Wrong-signed multiplier on a one-sided row is removed, never accepted.
    clipped=reserve_benders_cut(A,P,c,[-Inf],U,Y,XL,XU,[2.0])
    @test clipped.dual==[0.0]
    @test clipped.intercept==0.0
    @test_throws Exception reserve_benders_cut(A,P,[-0.2],L,U,Y,XL,XU,[2.0])
    @test_throws Exception reserve_benders_cut(A,P,c,L,U,[-1.0],XL,XU,[2.0])
    @test_throws Exception reserve_benders_cut(A,P,c,L,U,Y,XL,XU,[NaN])
    @test_throws Exception reserve_benders_cut(A,P,c,L,U,Y,[0.0],XU,[2.0])
    # A zero-cost recourse column without a repairable singleton falls back to
    # a provably weak zero cut, which the coordinator must not call convergence.
    A2=sparse(reshape([1.0,1.0],1,2));P2=sparse(reshape([-1.0],1,1))
    weak=reserve_benders_cut(A2,P2,[0.0,1.0],[0.0],[Inf],[Inf,Inf],[0.0],[1.0],[0.1])
    @test weak.certificate["dual_repair"]["zero_fallback"]
    @test reserve_cut_lower_value(weak,[1.0])==0.0
end

@testset "Random feasible recourse points respect conservative lower cuts" begin
    rng=MersenneTwister(73123)
    for trial in 1:30
        A=sparse(randn(rng,5,4));P=sparse(randn(rng,5,3));c=rand(rng,4)
        Y=fill(4.0,4);XL=fill(-2.0,3);XU=fill(2.0,3)
        x=4rand(rng,3).-2;y=4rand(rng,4);v=A*y+P*x
        L=v.-rand(rng,5);U=v.+rand(rng,5)
        cut=reserve_benders_cut(A,P,c,L,U,Y,XL,XU,10randn(rng,5))
        rb_big_check(cut,A,P,c,L,U,Y,[x,XL,XU,zeros(3)])
        @test reserve_cut_lower_value(cut,x)<=dot(c,y)
    end
end

@testset "Native small-coefficient handling never strengthens the lower cut" begin
    raw=(;intercept=1.0,coefficients=[-1e-14,1e-14,-1e-14,1e-14,0.2],
        dual=[0.0],certificate=Dict{String,Any}())
    lower=[0.0,-Inf,-2.0,0.0,-1.0];upper=[Inf,0.0,3.0,Inf,1.0]
    safe=reserve_solver_safe_cut(raw,lower,upper)
    @test all(v->v==0 || abs(v)>=1e-8,safe.coefficients)
    @test safe.certificate["solver_safe_coefficient_adjustments"]==4
    for scale in (0.0,1.0,1e6),signed in (-2.0,0.0,3.0)
        x=[scale,-scale,signed,scale,1.0]
        @test BigFloat(safe.intercept)+dot(BigFloat.(safe.coefficients),BigFloat.(x)) <=
            BigFloat(raw.intercept)+dot(BigFloat.(raw.coefficients),BigFloat.(x))
    end
    @test_throws Exception reserve_solver_safe_cut(raw,lower,upper;minimum_coefficient=0.0)
    @test_throws Exception reserve_solver_safe_cut(raw,fill(-Inf,5),fill(Inf,5))
end
