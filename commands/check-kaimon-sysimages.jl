# Run with the pinned Kaimon service project in an owned cold process.
using Kaimon, Test, TOML

mktempdir() do temporary
    old_mode = get(ENV, "KAIMON_SYSIMAGE_MODE", nothing)
    old_root = get(ENV, "KAIMON_SYSIMAGE_ROOT", nothing)
    ENV["KAIMON_SYSIMAGE_ROOT"] = joinpath(temporary, "not-published")
    ENV["KAIMON_SYSIMAGE_MODE"] = "auto"
    configs = [
        Kaimon.LaunchConfig(),
        Kaimon.LaunchConfig("2,1", "2", "3G", ["--check-bounds=yes"],
                            "", joinpath(Sys.BINDIR,"julia"), true, "1.13.2"),
        Kaimon.LaunchConfig("", "", "", ["--sysimage=/explicit/image"],
                            "", "", false, ""),
    ]
    project = joinpath(temporary, "quoted project \" \$ value")
    mkpath(project)
    write(joinpath(project, "Project.toml"), "")
    script = "owned_state = 41"
    before = [Kaimon._build_julia_cmd(lc, script; project) for lc in configs]
    before_resolver = which(Kaimon._resolve_sysimage, (Kaimon.LaunchConfig, String))
    include(joinpath(@__DIR__, "kaimon-managed-sysimages.jl"))
    @testset "automatic session selection preserves launch semantics" begin
        # Missing root preserves every original argument and reports child status.
        after = [Base.invokelatest(Kaimon._build_julia_cmd, lc, script; project) for lc in configs]
        @test all(a[1:end-1] == b[1:end-1] for (a,b) in zip(after,before))
        @test all(endswith(a[end],script) for a in after)
        @test all(occursin("KAIMON_CITY_SYSIMAGE",a[end]) for a in after)
        @test which(Kaimon._resolve_sysimage, (Kaimon.LaunchConfig, String)) === before_resolver
        ENV["KAIMON_SYSIMAGE_MODE"] = "off"
        cmd = Base.invokelatest(Kaimon._build_julia_cmd, configs[2], script; project)
        @test cmd[1:end-1] == before[2][1:end-1]
        @test endswith(cmd[end], script)
        @test occursin("KAIMON_CITY_SYSIMAGE", cmd[end])
        @test occursin("off", cmd[end])
        # Caller-specified image is preserved, including its boot script.
        explicit = Base.invokelatest(Kaimon._build_julia_cmd, configs[3], script; project)
        @test explicit[1:end-1] == before[3][1:end-1]
        @test occursin("explicit caller image",explicit[end])
        # Normal test launcher still sees upstream resolver, not automatic selection.
        @test Kaimon._resolve_sysimage(Kaimon.LaunchConfig(), project) == ""
        # The daemon can have a different stack from its managed child overlay.
        # An empty existing artifact root runs selection, then falls back.
        mkpath(ENV["KAIMON_SYSIMAGE_ROOT"])
        wrapper = joinpath(temporary, "probe-wrapper")
        receipt = joinpath(temporary, "child-load-path.txt")
        julia = realpath(joinpath(Sys.BINDIR,"julia"))
        write(wrapper, "#!/bin/sh\nprintf '%s' \"\$JULIA_LOAD_PATH\" > $(repr(receipt))\nexec $(repr(julia)) \"\$@\"\n")
        chmod(wrapper,0o755)
        original_load_path = get(ENV,"JULIA_LOAD_PATH",nothing)
        try
            ENV["JULIA_LOAD_PATH"] = "@stdlib"
            ENV["KAIMON_SYSIMAGE_MODE"] = "auto"
            lc = Kaimon.LaunchConfig("2,1", "", "", String[], "", wrapper, false, "")
            Base.invokelatest(Kaimon._build_julia_cmd, lc, script;project)
            @test read(receipt,String) == Kaimon._build_session_env()["JULIA_LOAD_PATH"]
            @test ENV["JULIA_LOAD_PATH"] == "@stdlib"
        finally
            original_load_path === nothing ? delete!(ENV,"JULIA_LOAD_PATH") : (ENV["JULIA_LOAD_PATH"] = original_load_path)
        end
    end
    old_mode === nothing ? delete!(ENV,"KAIMON_SYSIMAGE_MODE") : (ENV["KAIMON_SYSIMAGE_MODE"] = old_mode)
    old_root === nothing ? delete!(ENV,"KAIMON_SYSIMAGE_ROOT") : (ENV["KAIMON_SYSIMAGE_ROOT"] = old_root)
