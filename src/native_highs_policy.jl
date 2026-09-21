using Libdl

const NATIVE_SETUP_GUARD_POLICY="setup_clique_guard_v1"
const NATIVE_ROOT_MEMORY_POLICY="root_memory_guard_v1"
const NATIVE_ROOT_PROGRESS_POLICY="root_progress_guard_v1"
const NATIVE_ROOT_POLICIES=(NATIVE_ROOT_MEMORY_POLICY,NATIVE_ROOT_PROGRESS_POLICY)
const NATIVE_GUARD_MANIFESTS=Dict(
    NATIVE_SETUP_GUARD_POLICY=>"native_highs_setup_guard_v1.json",
    NATIVE_ROOT_MEMORY_POLICY=>"native_highs_root_memory_guard_v1.json",
    NATIVE_ROOT_PROGRESS_POLICY=>"native_highs_root_progress_guard_v1.json")

function native_highs_identity(config)
    policy=get(config,"scheduling_native_backend_policy","upstream_jll_v1")
    policy=="upstream_jll_v1" || haskey(NATIVE_GUARD_MANIFESTS,policy) || error("Unknown native backend")
    path=spool_local(Libdl.dlpath(HiGHS.libhighs))
    result=Dict("policy"=>policy,"library_path"=>path,"library_sha256"=>spool_sha(path),
        "version"=>unsafe_string(HiGHS.Highs_version()),"git_hash"=>unsafe_string(HiGHS.Highs_githash()),
        "floating_point_bits"=>64,"highs_int_bits"=>8*sizeof(HiGHS.HighsInt))
    if haskey(NATIVE_GUARD_MANIFESTS,policy)
        root=normpath(joinpath(@__DIR__,".."))
        manifest=joinpath(root,"manifests",NATIVE_GUARD_MANIFESTS[policy])
        build=JSON.parsefile(manifest)
        library=build["files"]["library"]
        normpath(path)==normpath(spool_local(joinpath(root,library["path"]))) &&
            result["library_sha256"]==library["sha256"] && result["version"]=="1.15.1" &&
            result["highs_int_bits"]==32 || error("Unregistered native library loaded")
        result["manifest_sha256"]=spool_sha(manifest)
        result["objective_clique_max_size"]=config["scheduling_native_objective_clique_max_size"]
        if policy in NATIVE_ROOT_POLICIES
            get(config,"scheduling_native_analytic_center",nothing)===false ||
                error("Root-memory guard requires analytic center disabled")
            result["analytic_center_requested"]=false
            if haskey(config,"scheduling_native_root_presolve_only")
                config["scheduling_native_root_presolve_only"] isa Bool ||
                    error("Root-only presolve must be Boolean")
                result["root_presolve_only_requested"]=config["scheduling_native_root_presolve_only"]
            end
        end
        if policy==NATIVE_ROOT_PROGRESS_POLICY
            get(config,"scheduling_native_root_lp_logging",nothing)===true ||
                error("Root-progress guard requires explicit logging enabled")
            result["root_lp_logging_requested"]=true
        end
    end
    result
end
