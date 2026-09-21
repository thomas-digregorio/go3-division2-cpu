# A cold primal heuristic, not a replacement objective or a global bound.
# Source rows are unchanged. The first objective encourages online intervals;
# a separate fresh LP restores source economics with all integers fixed.
const RB_COLD_PRIMAL_POLICY="cold_online_then_fixed_cost_v1"

function rb_online_objective(ctx;deadline=Inf)
    spool_check_deadline(deadline)
    mapping=spool_array(ctx.compact,"original_to_compact",Int32,ctx.source["variables"])
    ids=spool_array(ctx.master_directory,"source_columns",Int32,ctx.master["source_variables"])
    inverse=zeros(Int32,ctx.reduced["variables"])
    for (j,id) in enumerate(ids);inverse[id]=Int32(j);end
    path=joinpath(ctx.original,"column_names.bin");info=ctx.source["files"]["column_names.bin"]
    filesize(path)==info["bytes"] && spool_sha(path)==info["sha256"] || error("Cold objective name identity mismatch")
    cost=zeros(ctx.master["variables"]);visited=0;online=0;eliminated=0
    open(path,"r") do io
        while !eof(io)
            id=Int(read(io,Int64));len=Int(read(io,Int32));visited+=1
            id==visited && 0<=len<=10000 || error("Malformed cold objective column identity")
            name=String(read(io,len))
            if startswith(name,"p_on_status[") && endswith(name,"]")
                online+=1;compact_id=mapping[id]
                if compact_id==0
                    eliminated+=1
                else
                    j=inverse[compact_id]
                    j>0 && ctx.ma.integer[j]==1 && 0<=ctx.ma.lo[j]<=ctx.ma.hi[j]<=1 ||
                        error("Online status is not an original binary master column")
                    cost[j]+=1.0
                end
            end
            visited%65536==0 && spool_check_deadline(deadline)
        end
    end
    visited==ctx.source["variables"] && online>0 || error("Missing source online-status inventory")
    cost,Dict("objective_scope"=>"sum_source_online_intervals_not_economics",
        "source_online_columns"=>online,"eliminated_zero_online_columns"=>eliminated,
        "nonzero_master_costs"=>count(!iszero,cost),"external_start_used"=>false)
end

function rb_master_audit(ctx,x,cuts;deadline)
    audit=check_original_spool_point(ctx.master_directory,ctx.master,x;deadline=deadline)
    audit["maximum_cut_violation"]=maximum([0.0;[row.lower-sum(row.values.*x[row.index.+1])
        for row in (rb_cut_row(c,ctx) for c in cuts)]])
    audit["pass"] && audit["maximum_cut_violation"]<=1e-8 || error("Constructed master point failed original rows or cuts")
    audit
end

function rb_load_cold_native(ctx,options,log_path,cuts)
    native=HiGHS.Optimizer()
    try
        rb_configure!(native,options,log_path)
        load_spool_native!(native,ctx.master_directory,ctx.master)
        nz=Int(ctx.master["nonzeros"])
        for cut in cuts
            row=rb_cut_row(cut,ctx)
            HiGHS.Highs_addRow(native,row.lower,Inf,length(row.index),row.index,row.values)==HiGHS.kHighsStatusOk ||
                error("Cold master cut insertion failed")
            nz+=length(row.index)
        end
        HiGHS.Highs_getNumRow(native)==ctx.master["rows"]+length(cuts) &&
            HiGHS.Highs_getNumNz(native)==nz || error("Cold native load changed source rows")
    catch
        finalize(native);rethrow()
    end
    native
end

function rb_cold_master_result(ctx,config,request,directory,primal,audit,phases,options,started;
        label,primal_file)
    last=phases[end]
    stats=Dict("native_status"=>last["native_status"],"termination"=>last["termination"],
        "has_primal"=>!isempty(primal),"objective"=>audit===nothing ? nothing : audit["objective"],
        "bound"=>nothing,"relative_gap"=>nothing,"nodes"=>sum(p["nodes"] for p in phases),
        "solve_seconds"=>sum(p["solve_seconds"] for p in phases),
        "solve_wall_seconds"=>sum(p["solve_wall_seconds"] for p in phases),
        "simplex_iterations"=>sum(p["simplex_iterations"] for p in phases),
        "barrier_iterations"=>sum(p["barrier_iterations"] for p in phases),
        "bound_scope"=>"none_for_original_MILP_primal_heuristic_only",
        "termination_scope"=>"last_constructor_or_restricted_LP_not_original_economic_MILP",
        "selected_primal"=>label)
    Dict("schema"=>RB_RESULT_SCHEMA,"mode"=>"master","complete"=>true,"pid"=>getpid(),
        "identity"=>ctx.identity,"statistics"=>stats,"options"=>options,
        "start"=>Dict("supplied"=>false,"native_consumption_reported"=>false,
            "scope"=>"cold construction within this attempt; fresh cost LP without start or basis"),
        "primal"=>rb_binary(joinpath(directory,primal_file),primal),"audit"=>audit,
        "cut_count"=>length(rb_load_cuts(request,ctx)),"solve_calls"=>length(phases),
        "wall_seconds"=>time()-started,"primal_policy"=>RB_COLD_PRIMAL_POLICY,"phases"=>deepcopy(phases),
        "native_backend"=>native_highs_identity(config),
        "request_sha256"=>spool_sha(joinpath(directory,"request.json")))
