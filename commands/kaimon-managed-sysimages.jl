# City-managed automatic selection for NEW interactive Kaimon sessions only.
# Include after kaimon-managed-bootstrap.jl. No running gate is modified.
# Intentionally do not override _resolve_sysimage: run_tests uses that function
# for isolated test environments which must retain their existing semantics.
let
    Base.pkgversion(Kaimon) == v"2.9.0" || error("Revalidate city sysimage hook after upgrading Kaimon")
    config = Kaimon.LaunchConfig("2,1", "2", "3G", ["--check-bounds=yes"],
                                "", "/city-probe/julia", false, "1.12.7")
    expected = ["/city-probe/julia", "-i", "-t", "2,1", "--gcthreads=2",
                "--heap-size-hint=3G", "--check-bounds=yes", "--project=/city probe/project",
                "--startup-file=no", "-e", "city_probe = 41"]
    Kaimon._build_julia_cmd(config, "city_probe = 41"; project="/city probe/project") == expected ||
        error("Kaimon command builder changed; revalidate city sysimage hook")
end

@eval Kaimon begin
    const _city_sysimage_selector = $(joinpath(@__DIR__, "kaimon-sysimage.py"))

    function _city_status!(cmd::Vector{String}, status::String)
        cmd[end] = "ENV[\"KAIMON_CITY_SYSIMAGE\"] = $(repr(status))\n" * cmd[end]
        return cmd
    end

    function _city_select_sysimage!(cmd::Vector{String}, lc::LaunchConfig, project::String)
        isempty(project) && return _city_status!(cmd,"no exact project")
        if !isempty(lc.sysimage) || any(f -> startswith(f,"--sysimage") || startswith(f,"-J"),lc.extra_flags)
            return _city_status!(cmd,"explicit caller image")
        end
        recipe_file = joinpath(project,"kaimon.toml")
        recipe = isfile(recipe_file) ? get(TOML.parsefile(recipe_file),"city_sysimage",Dict()) : Dict()
        mode = get(ENV,"KAIMON_SYSIMAGE_MODE",get(recipe,"mode","auto"))
        mode in ("off","auto","required") || error("Unknown city sysimage mode: $mode")
        mode == "off" && return _city_status!(cmd,"off")
        if any(f -> f in ("--compiled-modules=no","--compiled-modules=existing"),lc.extra_flags)
            mode == "required" && error("Required city image conflicts with caller cache policy")
            return _city_status!(cmd,"off: caller cache policy")
        end
        city = get(ENV,"GC_CITY","/Users/Shared/Developer/ai/city/math-city")
        root = get(ENV,"KAIMON_SYSIMAGE_ROOT",get(recipe,"artifact_root",""))
        profile = get(ENV,"KAIMON_SYSIMAGE_PROFILE",
                      get(recipe,"profile",joinpath(city,".gc","kaimon-sysimages","current","profile.json")))
        explicit_profile = haskey(ENV,"KAIMON_SYSIMAGE_PROFILE") || haskey(recipe,"profile")
        explicit_artifact = get(recipe,"artifact","")
        if !explicit_profile && !isempty(root) && !isdir(root) && !isfile(profile) && isempty(explicit_artifact)
            mode == "required" && error("Required city image artifact root is missing: $root")
            return _city_status!(cmd,"unavailable: artifact root missing")
        end
        if !explicit_profile && isempty(root) && !isfile(profile) && isempty(explicit_artifact) &&
           !isdir(joinpath(city,".gc","kaimon-sysimages","artifacts"))
            mode == "required" && error("Required city image profile/artifact is missing")
            return _city_status!(cmd,"unavailable: no city image profile or artifact directory")
        end
        argv = [_city_sysimage_selector,"select","--project",project,"--julia",first(cmd),
                "--bootstrap-project",pkgdir(KaimonGate),"--managed-script",cmd[end]]
        !isempty(root) && append!(argv,["--root",root])
        (explicit_profile || isfile(profile)) && append!(argv,["--profile",profile])
        !isempty(explicit_artifact) && append!(argv,["--artifact",explicit_artifact])
        if isempty(lc.julia_bin) && !isempty(lc.julia_version)
            append!(argv,["--requested-julia",lc.julia_version])
        end
        errors = IOBuffer()
        status = ""
        try
            # spawn_session! applies this overlay after building the command.
            # Probe the same child stack, rather than the daemon's own stack.
            child_load_path = _build_session_env()["JULIA_LOAD_PATH"]
            selector = addenv(Cmd(argv), "JULIA_LOAD_PATH"=>child_load_path)
            selected = JSON.parse(read(pipeline(selector;stderr=errors),String))
            image = String(selected["image"])
            isabspath(image) && isfile(image) || error("Invalid selector response")
            # The parent already has --project; pin the inherited environment
            # for later Base.julia_cmd() children which inherit -J only.
            cmd[end] = "ENV[\"JULIA_PROJECT\"] = $(repr(realpath(project)))\n" * String(selected["script"])
            insert!(cmd,2,"--sysimage=$image")
            status = basename(dirname(image))
            _push_log!(:info,"City dependency image $status selected for $project")
        catch error
            diagnostic = strip(String(take!(errors)))
            isempty(diagnostic) && (diagnostic = sprint(showerror,error))
            status = "rejected: " * diagnostic
            _push_log!(:warn,"City dependency image rejected for $project; using normal Julia: $diagnostic")
            mode == "required" && rethrow()
        end
        return _city_status!(cmd,status)
    end

    function _build_julia_cmd(lc::LaunchConfig, script::String; project::String="")
        cmd = [_launch_julia_exe(lc), "-i"]
        sysimage = _resolve_sysimage(lc, project)
        !isempty(sysimage) && push!(cmd, "--sysimage=$sysimage")
        threads = isempty(lc.threads) ? "auto" : lc.threads
        append!(cmd, ["-t", threads])
        !isempty(lc.gcthreads) && push!(cmd, "--gcthreads=$(lc.gcthreads)")
        !isempty(lc.heap_size_hint) && push!(cmd, "--heap-size-hint=$(lc.heap_size_hint)")
        append!(cmd, lc.extra_flags)
        !isempty(project) && push!(cmd, "--project=$project")
        push!(cmd, lc.startup_file ? "--startup-file=yes" : "--startup-file=no")
        append!(cmd, ["-e", script])
        _city_select_sysimage!(cmd, lc, project)
    end
end
