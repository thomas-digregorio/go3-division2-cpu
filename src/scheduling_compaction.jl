# Exact algebraic compaction, not tolerance-based presolve or feasibility repair.
# Only zero substitution and x=y identification; no nonzero offset substitution.
const COMPACTION_POLICY="exact_zero_alias_v1"
const COMPACT_SCHEMA="go3_exact_zero_alias_csr_v1"

function compact_root!(parent,j)
    r=j
    while parent[r]!=r;r=parent[r];end
    while parent[j]!=j;k=parent[j];parent[j]=r;j=k;end
    Int(r)
end

function compact_original_arrays(directory,record)
    n=Int(record["variables"]);m=Int(record["rows"]);nz=Int(record["nonzeros"])
    (;lo=spool_array(directory,"col_lower",Float64,n),hi=spool_array(directory,"col_upper",Float64,n),
      cost=spool_array(directory,"col_cost",Float64,n),integer=spool_array(directory,"integrality",Int32,n),
      rl=spool_array(directory,"row_lower",Float64,m),ru=spool_array(directory,"row_upper",Float64,m),
      start=spool_array(directory,"a_start",Int32,m+1),index=spool_array(directory,"a_index",Int32,nz),
      value=spool_array(directory,"a_value",Float64,nz))
end

function compact_row_state!(a,row,parent,zero,lo,hi)
    count=0;x=0;y=0;ax=0.0;ay=0.0;nonnegative=true;nonpositive=true
    for k in Int(a.start[row])+1:Int(a.start[row+1])
        j=compact_root!(parent,Int(a.index[k])+1);v=a.value[k]
        (zero[j] || v==0) && continue
        count+=1
        if count==1;x=j;ax=v;elseif count==2;y=j;ay=v;end
        nonnegative &= v>0 ? lo[j]>=0 : hi[j]<=0
        nonpositive &= v>0 ? hi[j]<=0 : lo[j]>=0
    end
    (;count,x,y,ax,ay,nonnegative,nonpositive)
end

function compact_zero_justified(a,row,s)
    (a.rl[row]==0 && a.ru[row]==0 && s.count==1) ||
        (a.ru[row]==0 && s.nonnegative) || (a.rl[row]==0 && s.nonpositive)
end

