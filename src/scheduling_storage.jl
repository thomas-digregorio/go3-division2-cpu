# Storage-only handoff: copy the complete unsolved linear MILP to native HiGHS,
# retain mapped extraction references, then release JuMP's disposable cache.
# No row/column elimination, presolve, coefficient change, or external start.

const SCHEDULING_STORAGE_POLICIES=("cached_model_v1","native_handoff_v1",
    "native_handoff_trimmed_metadata_v1","disk_backed_native_v1")
const SCHEDULING_EXTRACTION_SYMBOLS=(
    :p_on_status,:p,:q,:p_balance_slack_pos,:p_balance_slack_neg,
    :q_balance_slack_pos,:q_balance_slack_neg,
    :p_rgu,:p_rgd,:p_scr,:p_nsc,:p_rru_on,:p_rrd_on,:p_rru_off,:p_rrd_off,:q_qru,:q_qrd)

function scheduling_plain_metadata(x)
    x===nothing || x isa Number || x isa AbstractString || x isa Symbol ||
        (x isa AbstractArray && all(scheduling_plain_metadata,x)) ||
        (x isa AbstractDict && all(p->scheduling_plain_metadata(first(p)) &&
            scheduling_plain_metadata(last(p)),x))
end

function scheduling_constraint_inventory(model)
    Dict(string(F)*" in "*string(S)=>num_constraints(model,F,S)
        for (F,S) in list_of_constraint_types(model))
end

function release_scheduling_construction_metadata!(cached)
    mode(cached)==DIRECT && error("Metadata release requires an unsolved cached model")
    termination_status(cached)==MOI.OPTIMIZE_NOT_CALLED ||
        error("Metadata release must occur before a solve")
    scheduling_plain_metadata(cached.ext) ||
        error("Scheduling metadata contains references that would retain construction storage")
    dictionary=object_dictionary(cached)
    all(s->haskey(dictionary,s),SCHEDULING_EXTRACTION_SYMBOLS[1:7]) ||
        error("Incomplete scheduling extraction dictionary before metadata release")
    started=time()
    nvariables=num_variables(cached)
    inventory=scheduling_constraint_inventory(cached)
    sense=objective_sense(cached)
    live_before=Base.gc_live_bytes()
    removed=String[]
    removed_container_entries=0
    # unregister() removes only symbolic lookup entries; JuMP documents that
    # it does NOT delete their variables/constraints. Affine construction
    # expressions have already been assembled into the original objective.
    # The complete MOI model, all names and extraction references stay intact.
    for symbol in collect(keys(dictionary))
        symbol in SCHEDULING_EXTRACTION_SYMBOLS && continue
        entry=dictionary[symbol]
        removed_container_entries+=applicable(length,entry) ? length(entry) : 1
        push!(removed,string(symbol))
        unregister(cached,symbol)
        entry=nothing
    end
    GC.gc(true)
    num_variables(cached)==nvariables || error("Metadata cleanup changed variable count")
    scheduling_constraint_inventory(cached)==inventory ||
        error("Metadata cleanup changed mathematical constraint inventory")
    objective_sense(cached)==sense || error("Metadata cleanup changed objective sense")
    record=Dict("policy"=>"unregister_disposable_construction_containers_v1",
        "removed_lookup_symbols"=>sort!(removed),
        "removed_container_entries"=>removed_container_entries,
        "retained_lookup_symbols"=>sort!(string.(collect(keys(dictionary)))),
        "mathematical_variables"=>nvariables,"constraint_inventory"=>inventory,
        "rows_or_columns_eliminated"=>0,"source_values_changed"=>false,
        "mathematical_names_changed"=>false,
        "gc_reported_live_bytes_before"=>live_before,
        "gc_reported_live_bytes_after"=>Base.gc_live_bytes(),
        "cleanup_and_gc_seconds"=>time()-started,
        "scope"=>"Symbolic lookup containers only; complete MOI model and names retained")
    cached.ext[:scheduling_metadata_release]=record
    record
end

function native_scheduling_handoff!(cached,optimizer;on_copied=(a,b,m)->nothing)
    mode(cached)==DIRECT && error("Scheduling handoff requires an unsolved cached model")
    termination_status(cached)==MOI.OPTIMIZE_NOT_CALLED ||
        error("Scheduling handoff must occur before a solve")
    scheduling_plain_metadata(cached.ext) ||
        error("Scheduling metadata contains references that would retain the old model")
    started=time()
    nvariables=num_variables(cached)
    inventory=scheduling_constraint_inventory(cached)
    metadata=deepcopy(cached.ext)
    native=direct_model(MOI.instantiate(optimizer))
    for (F,S) in MOI.get(backend(cached),MOI.ListOfConstraintTypesPresent())
        MOI.supports_constraint(backend(native),F,S) ||
            error("Native scheduling handoff cannot omit or bridge unsupported constraints: $F in $S")
    end
    # Public whole-model copy: all rows, bounds, costs and integrality are copied,
    # including variables not needed by the subsequent solution extractor.
    index_map=MOI.copy_to(backend(native),backend(cached))
    reference_map=JuMP.ReferenceMap(native,index_map)
    num_variables(native)==nvariables || error("Native copy changed variable count")
    scheduling_constraint_inventory(native)==inventory || error("Native copy changed constraint inventory")
    objective_sense(native)==objective_sense(cached) || error("Native copy changed objective sense")
    for symbol in SCHEDULING_EXTRACTION_SYMBOLS
        haskey(object_dictionary(cached),symbol) || continue
        native[symbol]=reference_map[cached[symbol]]
    end
    all(s->haskey(object_dictionary(native),s),SCHEDULING_EXTRACTION_SYMBOLS[1:7]) ||
        error("Incomplete native scheduling extraction mapping")
    merge!(native.ext,metadata)
    # Fixture-only callers compare every mapped coefficient/domain before release.
    on_copied(cached,native,index_map)
    empty!(cached)
    num_variables(cached)==0 && isempty(object_dictionary(cached)) ||
        error("Disposable scheduling cache was not released")
    record=Dict("policy"=>"native_handoff_v1","variables"=>nvariables,
        "constraint_inventory"=>inventory,"whole_model_copy"=>true,
        "rows_or_columns_eliminated"=>0,"source_values_changed"=>false,
        "cached_model_emptied"=>true,"native_mode"=>string(mode(native)),
        "mapped_extraction_symbols"=>sort!(string.(collect(keys(object_dictionary(native))))),
        "handoff_seconds_before_gc"=>time()-started,
        "scope"=>"Storage-only public MOI copy; no presolve or external initialization")
    native.ext[:scheduling_storage]=record
    native
end