end

# Optional real-artifact success path. It constructs a command without running
# the image or starting a gate; all Pkg work targets a new owned copy.
if haskey(ENV, "KAIMON_TEST_PROFILE") || haskey(ENV, "KAIMON_TEST_PROJECT")
    profile_file = ENV["KAIMON_TEST_PROFILE"]
    source_project = ENV["KAIMON_TEST_PROJECT"]
    owner = ENV["KAIMON_TEST_OWNED_ROOT"]
    profile = Kaimon.JSON.parsefile(profile_file)
    include(joinpath(@__DIR__, "kaimon-managed-bootstrap.jl"))
    mkpath(owner)
    mktempdir(owner; prefix="selected-hook-") do scratch
        project = realpath(scratch)
        for name in readdir(source_project)
            if name == "Project.toml" || (startswith(name,"Manifest") && endswith(name,".toml"))
                cp(joinpath(source_project,name),joinpath(project,name))
            end
        end
        cp(joinpath(source_project,"src"),joinpath(project,"src"))
        saved = Dict(key=>get(ENV,key,nothing) for key in
                     ("KAIMON_SYSIMAGE_MODE","KAIMON_SYSIMAGE_ROOT","KAIMON_SYSIMAGE_PROFILE"))
        try
            ENV["KAIMON_SYSIMAGE_MODE"] = "required"
            ENV["KAIMON_SYSIMAGE_PROFILE"] = profile_file
            delete!(ENV,"KAIMON_SYSIMAGE_ROOT")
            julia = realpath(joinpath(Sys.BINDIR,"julia"))
            lc = Kaimon.LaunchConfig("2,1", "2", "3G", ["--check-bounds=yes"],
                                    "", julia, false, string(VERSION))
            script = Kaimon._build_session_script(project; allow_restart=false)
            before = Dict(name=>read(joinpath(project,name)) for name in readdir(project)
                          if name == "Project.toml" || startswith(name,"Manifest"))
            cmd = Base.invokelatest(Kaimon._build_julia_cmd, lc, script; project)
            @testset "real selected image command and bootstrap" begin
                @test first(cmd) == julia
                @test cmd[2] == "--sysimage=$(joinpath(profile["artifact"],"image.dylib"))"
                @test cmd[3:end-1] == ["-i","-t","2,1","--gcthreads=2","--heap-size-hint=3G",
                                      "--check-bounds=yes","--project=$project","--startup-file=no","-e"]
                @test startswith(cmd[end], "ENV[\"KAIMON_CITY_SYSIMAGE\"] = $(repr(profile["artifact_id"]))\n" *
                                          "ENV[\"JULIA_PROJECT\"] = $(repr(project))\n")
                original = split(cmd[end], '\n';limit=3)[3]
                @test replace(original,"# Pkg.instantiate completed in neutral prelaunch Julia."=>
                              "Pkg.instantiate(; io=devnull)") == script
                @test all(read(joinpath(project,name)) == content for (name,content) in before)
            end
        finally
            for (key,value) in saved
                value === nothing ? delete!(ENV,key) : (ENV[key] = value)
            end
        end
    end
end
println("CITY_SYSIMAGE_COMMAND_PASS")