function compact_scheduling_spool(original,output;deadline=Inf,require_exit=true,on_event=(n,d)->nothing)
    original=spool_local(original);output=spool_local(output)
    ispath(output) && error("Immutable compact spool already exists")
    record=validate_scheduling_spool(original;require_exit=require_exit,deadline=deadline)
    a=compact_original_arrays(original,record);n=Int(record["variables"]);m=Int(record["rows"])
    parent=Int32.(1:n);lo=copy(a.lo);hi=copy(a.hi);cost=copy(a.cost);integer=copy(a.integer)
    zero=(lo.==0).&(hi.==0)
    all(lo.<=hi) || error("Original model contains inconsistent variable bounds")
    mkpath(output);proof=SpoolStream(joinpath(output,"proof.bin"));steps=0;rounds=Any[]
    started=time()
    try
        # An early stop in reduction rounds affects compactness only, not validity.
        for pass in 1:16
            changed=0
            for row in 1:m
                s=compact_row_state!(a,row,parent,zero,lo,hi)
                if s.count>0 && compact_zero_justified(a,row,s)
                    for k in Int(a.start[row])+1:Int(a.start[row+1])
                        j=compact_root!(parent,Int(a.index[k])+1)
                        (zero[j] || a.value[k]==0) && continue
                        lo[j]<=0<=hi[j] || error("Exact zero inference conflicts with original bounds at row $row")
                        zero[j]=true;lo[j]=0;hi[j]=0;changed+=1;steps+=1
                        foreach(v->spool_write(proof,Int32(v)),(1,row,j,0))
                    end
                elseif s.count==2 && s.x!=s.y && a.rl[row]==a.ru[row]==0 && s.ax == -s.ay
                    # Never add two nonzero objective coefficients, avoiding even
                    # a rounding change in the stored mathematical objective.
                    if cost[s.x]==0 || cost[s.y]==0
                        keep=min(s.x,s.y);remove=max(s.x,s.y)
                        lower=max(lo[keep],lo[remove]);upper=min(hi[keep],hi[remove])
                        lower<=upper || error("Exact alias inference has inconsistent domains at row $row")
                        parent[remove]=Int32(keep);lo[keep]=lower;hi[keep]=upper
                        cost[keep]+=cost[remove];integer[keep]=max(integer[keep],integer[remove])
                        zero[keep]=lower==upper==0;changed+=1;steps+=1
                        foreach(v->spool_write(proof,Int32(v)),(2,row,remove,keep))
                    end
                end
                row%65536==0 && spool_check_deadline(deadline)
            end
            push!(rounds,Dict("round"=>pass,"reductions"=>changed))
            on_event("exact_compaction_round",rounds[end])
            changed==0 && break
        end
    finally;close(proof);end
    # Stable representatives and complete source-column reconstruction map.
    representatives=Int32[];root_index=zeros(Int32,n)
    for j in 1:n
        if parent[j]==j && !zero[j]
            push!(representatives,Int32(j));root_index[j]=Int32(length(representatives))
        end
    end
    mapping=Vector{Int32}(undef,n)
    for j in 1:n
        r=compact_root!(parent,j);mapping[j]=zero[r] ? 0 : root_index[r]
    end
    for (field,values) in (("col_cost",cost),("col_lower",lo),("col_upper",hi),("integrality",integer))
        open(io->write(io,values[representatives]),joinpath(output,field*".bin"),"w")
    end
    open(io->write(io,mapping),joinpath(output,"original_to_compact.bin"),"w")
    fields=("row_lower","row_upper","a_start","a_index","a_value","original_row")
    streams=Dict(k=>SpoolStream(joinpath(output,k*".bin")) for k in fields)
    rows=0;nz=0;tautologies=0;buffer=Tuple{Int32,Float64}[]
    try
        for row in 1:m
            empty!(buffer)
            for k in Int(a.start[row])+1:Int(a.start[row+1])
                j=mapping[Int(a.index[k])+1]
                j!=0 && a.value[k]!=0 && push!(buffer,(j,a.value[k]))
            end
            sort!(buffer;by=first)
            nterms=0;i=1
            while i<=length(buffer)
                j,value=buffer[i];i+=1
                while i<=length(buffer) && buffer[i][1]==j
                    add=buffer[i][2];total=value+add
                    # Error-free TwoSum detects an inexact coefficient merge.
                    z=total-value;roundoff=(value-(total-z))+(add-z)
                    roundoff==0 && isfinite(total) || error("Inexact alias coefficient merge at source row $row")
                    value=total;i+=1
                end
                if value!=0;nterms+=1;buffer[nterms]=(j,value);end
            end
            if nterms==0 && a.rl[row]<=0<=a.ru[row]
                tautologies+=1
            else
                spool_write(streams["a_start"],Int32(nz));spool_write(streams["original_row"],Int32(row))
                spool_write(streams["row_lower"],a.rl[row]);spool_write(streams["row_upper"],a.ru[row])
                for k in 1:nterms
                    j,v=buffer[k];spool_write(streams["a_index"],j-Int32(1));spool_write(streams["a_value"],v)
                end
                rows+=1;nz+=nterms
            end
            row%65536==0 && spool_check_deadline(deadline)
        end
        spool_write(streams["a_start"],Int32(nz))
    finally;foreach(close,values(streams));end
    compact=Dict("schema"=>COMPACT_SCHEMA,"complete"=>true,"policy"=>COMPACTION_POLICY,
        "original_manifest_sha256"=>spool_sha(joinpath(original,"manifest.json")),"identity"=>record["identity"],
        "variables"=>length(representatives),"rows"=>rows,"nonzeros"=>nz,
        "original_variables"=>n,"original_rows"=>m,"original_nonzeros"=>record["nonzeros"],
        "sense"=>record["sense"],"objective_offset"=>record["objective_offset"],
        "zero_columns"=>count(iszero,mapping),"aliased_columns"=>n-count(iszero,mapping)-length(representatives),
        "removed_tautologies"=>tautologies,"proof_steps"=>steps,"rounds"=>rounds,
        "source_values_changed"=>false,"coefficient_merges_exact"=>true,"elapsed_seconds"=>time()-started,
        "files"=>Dict(basename(p)=>Dict("bytes"=>filesize(p),"sha256"=>spool_sha(p)) for p in readdir(output;join=true)))
    atomic_json(joinpath(output,"manifest.json"),compact)
    compact
