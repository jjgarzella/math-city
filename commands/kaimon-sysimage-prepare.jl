# Explicit, task-owned Project/source/lockfile alignment. No canonical writes.
using Pkg, TOML, SHA
project, union_manifest, path_map, owned_root = ARGS[1:4]
preserve_project = length(ARGS) > 4 && ARGS[5] == "preserve-project"
editable_root = length(ARGS) > 5 && ARGS[6] == "editable-root"
# The CLI's EDITABLE set is excluded by the builder, even when another city
# project pins that package's Git source. Artifact validation still checks UUIDs.
project = realpath(project)
owned_root = realpath(owned_root)
@assert project == owned_root || startswith(project,owned_root * "/") "Target is outside owned root"
@assert any(part in (".gc","worktrees") for part in splitpath(owned_root)) "Not an isolated task/worktree root"
pfile = joinpath(project, "Project.toml")
@assert !islink(pfile) "Refusing symlinked Project target"
@assert !islink(joinpath(project,"Manifest-v$(VERSION.major).$(VERSION.minor).toml")) "Refusing symlinked Manifest target"
p = TOML.parsefile(pfile)
original_project = deepcopy(p)
m = TOML.parsefile(union_manifest)
frozen = m["deps"]
explicit_paths = isempty(path_map) ? Dict{String,String}() : TOML.parsefile(path_map)

declared_source_matches(source, path, declaring_file) =
    source !== nothing && haskey(source, "path") &&
    realpath(joinpath(dirname(declaring_file), source["path"])) == path
root_name = get(p,"name","")
root_uuid = get(p,"uuid","")
if !editable_root && haskey(frozen,root_name) && haskey(only(frozen[root_name]),"git-tree-sha1")
    error("The root package is an immutable image dependency; use normal Julia for its development")
end

# Pkg's actual workspace declaration, including nested workspace projects.
workspace = Pkg.Types.collect_workspace(pfile)
selected = Dict{String,Any}()
selected_paths = Dict{String,String}()
pending = Tuple{String,String,String,Dict{String,Any}}[]
for (file, _) in workspace
    data = TOML.parsefile(file)
    for (name,id) in get(data,"deps",Dict())
        push!(pending,(name,id,file,data))
    end
end

while !isempty(pending)
    name, id, parent_file, parent = pop!(pending)
    if name == root_name
        id == root_uuid || error("Root UUID mismatch: " * name)
        continue
    end
    haskey(frozen,name) || error("Union lock does not cover target/workspace dependency: " * name)
    entry = deepcopy(only(frozen[name]))
    entry["uuid"] == id || error("Union UUID mismatch: " * name)
    parent_source = get(get(parent,"sources",Dict()),name,nothing)
    root_source = get(get(p,"sources",Dict()),name,nothing)
    declared = root_source === nothing ? parent_source : root_source
    declaring_file = root_source === nothing ? parent_file : pfile

    if haskey(entry,"path")
        path = if haskey(explicit_paths,name)
            realpath(explicit_paths[name])
        elseif declared !== nothing && haskey(declared,"path")
            realpath(joinpath(dirname(declaring_file),declared["path"]))
        else
            error("Editable dependency " * name * " requires explicit --path-map or declared local source; refusing inherited union path")
        end
        if haskey(selected_paths,name)
            selected_paths[name] == path || error("Conflicting local source choices: " * name)
        end
        local_file = joinpath(path,"Project.toml")
        local_project = TOML.parsefile(local_file)
        get(local_project,"uuid","") == id || error("Local source UUID mismatch: " * name)
        get(local_project,"name",name) == name || error("Local source name mismatch: " * name)
        get(local_project,"version","0.0.0") == get(entry,"version","0.0.0") ||
            error("Local source version differs from union lock: " * name)
        local_deps = get(local_project,"deps",Dict())
        Set(keys(local_deps)) == Set(get(entry,"deps",String[])) ||
            error("Local source dependencies differ from union lock; resolve the common union first: " * name)
        entry["path"] = path
        selected_paths[name] = path
        if haskey(get(p,"deps",Dict()),name) && haskey(explicit_paths,name)
            replacement = Dict("path"=>path)
            if !declared_source_matches(root_source, path, pfile)
                println("Source alignment ",name,": ",repr(root_source)," -> ",repr(replacement))
                get!(p,"sources",Dict())[name] = replacement
            end
        end
        if !haskey(selected,name)
            selected[name] = [entry]
            for (dependency,dependency_id) in local_deps
                push!(pending,(dependency,dependency_id,local_file,local_project))
            end
        end
    else
        if haskey(explicit_paths,name) || (declared !== nothing && haskey(declared,"path"))
            error("Local source overrides frozen external dependency: " * name)
        end
        if declared !== nothing && haskey(declared,"url")
            get(entry,"repo-url",nothing) == declared["url"] || error("Source URL differs from union lock: " * name)
            haskey(declared,"rev") && get(entry,"repo-rev",nothing) != declared["rev"] &&
                error("Source revision differs from union lock: " * name)
        end
        if !haskey(selected,name)
            selected[name] = [entry]
            for dependency in get(entry,"deps",String[])
                dependency == root_name && continue
                haskey(frozen,dependency) || error("Union lock lacks transitive dependency: " * dependency)
                push!(pending,(dependency,only(frozen[dependency])["uuid"],parent_file,Dict{String,Any}()))
            end
        end
    end
