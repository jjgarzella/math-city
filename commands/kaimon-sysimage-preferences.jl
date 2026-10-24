# Read-only Base/TOML probe; never import packages whose UUIDs are queried.
using TOML, SHA
function preference_audit(args)
    count = parse(Int, args[1])
    ids = Base.UUID.(args[2:count+1])
    request = TOML.parse(args[count+2])
    stacks = request["stacks"]
    extensions = sort!([Base.uuid5(Base.UUID(id), name) for (id, name) in get(request,"extensions",[])])
    append!(ids, extensions)
    contexts = Dict{String,Any}[]
    original = copy(LOAD_PATH)
    try
        for stack in stacks
            copy!(LOAD_PATH, String.(stack))
            expanded = Base.load_path()
            inputs = Dict{String,String}()
            for entry in expanded
                project = Base.env_project_file(entry)
                project isa String && isfile(project) || continue
                for file in Base.get_projects_workspace_to_root(project)
                    # Hash inputs, never disclose preference values (or keys).
                    for candidate in (file, joinpath(dirname(file), "JuliaLocalPreferences.toml"),
                                      joinpath(dirname(file), "LocalPreferences.toml"))
                        inputs[candidate] = isfile(candidate) ? bytes2hex(SHA.sha256(read(candidate))) : "absent"
                    end
                end
            end
            nonempty = String[]
            for id in ids
                prefs = Base.get_preferences(id)
                # Base resolves clears but retains this reserved control key.
                # Preferences.load_preference returns data with clears removed.
                delete!(prefs, "__clear__")
                isempty(prefs) || push!(nonempty, string(id))
            end
            sort!(nonempty)
            push!(contexts, Dict("load_path"=>stack, "expanded_load_path"=>expanded,
                                 "input_files"=>inputs, "nonempty_uuids"=>nonempty,
                                 "empty"=>isempty(nonempty)))
        end
    catch
        return Dict("failed"=>true)
    finally
        copy!(LOAD_PATH, original)
    end
    Dict("contexts"=>contexts, "queried_extension_uuids"=>string.(extensions))
end