end

function verify_compaction_proof(original,directory;deadline=Inf,on_event=(n,d)->nothing)
    c=validate_compact_spool(original,directory;deadline=deadline)
    record=JSON.parsefile(joinpath(original,"manifest.json"));a=compact_original_arrays(original,record)
    n=Int(record["variables"]);m=Int(record["rows"]);nc=Int(c["variables"]);mc=Int(c["rows"])
    parent=Int32.(1:n);lo=copy(a.lo);hi=copy(a.hi)
    cost=copy(a.cost);integer=copy(a.integer);zero=(lo.==0).&(hi.==0)
    steps=0
    open(joinpath(directory,"proof.bin"),"r") do io
        while !eof(io)
            kind,row,col,target=ntuple(_->Int(read(io,Int32)),4)
            1<=row<=m && 1<=col<=n || error("Invalid proof identity")
            parent[col]==col && !zero[col] || error("Proof target is not a live representative")
            entries=Tuple{Int,Float64}[]
            for k in Int(a.start[row])+1:Int(a.start[row+1])
                j=compact_root!(parent,Int(a.index[k])+1)
                !zero[j] && a.value[k]!=0 && push!(entries,(j,a.value[k]))
            end
            if kind==1
                any(p->p[1]==col,entries) && target==0 || error("Zero proof lacks its variable")
                equality=(length(entries)==1 && a.rl[row]==0 && a.ru[row]==0)
                upper=(a.ru[row]==0 && all(p->p[2]>0 ? lo[p[1]]>=0 : hi[p[1]]<=0,entries))
                lower=(a.rl[row]==0 && all(p->p[2]>0 ? hi[p[1]]<=0 : lo[p[1]]>=0,entries))
                (equality || upper || lower) && lo[col]<=0<=hi[col] || error("Invalid zero inference")
                zero[col]=true;lo[col]=0;hi[col]=0
            elseif kind==2
                (length(entries)==2 && Set(first.(entries))==Set((col,target)) &&
                    entries[1][2]==-entries[2][2] && a.rl[row]==a.ru[row]==0 &&
                    target<col && parent[target]==target && !zero[target] &&
                    (cost[col]==0 || cost[target]==0)) || error("Invalid alias inference")
                parent[col]=Int32(target);lo[target]=max(lo[col],lo[target]);hi[target]=min(hi[col],hi[target])
                lo[target]<=hi[target] || error("Inconsistent alias domain")
                cost[target]+=cost[col];integer[target]=max(integer[col],integer[target])
                zero[target]=lo[target]==hi[target]==0
            else
                error("Unknown proof operation")
            end
            steps+=1;steps%65536==0 && spool_check_deadline(deadline)
            steps%1048576==0 && on_event("compaction_proof_steps",Dict("checked_steps"=>steps))
        end
    end
    steps==c["proof_steps"] || error("Proof step count mismatch")
    mapping=spool_array(directory,"original_to_compact",Int32,n)
    cc=spool_array(directory,"col_cost",Float64,nc)
    cl=spool_array(directory,"col_lower",Float64,nc)
    cu=spool_array(directory,"col_upper",Float64,nc)
    ci=spool_array(directory,"integrality",Int32,nc)
    seen=0
    for j in 1:n
        r=compact_root!(parent,j)
        if zero[r]
            mapping[j]==0 || error("Zero reconstruction mismatch")
        else
            if r==j
                seen+=1;mapping[j]==seen || error("Unstable or missing representative")
                (cc[seen]==cost[j] && cl[seen]==lo[j] && cu[seen]==hi[j] && ci[seen]==integer[j]) ||
                    error("Representative cost/domain differs from proof")
            end
            mapping[j]==mapping[r] && 1<=mapping[j]<=nc || error("Alias reconstruction mismatch")
        end
    end
    seen==nc || error("Compact column coverage mismatch")
    on_event("compaction_proof_columns",Dict("checked_columns"=>n))
    # Independently verify every retained row and every omitted tautology from
    # the ORIGINAL matrix under the proven reconstruction, not a copied hash.
    ca=compact_original_arrays(directory,c);original_rows=spool_array(directory,"original_row",Int32,mc)
    current=1;terms=Dict{Int,Float64}()
    for row in 1:m
        empty!(terms)
        for k in Int(a.start[row])+1:Int(a.start[row+1])
            j=Int(mapping[Int(a.index[k])+1]);j==0 && continue
            terms[j]=get(terms,j,0.0)+a.value[k]
        end
        filter!(p->last(p)!=0,terms)
        if isempty(terms) && a.rl[row]<=0<=a.ru[row]
            # This is the only permissible omitted-row condition.
        else
            current<=mc && original_rows[current]==row || error("Omitted nontrivial source row")
            ca.rl[current]==a.rl[row] && ca.ru[current]==a.ru[row] || error("Changed source row bounds")
            Int(ca.start[current+1]-ca.start[current])==length(terms) || error("Transformed row length mismatch")
            for k in Int(ca.start[current])+1:Int(ca.start[current+1])
                j=Int(ca.index[k])+1
                haskey(terms,j) && terms[j]==ca.value[k] || error("Changed source coefficient")
                delete!(terms,j)
            end
            isempty(terms) || error("Transformed row omitted a coefficient")
            current+=1
        end
        row%65536==0 && spool_check_deadline(deadline)
        row%1048576==0 && on_event("compaction_proof_rows",Dict("checked_rows"=>row,"required_rows"=>m))
    end
    current==mc+1 || error("Compact row coverage mismatch")
    Dict("pass"=>true,"complete"=>true,"proof_steps"=>steps,"original_rows_checked"=>record["rows"],
        "original_columns_checked"=>n,"compact_manifest_sha256"=>spool_sha(joinpath(directory,"manifest.json")),
        "policy"=>COMPACTION_POLICY,"source_constraints_weakened"=>false)
