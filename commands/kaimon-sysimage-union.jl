# Run in a dedicated owned resolver session; never activate canonical projects.
# Arguments can also be supplied by setting city_union_root/city_project_root.
using Pkg, TOML, SHA
union_root = @isdefined(city_union_root) ? city_union_root : ARGS[1]
project_root = @isdefined(city_project_root) ? city_project_root : ARGS[2]
@assert realpath(dirname(Base.active_project())) == realpath(union_root)

projects = Dict{String,Any}()
excluded = @isdefined(city_excluded_projects) ? city_excluded_projects : Set{String}()
for path in sort(readdir(project_root; join=true))
    file = joinpath(path, "Project.toml")
    isfile(file) || continue
    project = TOML.parsefile(file)
    haskey(project, "name") && haskey(project, "uuid") || continue
    project["name"] in excluded && continue
    if project["name"] == "Nemo" && @isdefined(city_modern_nemo)
        path = city_modern_nemo
        file = joinpath(path, "Project.toml")
        project = TOML.parsefile(file)
    end
    projects[project["name"]] = (path=path, project=project,
                               sha256=bytes2hex(sha256(read(file))))
end
gate_path = pkgdir(KaimonGate)
projects["KaimonGate"] = (path=gate_path, project=TOML.parsefile(joinpath(gate_path, "Project.toml")),
                        sha256=bytes2hex(sha256(read(joinpath(gate_path, "Project.toml")))))

# A repository's declared URL/revision is authoritative even for another city
# package. Validate the clean workload checkout against it, then keep that Git
# source in the lock: Pkg rejects URL declarations paired with path entries.
pinned_sources = Dict{String,Any}()
pinned_trees = Dict{String,String}()
for entry in values(projects), (name, source) in get(entry.project, "sources", Dict())
    haskey(projects, name) && haskey(source, "url") && haskey(source, "rev") || continue
    haskey(pinned_sources, name) && pinned_sources[name] != source &&
        error("Conflicting pinned city sources: " * name)
    path = projects[name].path
    git(args...) = strip(read(`git -C $path $args`, String))
    normalize(url) = replace(rstrip(url, '/'), r"\.git$" => "")
    normalize(git("remote", "get-url", "origin")) == normalize(source["url"]) ||
        error("Workload checkout URL differs from declared source: " * name)
    git("rev-parse", "HEAD") == git("rev-parse", source["rev"] * "^{commit}") ||
        error("Workload checkout revision differs from declared source: " * name)
    isempty(git("status", "--porcelain")) || error("Pinned workload checkout is dirty: " * name)
    pinned_sources[name] = source
    pinned_trees[name] = git("rev-parse", "HEAD^{tree}")
end

# A current development root can have additional requirements while another
# workload still pins an older Git release of that same package. Supplement
# dependency/compat constraints without substituting the pinned package source.
requirements = copy(projects)
for path in (@isdefined(city_supplemental_projects) ? city_supplemental_projects : String[])
    file = joinpath(path, "Project.toml")
    project = TOML.parsefile(file)
    name = project["name"]
    haskey(projects, name) || error("Supplement must describe an existing workload: " * name)
    project["uuid"] == projects[name].project["uuid"] || error("Supplement UUID mismatch: " * name)
    isempty(get(project, "sources", Dict())) || error("Supplement cannot change dependency sources: " * name)
    label = name * " (supplemental constraints)"
    haskey(requirements, label) && error("Duplicate supplemental workload: " * name)
    requirements[label] = (path=path, project=project, sha256=bytes2hex(sha256(read(file))))
end

deps = Dict{String,String}()
sources = Dict{String,Any}()
compat = Dict{String,Pkg.Versions.VersionSpec}()
exact_pins = Dict{String,String}()
matrix = Dict{String,Any}()
for (name, entry) in sort(collect(projects); by=first)
    project = entry.project
    deps[name] = project["uuid"]
    # Nemo is a pinned external dependency for Oscar. Its own modern development
    # checkout remains editable and will be refused by image selection.
    if name == "Nemo" && @isdefined(city_modern_nemo)
        compat[name] = Pkg.Versions.semver_spec("=" * project["version"])
        exact_pins[name] = project["version"]
    else
        sources[name] = get(pinned_sources, name, Dict("path"=>entry.path))
    end
    for (dependency, source) in get(project, "sources", Dict())
        # City packages use the exact discovered local source, remaining editable.
        haskey(projects, dependency) && continue
        if haskey(sources, dependency) && sources[dependency] != source
            error("Conflicting sources for " * dependency)
        end
        sources[dependency] = source
    end
