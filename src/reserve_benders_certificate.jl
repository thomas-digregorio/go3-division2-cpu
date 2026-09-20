# Lower cuts for the source reserve LP, not a new reserve or AC formulation.
# Convention: min c'y, L <= A*y + P*x <= U, 0 <= y <= upper.
# x comprises original scheduling variables with their original domains.
# Any sign-correct row multipliers give a Lagrangian lower bound. We use
# outward-rounded arithmetic and the original variable box, rather than
# mistaking a solver's approximate dual-feasibility status for a certificate.
using SparseArrays

const RESERVE_BENDERS_POLICY = "source_reserve_benders_v1"

rb_downadd(a::Float64,b::Float64) = b==0 ? a : a==0 ? b : prevfloat(a+b)
rb_upadd(a::Float64,b::Float64) = b==0 ? a : a==0 ? b : nextfloat(a+b)
rb_downmul(a::Float64,b::Float64) = (a==0 || b==0) ? 0.0 : prevfloat(a*b)
rb_upmul(a::Float64,b::Float64) = (a==0 || b==0) ? 0.0 : nextfloat(a*b)

function rb_transpose_interval(matrix::SparseMatrixCSC{Float64,Ti},dual::Vector{Float64}) where Ti
    length(dual)==size(matrix,1) || error("Reserve dual dimension mismatch")
    lower=zeros(size(matrix,2));upper=zeros(size(matrix,2))
    for j in axes(matrix,2), k in nzrange(matrix,j)
        a=matrix.nzval[k];b=dual[matrix.rowval[k]]
        lower[j]=rb_downadd(lower[j],rb_downmul(a,b))
        upper[j]=rb_upadd(upper[j],rb_upmul(a,b))
    end
    all(isfinite,lower) && all(isfinite,upper) || error("Nonfinite reserve dual product")
    lower,upper
end

function rb_certificate_inputs(A,P,c,lower,upper,y_upper,x_lower,x_upper,dual)
    m,n=size(A)
    size(P,1)==m && length(c)==n && length(y_upper)==n &&
        length(lower)==length(upper)==length(dual)==m &&
        length(x_lower)==length(x_upper)==size(P,2) || error("Reserve certificate dimensions differ")
    all(isfinite,A.nzval) && all(isfinite,P.nzval) && all(isfinite,c) &&
        all(isfinite,dual) || error("Nonfinite reserve coefficients or dual")
    all(c.>=0) || error("This reserve certificate requires nonnegative source reserve costs")
    all(y_upper.>=0) && all(lower.<=upper) && all(x_lower.<=x_upper) ||
        error("Inconsistent source reserve domains")
    all(x->!isnan(x),Iterators.flatten((lower,upper,y_upper,x_lower,x_upper))) ||
        error("NaN reserve domain")
    all(x->x!=Inf,lower) && all(x->x!= -Inf,upper) &&
        all(x->x!=Inf,x_lower) && all(x->x!= -Inf,x_upper) || error("Empty infinite domain")
end

function rb_repair_dual(A,c,lower,upper,y_upper,raw_dual)
    dual=copy(raw_dual)
    # A multiplier has the sign of its finite lower/upper row bound.
    for i in eachindex(dual)
        if (dual[i]>0 && !isfinite(lower[i])) || (dual[i]<0 && !isfinite(upper[i]))
            dual[i]=0.0
        end
    end
    row_count=zeros(Int,size(A,1))
    for j in axes(A,2), k in nzrange(A,j)
        A.nzval[k]!=0 && (row_count[A.rowval[k]]+=1)
    end
    repairs=0;scale=1.0;zero_fallback=false
    for pass in 1:8
        _,at_upper=rb_transpose_interval(A,dual)
        bad=[j for j in eachindex(c) if !isfinite(y_upper[j]) && at_upper[j]>c[j]]
        isempty(bad) && return dual,Dict("repair_passes"=>pass-1,"singleton_repairs"=>repairs,
            "common_scale"=>scale,"zero_fallback"=>zero_fallback,
            "unbounded_columns_certified"=>count(!isfinite,y_upper))
        # In particular, max-production auxiliaries have zero cost. Their
        # singleton lower rows permit reducing the positive dual contribution
        # without worsening another recourse column's dual inequality.
        for j in bad
            c[j]==0 || continue
            needed=nextfloat(at_upper[j]+1e-12*max(1.0,abs(at_upper[j])))
            for k in nzrange(A,j)
                i=A.rowval[k];a=A.nzval[k]
                row_count[i]==1 && a*dual[i]>0 || continue
                change=min(abs(dual[i]),nextfloat(needed/abs(a)))
                old=dual[i]
                dual[i]=copysign(max(0.0,prevfloat(abs(old)-change)),old)
                repairs+=1
                needed-=abs(a)*(abs(old)-abs(dual[i]))
                needed<=0 && break
            end
        end
        _,at_upper=rb_transpose_interval(A,dual)
        factor=1.0
        for j in eachindex(c)
            isfinite(y_upper[j]) && continue
            if at_upper[j]>c[j]
                factor=min(factor,c[j]==0 ? 0.0 :
                    prevfloat(c[j]/(at_upper[j]+1e-12*max(1.0,abs(at_upper[j])))))
            end
        end
        if factor<1
            factor=max(0.0,factor);dual .*= factor;scale*=factor
            zero_fallback |= factor==0
        end
    end
    # Zero multipliers are always valid for the explicitly checked nonnegative
    # cost / nonnegative recourse domain. A weak cut is never called convergence.
    fill!(dual,0.0)
    dual,Dict("repair_passes"=>8,"singleton_repairs"=>repairs,"common_scale"=>0.0,
        "zero_fallback"=>true,"unbounded_columns_certified"=>count(!isfinite,y_upper))
