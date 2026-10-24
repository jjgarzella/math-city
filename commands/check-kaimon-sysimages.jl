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
println("CITY_SYSIMAGE_COMMAND_PASS")
