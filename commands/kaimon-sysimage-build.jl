# Invoked by kaimon-sysimage.py in an owned, pinned PackageCompiler environment.
using PackageCompiler, TOML
project, output, workload, cpu_target, packages... = ARGS
PackageCompiler.create_sysimage(packages;
    project, sysimage_path=output, cpu_target,
    incremental=true, include_transitive_dependencies=true,
    precompile_execution_file=workload)
