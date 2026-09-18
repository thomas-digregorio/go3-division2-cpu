# Original translation of source startup-count windows. Independent Python
# checking uses a separate vectorized implementation of the same source rule.
const SOURCE_TIME_EQUALITY_TOLERANCE = 1e-6

function source_startup_window_members(dt,begin_time,end_time)
    starts=vcat(0.0,cumsum(dt)[1:end-1])
    findall(t -> begin_time-SOURCE_TIME_EQUALITY_TOLERANCE <= t <
        end_time-SOURCE_TIME_EQUALITY_TOLERANCE,starts)
end

function without_upstream_startup_windows(input)
    # The pinned upstream window helper uses a different boundary tolerance and
    # asserts on a zero-length window at time zero. Bypass ONLY its window rows
    # on a private lookup copy; install every original source window below.
    # No raw value or other constraint is modified or removed.
    any(!isempty(input.sdd_lookup[u]["startups_ub"]) for u in input.sdd_ids) || return input
    lookup=Dict(u=>merge(d,Dict("startups_ub"=>Any[])) for (u,d) in input.sdd_lookup)
    merge(input,(sdd_lookup=lookup,))
end

function add_source_startup_windows!(model,input)
    rows=Dict{Tuple{String,Int},ConstraintRef}()
    for uid in input.sdd_ids, (w,window) in enumerate(input.sdd_lookup[uid]["startups_ub"])
        a,b,count=window
        members=source_startup_window_members(input.dt,a,b)
        rows[(uid,w)]=@constraint(model,
            sum((model[:u_su][uid,t] for t in members);init=AffExpr(0.0)) <= count)
    end
    model[:source_maximum_startups]=rows
    model.ext[:source_startup_windows]=Dict("windows"=>length(rows),
        "time_equality_tolerance"=>SOURCE_TIME_EQUALITY_TOLERANCE,
        "membership"=>"begin-tol <= interval_start < end-tol",
        "source_values_changed"=>false)
    rows
end