end

function reserve_benders_cut(A::SparseMatrixCSC{Float64,Ti},P::SparseMatrixCSC{Float64,Tj},
        c::Vector{Float64},lower::Vector{Float64},upper::Vector{Float64},
        y_upper::Vector{Float64},x_lower::Vector{Float64},x_upper::Vector{Float64},
        raw_dual::Vector{Float64}) where {Ti,Tj}
    rb_certificate_inputs(A,P,c,lower,upper,y_upper,x_lower,x_upper,raw_dual)
    dual,repair=rb_repair_dual(A,c,lower,upper,y_upper,raw_dual)
    _,at_upper=rb_transpose_interval(A,dual)
    intercept=0.0
    for i in eachindex(dual)
        dual[i]==0 && continue
        b=dual[i]>0 ? lower[i] : upper[i]
        intercept=rb_downadd(intercept,rb_downmul(dual[i],b))
    end
    for j in eachindex(c)
        # Subtraction also rounds down. A bit-exact zero is safe if the
        # accumulated product interval is exactly zero and source cost is zero.
        r=c[j]==at_upper[j] ? 0.0 : prevfloat(c[j]-at_upper[j])
        if r<0
            isfinite(y_upper[j]) || error("Uncertified unbounded recourse column")
            intercept=rb_downadd(intercept,rb_downmul(r,y_upper[j]))
        end
    end
    p_lower,p_upper=rb_transpose_interval(P,dual)
    coefficients=zeros(size(P,2));mixed_domain_correction=0.0
    for j in eachindex(coefficients)
        gl=-p_upper[j];gu=-p_lower[j]
        if x_lower[j]>=0
            coefficients[j]=gl
        elseif x_upper[j]<=0
            coefficients[j]=gu
        elseif isfinite(x_lower[j]) && isfinite(x_upper[j])
            b=gl/2+gu/2;coefficients[j]=b
            dl=gl==b ? 0.0 : prevfloat(gl-b)
            du=gu==b ? 0.0 : nextfloat(gu-b)
            correction=minimum(rb_downmul(d,x) for d in (dl,du) for x in (x_lower[j],x_upper[j]))
            intercept=rb_downadd(intercept,correction)
            mixed_domain_correction=rb_downadd(mixed_domain_correction,correction)
        elseif gl==gu
            coefficients[j]=gl
        else
            # No finite support bound for this uncertainty. Cost is >= 0, so
            # return the valid zero cut, not an uncertified affine assertion.
            fill!(coefficients,0.0);intercept=0.0
            fill!(dual,0.0);mixed_domain_correction=0.0
            repair["zero_fallback"]=true;repair["free_parameter_fallback"]=true
            break
        end
    end
    isfinite(intercept) && all(isfinite,coefficients) || error("Nonfinite reserve lower cut")
    (;intercept,coefficients,dual,certificate=Dict(
        "policy"=>"outward_rounded_lagrangian_box_v1","valid_lower_cut"=>true,
        "rows_checked"=>size(A,1),"recourse_columns_checked"=>size(A,2),
        "parameter_columns_checked"=>size(P,2),"original_upper_bounds_used"=>true,
        "source_reserve_costs_nonnegative"=>true,"recourse_lower_bounds_zero"=>true,
        "mixed_domain_correction"=>mixed_domain_correction,"dual_repair"=>repair,
        "scope"=>"Source reserve LP lower cut only; not full GO3 optimality"))
end

function reserve_cut_lower_value(cut,x)
    length(x)==length(cut.coefficients) && all(isfinite,x) || error("Invalid cut evaluation point")
    v=cut.intercept
    for j in eachindex(x)
        v=rb_downadd(v,rb_downmul(cut.coefficients[j],x[j]))
    end
    v
end

function reserve_solver_safe_cut(cut,x_lower,x_upper;minimum_coefficient=1e-8)
    # Native solvers can discard very small matrix entries. Make that operation
    # explicit and lower-bounding instead of letting a discarded negative term
    # accidentally strengthen an alleged lower cut on an unbounded domain.
    isfinite(minimum_coefficient) && minimum_coefficient>0 || error("Invalid cut coefficient floor")
    length(cut.coefficients)==length(x_lower)==length(x_upper) || error("Cut domain dimension mismatch")
    all(x_lower.<=x_upper) || error("Invalid cut domains")
    coefficients=copy(cut.coefficients);intercept=cut.intercept;adjusted=0
    for j in eachindex(coefficients)
        v=coefficients[j]
        (v==0 || abs(v)>=minimum_coefficient) && continue
        if isfinite(x_lower[j]) && isfinite(x_upper[j])
            correction=min(rb_downmul(v,x_lower[j]),rb_downmul(v,x_upper[j]))
            intercept=rb_downadd(intercept,correction);coefficients[j]=0.0
        elseif x_lower[j]>=0
            coefficients[j]=v>0 ? 0.0 : -minimum_coefficient
        elseif x_upper[j]<=0
            coefficients[j]=v<0 ? 0.0 : minimum_coefficient
        else
            error("Cannot safely encode a tiny coefficient on a two-sided unbounded parameter")
        end
        adjusted+=1
    end
    merge(cut,(;intercept,coefficients,certificate=merge(cut.certificate,Dict(
        "minimum_nonzero_matrix_coefficient"=>minimum_coefficient,
        "solver_safe_coefficient_adjustments"=>adjusted,
        "rounding_policy"=>"Only weaken the cut over the original parameter domains"))))
end
