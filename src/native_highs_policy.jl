using Libdl

const NATIVE_SETUP_GUARD_POLICY="setup_clique_guard_v1"

function native_highs_identity(config)
    policy=get(config,"scheduling_native_backend_policy","upstream_jll_v1")
    policy in ("upstream_jll_v1",NATIVE_SETUP_GUARD_POLICY) || error("Unknown native backend")
    path=spool_local(Libdl.dlpath(HiGHS.libhighs))
    result=Dict("policy"=>policy,"library_path"=>path,"library_sha256"=>spool_sha(path),
        "version"=>unsafe_string(HiGHS.Highs_version()),"git_hash"=>unsafe_string(HiGHS.Highs_githash()),
        "floating_point_bits"=>64,"highs_int_bits"=>8*sizeof(HiGHS.HighsInt))
    if policy==NATIVE_SETUP_GUARD_POLICY
        root=normpath(joinpath(@__DIR__,".."))
        manifest=joinpath(root,"manifests","native_highs_setup_guard_v1.json")
        build=JSON.parsefile(manifest)
        library=build["files"]["library"]
        normpath(path)==normpath(spool_local(joinpath(root,library["path"]))) &&
            result["library_sha256"]==library["sha256"] && result["version"]=="1.15.1" &&
            result["highs_int_bits"]==32 || error("Unregistered native library loaded")
        result["manifest_sha256"]=spool_sha(manifest)
        result["objective_clique_max_size"]=config["scheduling_native_objective_clique_max_size"]
    end
    result
end
