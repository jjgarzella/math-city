# Explicit, task-owned Project/source/lockfile alignment. No canonical writes.
using Pkg, TOML, SHA
project, union_manifest, path_map, owned_root = ARGS
@assert realpath(dirname(Base.active_project())) == realpath(project)
pfile = joinpath(project, "Project.toml")
p = TOML.parsefile(pfile)
original_project = deepcopy(p)
m = TOML.parsefile(union_manifest)
paths = isempty(path_map) ? Dict{String,String}() : TOML.parsefile(path_map)
explicit_paths = Set(keys(paths))
for (name, values) in m["deps"]
    entry = only(values)
    if haskey(entry, "path") && !haskey(paths, name)
        paths[name] = abspath(dirname(union_manifest), entry["path"])
    end
end
if haskey(p, "name")
    if haskey(m["deps"],p["name"]) && haskey(only(m["deps"][p["name"]]),"git-tree-sha1")
        error("The root package is an immutable image dependency; use normal Julia for its development")
    end
    paths[p["name"]] = project
end
for (name, source) in get(p,"sources",Dict())
    if haskey(source,"path") && !(name in explicit_paths)
        paths[name] = abspath(project,source["path"])
    end
end
for (name, path) in paths
    haskey(m["deps"], name) || continue
    frozen = only(m["deps"][name])
    haskey(frozen,"git-tree-sha1") && error("Local source overrides frozen external dependency: " * name)
    declared = get(get(p,"sources",Dict()),name,nothing)
    if haskey(get(p,"deps",Dict()),name) && !(name in explicit_paths)
        if declared !== nothing && haskey(declared,"url")
            error("URL source would change for " * name * "; supply an explicit --path-map choice")
        elseif declared === nothing && startswith(relpath(realpath(path),realpath(owned_root)),"..")
            error("Foreign local dependency " * name * " requires explicit --path-map selection")
        end
    end
    m["deps"][name][1]["path"] = path == project ? "." : path
    if haskey(get(p, "deps", Dict()), name)
        if name in explicit_paths || declared === nothing
            replacement = Dict("path"=>path)
            declared != replacement && println("Source alignment ", name, ": ", repr(declared), " -> ", repr(replacement))
            get!(p,"sources",Dict())[name] = replacement
        end
    end
end
# The CLI describes and backs up these changes before calling this script.
if p != original_project
    open(pfile,"w") do io
        TOML.print(io,p;sorted=true)
    end
end
series = "$(VERSION.major).$(VERSION.minor)"
mfile = joinpath(project, "Manifest-v$series.toml")
delete!(m,"project_hash")
open(mfile,"w") do io
    TOML.print(io,m;sorted=true)
end
env = Pkg.Types.EnvCache(pfile)
m["project_hash"] = Pkg.Types.workspace_resolve_hash(env)
m["city_path_project_hashes"] = Dict(name=>Dict(
    "uuid"=>only(values)["uuid"], "path"=>only(values)["path"],
    "sha256"=>bytes2hex(sha256(read(joinpath(project,only(values)["path"],"Project.toml")))))
    for (name,values) in m["deps"] if haskey(only(values),"path"))
open(mfile,"w") do io
    TOML.print(io,m;sorted=true)
end
# Validate declared sources against their explicit owned path overlays and
# install missing pinned artifacts without resolving/upgrading the graph.
Pkg.instantiate(;allow_autoprecomp=false)
@assert Pkg.is_manifest_current(project) === true
println("CITY_SYSIMAGE_PREPARE_PASS ", mfile)
