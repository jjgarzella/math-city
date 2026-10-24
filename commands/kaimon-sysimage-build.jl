# Invoked by kaimon-sysimage.py in an owned, pinned PackageCompiler environment.
using PackageCompiler, TOML
project, output, workload, cpu_target, packages... = ARGS
include(joinpath(@__DIR__, "kaimon-sysimage-preferences.jl"))
# Recheck the serialized child's exact stack immediately before construction.
manifest = TOML.parsefile(joinpath(project, "Manifest.toml"))
entries = [only(items) for items in values(manifest["deps"])]
ids = sort!(unique([entry["uuid"] for entry in entries]))
extensions = [[entry["uuid"], name] for entry in entries for name in keys(get(entry,"extensions",Dict()))]
stack = sprint(io->TOML.print(io,Dict("stacks"=>[[project,"@stdlib"]],"extensions"=>extensions)))
audit = preference_audit([string(length(ids)); ids; stack])
get(audit, "failed", false) && error("cannot audit baked-package preferences before construction")
all(context["empty"] for context in audit["contexts"]) ||
    error("non-default baked-package preferences before image construction")
PackageCompiler.create_sysimage(packages;
    project, sysimage_path=output, cpu_target,
    incremental=true, include_transitive_dependencies=true,
    precompile_execution_file=workload)