end

function validate_compact_spool(original,directory;deadline=Inf)
    directory=spool_local(directory);c=JSON.parsefile(joinpath(directory,"manifest.json"))
    source=JSON.parsefile(joinpath(original,"manifest.json"))
    (c["schema"]==COMPACT_SCHEMA && c["complete"] && c["policy"]==COMPACTION_POLICY &&
        c["original_manifest_sha256"]==spool_sha(joinpath(original,"manifest.json")) &&
        c["identity"]==source["identity"] && c["sense"]==source["sense"] &&
        c["objective_offset"]==source["objective_offset"] && !c["source_values_changed"]) ||
        error("Compact/source identity mismatch")
    Set(keys(c["files"]))==Set([f*".bin" for f in SPOOL_FIELDS] ∪
        ["original_to_compact.bin","original_row.bin","proof.bin"]) || error("Compact file inventory mismatch")
    for (file,info) in c["files"]
        spool_check_deadline(deadline);p=joinpath(directory,file)
        filesize(p)==info["bytes"] && spool_sha(p)==info["sha256"] || error("Compact hash mismatch: $file")
    end
    c
end

function check_original_spool_point(directory,record,primal;deadline=Inf)
    a=compact_original_arrays(directory,record);length(primal)==record["variables"] || error("Incomplete reconstruction")
    all(isfinite,primal) || error("Nonfinite reconstructed primal")
    residual=0.0;objective=record["objective_offset"]
    for j in eachindex(primal)
        x=primal[j];residual=max(residual,a.lo[j]-x,x-a.hi[j])
        a.integer[j]!=0 && (residual=max(residual,abs(x-round(x))))
        objective+=a.cost[j]*x
    end
    m=Int(record["rows"])
    for row in 1:m
        activity=0.0
        for k in Int(a.start[row])+1:Int(a.start[row+1]);activity+=a.value[k]*primal[Int(a.index[k])+1];end
        residual=max(residual,a.rl[row]-activity,activity-a.ru[row])
        row%65536==0 && spool_check_deadline(deadline)
    end
    isfinite(residual) && isfinite(objective) || error("Nonfinite original-model audit")
    Dict("complete"=>true,"pass"=>residual<=1e-8,"maximum_residual"=>residual,
        "tolerance"=>1e-8,"variables"=>length(primal),"rows"=>record["rows"],"objective"=>objective,
        "scope"=>"Original scheduling rows, bounds, integer domains and objective; not full GO3 verification")
end
