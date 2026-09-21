# Structural source audit only: no optimizer, no optimize!, no previous solution.
using JSON, SHA
include(joinpath(@__DIR__,"..","src","pilot_worker.jl"))
length(ARGS)==1 || error("One raw source path required")
raw_path=abspath(ARGS[1])
occursin("onedrive",lowercase(raw_path)) && error("OneDrive forbidden")
input=GO3.process_input_data(JSON.parsefile(raw_path))
m=Model()
@variable(m,p[u in input.sdd_ids])
@variable(m,q[u in input.sdd_ids])
on=Dict(u=>1 for u in input.sdd_ids)
curves=(p_su=Dict(u=>zeros(length(input.periods)) for u in input.sdd_ids),
        p_sd=Dict(u=>zeros(length(input.periods)) for u in input.sdd_ids),
        supc_status=Dict(u=>zeros(Int,length(input.periods)) for u in input.sdd_ids),
        sdpc_status=Dict(u=>zeros(Int,length(input.periods)) for u in input.sdd_ids))
r=add_source_reserve_allocation!(m,input,1,p,q,on,curves)
eligible=Set(v for group in values(r.variables) for v in group)
initial_zero=Set(v for v in all_variables(m) if ac_domain_is_exact_zero(ac_zero_domain(v)))
known_zero=copy(initial_zero)
rows=vcat(all_constraints(m,AffExpr,MOI.LessThan{Float64}),
    all_constraints(m,AffExpr,MOI.GreaterThan{Float64}),all_constraints(m,AffExpr,MOI.EqualTo{Float64}))
steps=0;passes=0
for pass in 1:8
    global passes=pass
    before=length(known_zero)
    for cref in rows
        c=constraint_object(cref)
        rhs=c.set isa MOI.LessThan ? c.set.upper : c.set isa MOI.GreaterThan ? c.set.lower : c.set.value
        rhs==0.0 && c.func.constant==0.0 || continue
        signs=c.set isa MOI.EqualTo ? (1.0,-1.0) : (c.set isa MOI.LessThan ? (1.0,) : (-1.0,))
        for sign in signs
            free=VariableRef[];valid=true
            for (coefficient_,v) in linear_terms(c.func)
                coefficient_==0.0 && continue
                v in known_zero && continue
                if !(v in eligible && !is_fixed(v) && has_lower_bound(v) &&
                        lower_bound(v)==0.0 && sign*coefficient_>0.0 &&
                        (!has_upper_bound(v) || upper_bound(v)>=0.0))
                    valid=false;break
                end
                push!(free,v)
            end
            if valid && !isempty(free)
                union!(known_zero,free);global steps+=1
                break
            end
        end
    end
    length(known_zero)==before && break
end
function zero_constant_rows(zeros_)
    count(rows) do cref
        c=constraint_object(cref)
        any(coef!=0.0 && v in eligible for (coef,v) in linear_terms(c.func)) &&
            c.func.constant==0.0 && all(coef==0.0 || v in zeros_ for (coef,v) in linear_terms(c.func)) &&
            (c.set isa MOI.LessThan ? c.set.upper>=0.0 : c.set isa MOI.GreaterThan ? c.set.lower<=0.0 : c.set.value==0.0)
    end
end
expected_rows=zero_constant_rows(known_zero)
println("ZERO_DOMAIN_AUDIT ",JSON.json(Dict("input_sha256"=>bytes2hex(open(SHA.sha256,raw_path)),
    "scope"=>"Source reserve algebra under an all-online pattern; no network solve or feasibility claim",
    "optimization_calls"=>0,"original_model_modified"=>false,"source_devices"=>length(input.sdd_ids),
    "reserve_variables"=>length(eligible),"affine_rows"=>length(rows),"initial_explicit_zero_variables"=>length(initial_zero),
    "new_exact_implied_zero_variables"=>length(setdiff(known_zero,initial_zero)),
    "initial_constant_satisfied_zero_rows"=>zero_constant_rows(initial_zero),
    "constant_satisfied_zero_rows_after_propagation"=>zero_constant_rows(known_zero),"proof_rows"=>steps,"passes"=>passes)))
@objective(m,Min,r.cost)
record=compact_ac_zero_reserves!(m,eligible;policy=AC_ZERO_RESERVES_POLICY)
@assert record["implied_zero_variables"]==length(setdiff(known_zero,initial_zero))
@assert record["constant_satisfied_rows_removed"]==expected_rows
println("IMPLEMENTED_ZERO_REDUCTION ",JSON.json(record))