end

function rb_cold_master_round(ctx,config,request,directory;deadline,on_event=(n,d)->nothing)
    get(config,"scheduling_benders_primal_policy","off")==RB_COLD_PRIMAL_POLICY || error("Unregistered cold master policy")
    request["start"]===nothing || error("Cold construction cannot use a prior optimized start")
    cuts=rb_load_cuts(request,ctx);options=isolated_options(config);started=time();phases=Any[]
    cost,inventory=rb_online_objective(ctx;deadline=deadline)
    on_event("cold_online_objective_ready",inventory)
    primal=Float64[];audit=nothing
    native=rb_load_cold_native(ctx,options,joinpath(directory,"construction.log"),cuts)
    try
        n=ctx.master["variables"]
        HiGHS.Highs_changeColsCostByRange(native,0,n-1,cost)==HiGHS.kHighsStatusOk &&
            HiGHS.Highs_changeObjectiveOffset(native,0.0)==HiGHS.kHighsStatusOk || error("Construction objective rejected")
        cost=nothing;GC.gc(true)
        stat=rb_native_run!(native,deadline,config["scheduling_benders_construction_seconds"],on_event,
            Dict("mode"=>"master","phase"=>"online_construction"))
        stat["phase"]="online_construction";stat["objective_scope"]=inventory["objective_scope"]
        stat["nodes"]=spool_native_info(native,"mip_node_count",Int64)
        stat["construction_objective"]=stat["has_primal"] ? HiGHS.Highs_getObjectiveValue(native) : nothing
        if stat["has_primal"]
            primal=Vector{Float64}(undef,n)
            HiGHS.Highs_getSolution(native,primal,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk || error("Construction extraction failed")
        end
        push!(phases,stat)
    finally
        finalize(native)
    end
    native=nothing;GC.gc(true)
    if isempty(primal)
        return rb_cold_master_result(ctx,config,request,directory,primal,nothing,phases,options,started;
            label="none",primal_file="master_primal.bin")
    end
    audit=rb_master_audit(ctx,primal,cuts;deadline=deadline)
    # Save a complete original-domain master point BEFORE another native call.
    # Reserve recourse and the complete original scheduling audit are still owed.
    saved=rb_cold_master_result(ctx,config,request,directory,primal,audit,phases,options,started;
        label="online_construction",primal_file="construction_primal.bin")
    atomic_json(joinpath(directory,"construction_result.json"),saved)
    on_event("cold_constructed_master_saved",Dict("objective"=>audit["objective"],
        "maximum_residual"=>audit["maximum_residual"],"not_yet_reserve_or_AC_verified"=>true))
    integer_ids=findall(!iszero,ctx.ma.integer)
    fixed=round.(primal[integer_ids])
    all(abs.(fixed.-primal[integer_ids]).<=1e-8) || error("Fractional construction cannot fix commitment")
    cost_options=copy(options);cost_options["solver"]="simplex";cost_options["presolve"]="on"
    cost_options["dual_feasibility_tolerance"]=1e-9
    native=rb_load_cold_native(ctx,cost_options,joinpath(directory,"fixed_cost.log"),cuts)
    candidate=Float64[]
    try
        n=ctx.master["variables"]
        HiGHS.Highs_changeColsBoundsBySet(native,length(integer_ids),Int32.(integer_ids.-1),fixed,fixed)==HiGHS.kHighsStatusOk ||
            error("Fixed commitment bounds rejected")
        HiGHS.Highs_changeColsIntegralityByRange(native,0,n-1,zeros(HiGHS.HighsInt,n))==HiGHS.kHighsStatusOk ||
            error("Fixed cost LP domains rejected")
        GC.gc(true)
        stat=rb_native_run!(native,deadline,config["scheduling_benders_fixed_cost_seconds"],on_event,
            Dict("mode"=>"master","phase"=>"fixed_commitment_cost_lp"))
        stat["phase"]="fixed_commitment_cost_lp";stat["nodes"]=0
        stat["bound_scope"]="restricted_LP_not_original_MILP"
        stat["fresh_native_model"]=true;stat["presolve"]="on";stat["start_or_basis_supplied"]=false
        stat["integer_columns_fixed"]=length(integer_ids)
        stat["options"]=cost_options
        if stat["has_primal"]
            candidate=Vector{Float64}(undef,n)
            HiGHS.Highs_getSolution(native,candidate,C_NULL,C_NULL,C_NULL)==HiGHS.kHighsStatusOk || error("Fixed cost extraction failed")
        end
        push!(phases,stat)
    finally
        finalize(native)
    end
    label="online_construction_retained"
    if !isempty(candidate)
        fixed_residual=maximum(abs.(candidate[integer_ids].-fixed);init=0.0)
        fixed_residual<=1e-8 || error("Cost LP changed the fixed integer pattern")
        phases[end]["maximum_fixed_integer_residual"]=fixed_residual
        candidate_audit=rb_master_audit(ctx,candidate,cuts;deadline=deadline)
        if candidate_audit["objective"]>=audit["objective"]
            primal=candidate;audit=candidate_audit;label="fixed_commitment_cost_lp"
        end
    end
    rb_cold_master_result(ctx,config,request,directory,primal,audit,phases,options,started;
        label=label,primal_file="master_primal.bin")
end