end

# Carry only the target/workspace hard closure, without rootself or other repos.
for values in values(selected)
    entry = only(values)
    weak = get(entry,"weakdeps",nothing)
    if weak isa Vector
        # Names alone are ambiguous once an optional package is pruned. Keep
        # UUID declarations without importing optional nodes into the closure.
        entry["weakdeps"] = Dict(name=>only(frozen[name])["uuid"] for name in weak)
    end
end
m["deps"] = selected
for name in ("project_hash","city_path_project_hashes","city_workspace_project_hashes")
    delete!(m,name)
end
if p != original_project
  preserve_project && error("preparation would change Project.toml; preserving declared sources")
  let
    # Preserve unrelated text, comments and table order. Only replace source
    # tables; unusual TOML syntax falls back to serialization with an exact diff.
    original_text = read(pfile,String)
    source_text = sprint(io->TOML.print(io,Dict("sources"=>p["sources"]);sorted=true))
    kept = String[]
    source_comments = String[]
    in_sources = false
    for line in split(original_text,'\n';keepempty=true)
        header = match(r"^\s*\[([^\]]+)\]\s*(?:#.*)?$",line)
        if header !== nothing
            table = strip(header.captures[1])
            in_sources = table == "sources" || startswith(table,"sources.")
        end
        if !in_sources
            push!(kept,line)
        elseif startswith(strip(line),"#")
            push!(source_comments,line)
        end
    end
    proposal = join(kept,"\n") * "\n" * join(source_comments,"\n") * "\n" * source_text
    matches = try TOML.parse(proposal) == p catch; false end
    matches || (proposal = sprint(io->TOML.print(io,p;sorted=true)))
    write(pfile,proposal)
  end
end
series = "$(VERSION.major).$(VERSION.minor)"
mfile = joinpath(project,"Manifest-v$series.toml")
open(mfile,"w") do io
    TOML.print(io,m;sorted=true)
end
env = Pkg.Types.EnvCache(pfile)
m["project_hash"] = Pkg.Types.workspace_resolve_hash(env)
m["city_path_project_hashes"] = Dict(name=>Dict("uuid"=>only(selected[name])["uuid"],
    "path"=>path,"sha256"=>bytes2hex(SHA.sha256(read(joinpath(path,"Project.toml")))))
    for (name,path) in selected_paths)
m["city_workspace_project_hashes"] = Dict(relpath(file,project)=>bytes2hex(SHA.sha256(read(file)))
    for file in keys(workspace) if file != pfile)
open(mfile,"w") do io
    TOML.print(io,m;sorted=true)
end
before_boot = bytes2hex(SHA.sha256(read(mfile)))
# Pkg's artifact-selector subprocess inherits Base.active_project(), even
# when instantiate receives an explicit Context. Activate only now, after the
# broken/foreign manifest has been replaced and Pkg loaded from stdlib safely.
Pkg.activate(project;io=devnull)
"@" in LOAD_PATH || pushfirst!(LOAD_PATH,"@")
@assert Base.active_project() == pfile
Pkg.instantiate(Pkg.Types.Context(env=Pkg.Types.EnvCache(pfile));allow_autoprecomp=false)
@assert Pkg.is_manifest_current(project) === true
@assert bytes2hex(SHA.sha256(read(mfile))) == before_boot "Instantiation changed the prepared closure lock"
println("CITY_SYSIMAGE_PREPARE_PASS ",mfile," packages=",length(selected)," editable_stamps=",length(selected_paths))