end
for (name, entry) in sort(collect(requirements); by=first)
    project = entry.project
    for (dependency, id) in get(project, "deps", Dict())
        haskey(deps, dependency) && deps[dependency] != id && error("UUID collision: " * dependency)
        deps[dependency] = id
    end
    parsed = Pkg.Types.read_project(joinpath(entry.path, "Project.toml"))
    for (dependency, bound) in parsed.compat
        # Test extras are recorded but are not runtime dependency constraints.
        dependency == "julia" || haskey(get(project, "deps", Dict()), dependency) || continue
        compat[dependency] = haskey(compat, dependency) ? intersect(compat[dependency], bound.val) : bound.val
        origins = get!(matrix, dependency, Any[])
        push!(origins, Dict("repo"=>name, "declared"=>get(project["compat"], dependency, ""),
                            "parsed"=>string(bound.val), "project_sha256"=>entry.sha256))
    end
end
for (name, bound) in compat
    isempty(bound) && error("Empty declared compatibility intersection: " * name)
end
# The managed boot loads the gate before the math packages. Keep its installed
# external hard-dependency pins, rather than silently replacing them via image.
gate_manifest = TOML.parsefile(joinpath(gate_path, "Manifest.toml"))["deps"]
gate_pending = collect(keys(projects["KaimonGate"].project["deps"]))
gate_seen = Set{String}()
while !isempty(gate_pending)
    name = pop!(gate_pending)
    name in gate_seen && continue
    push!(gate_seen, name)
    entry = only(gate_manifest[name])
    append!(gate_pending, get(entry, "deps", String[]))
    haskey(entry, "git-tree-sha1") || continue  # bundled stdlibs follow exact runtime
    deps[name] = entry["uuid"]
    bound = Pkg.Versions.semver_spec("=" * first(split(entry["version"], '+')))
    exact_pins[name] = entry["version"]
    compat[name] = haskey(compat, name) ? intersect(compat[name], bound) : bound
    isempty(compat[name]) && error("Installed gate dependency conflicts with union: " * name)
    push!(get!(matrix, name, Any[]), Dict("repo"=>"installed KaimonGate bootstrap",
          "declared"=>"=" * entry["version"], "parsed"=>string(bound),
          "git-tree-sha1"=>entry["git-tree-sha1"]))
end
result = Dict("deps"=>deps, "sources"=>sources,
              "compat"=>Dict(name=>(haskey(exact_pins,name) ? "=" * first(split(exact_pins[name], '+')) :
                  replace(string(bound), "["=>"", "]"=>"")) for (name,bound) in compat))
open(joinpath(union_root, "Project.toml"), "w") do io
    TOML.print(io, result; sorted=true)
end
open(joinpath(union_root, "constraint-matrix.toml"), "w") do io
    TOML.print(io, Dict("julia"=>string(VERSION), "constraints"=>matrix,
        "projects"=>Dict(n=>Dict("path"=>e.path, "sha256"=>e.sha256) for (n,e) in requirements)); sorted=true)
end
open(joinpath(union_root, "resolve.log"), "w") do io
    try
        Pkg.resolve(; io)
        resolved = TOML.parsefile(joinpath(union_root, "Manifest.toml"))["deps"]
        for (name, source) in pinned_sources
            actual = only(resolved[name])
            get(actual, "repo-url", nothing) == source["url"] &&
                get(actual, "repo-rev", nothing) == source["rev"] &&
                get(actual, "git-tree-sha1", nothing) == pinned_trees[name] ||
                error("Resolved source differs from audited workload checkout: " * name)
        end
        for name in gate_seen
            expected = only(gate_manifest[name])
            haskey(expected, "git-tree-sha1") || continue
            actual = only(resolved[name])
            for key in ("version", "git-tree-sha1")
                actual[key] == expected[key] || error("Installed gate pin changed: " * name * " " * key)
            end
        end
        write(io, "\nCITY_UNION_RESOLVE_PASS\n")
        flush(io)
    catch error
        showerror(io, error, catch_backtrace())
        flush(io)
        rethrow()
    end
end
Dict("julia"=>string(VERSION), "project"=>Base.active_project(),
     "direct_dependencies"=>sort(collect(keys(deps))), "constraint_matrix"=>matrix)
