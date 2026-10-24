"""Owned selected-wrapper child control; no Gate or daemon is started.

One image parent spawns one inherited-image child WITHOUT --project. A separate
ordinary-Julia control verifies explicit --project precedence over the inherited
environment. All projects and receipts are created below the supplied owner.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--source-project", required=True)
p.add_argument("--artifact", required=True)
p.add_argument("--julia", required=True)
p.add_argument("--owned-root", required=True)
p.add_argument("--wrapper", default=str(Path(__file__).with_name("kaimon-sysimage-julia")))
args = p.parse_args()
source = Path(args.source_project).resolve()
artifact = Path(args.artifact).resolve()
metadata = json.loads((artifact / "metadata.json").read_text())
owner = Path(args.owned_root).resolve()
assert owner != Path("/") and owner != source
owner.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix="inherited-project-", dir=owner))
project = out / "DeRham.jl"
project.mkdir()
for file in source.glob("*.toml"):
    if file.name == "Project.toml" or file.name.startswith("Manifest"):
        shutil.copy2(file, project / file.name)
shutil.copytree(source / "src", project / "src")
binary = str(Path(args.julia).resolve())
recipe = ('[city_sysimage]\nmode = "required"\n' +
          "julia_bin = " + json.dumps(binary) + "\nartifact = " + json.dumps(str(artifact)) + "\n")
(project / "kaimon.toml").write_text(recipe)


def quote(value):
    return json.dumps(str(value), ensure_ascii=False).replace("$", "\\$")


image_file = str(artifact / "image.dylib")
version = metadata["spec"]["runtime"]["version"]
child_code = f'''using TOML
@assert Base.active_project() == {quote(project / "Project.toml")}
@assert string(VERSION) == {quote(version)}
@assert unsafe_string(Base.JLOptions().image_file) == {quote(image_file)}
@assert ENV["JULIA_PROJECT"] == {quote(project)}
TOML.print(Dict("project"=>Base.active_project(), "version"=>string(VERSION),
 "image"=>unsafe_string(Base.JLOptions().image_file), "inherited_project"=>ENV["JULIA_PROJECT"]))
'''
parent_code = f'''using TOML
@assert ENV["JULIA_PROJECT"] == {quote(project)}
@assert unsafe_string(Base.JLOptions().image_file) == {quote(image_file)}
child = Base.julia_cmd()
@assert !any(arg -> startswith(arg,"--project"), child.exec)
@assert any(arg -> startswith(arg,"-J") || startswith(arg,"--sysimage"), child.exec)
child_code = {quote(child_code)}
result = TOML.parse(read(`$child --startup-file=no -e $child_code`, String))
@assert result["project"] == {quote(project / "Project.toml")}
@assert result["version"] == {quote(version)}
@assert result["image"] == {quote(image_file)}
result["child_arguments_without_explicit_project"] = child.exec
TOML.print(result)
'''
command = [str(Path(args.wrapper).absolute()), "--startup-file=no", f"--project={project}", "-e", parent_code]
completed = subprocess.run(command, capture_output=True, text=True, check=True)
(out / "parent.stdout").write_text(completed.stdout)
(out / "parent.stderr").write_text(completed.stderr)
result = tomllib.loads(completed.stdout)
assert result["project"] == str(project / "Project.toml")
assert result["version"] == version and result["image"] == image_file

# Explicit child intent takes precedence without changing JULIA_PROJECT itself.
explicit = out / "explicit-child-project"
explicit.mkdir()
(explicit / "Project.toml").write_text("[deps]\n")
env = dict(os.environ, JULIA_PROJECT=str(project))
control = f'@assert Base.active_project()=={quote(explicit / "Project.toml")}; @assert ENV["JULIA_PROJECT"]=={quote(project)}; @assert string(VERSION)=={quote(version)}'
subprocess.run([binary, "--startup-file=no", f"--project={explicit}", "-e", control], env=env, check=True)
result["explicit_child_project_precedence"] = True
result["kind"] = "child project contract control; not native acceptance or benchmark"
(out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print("PASS inherited -J / no --project child: exact project, runtime and image; explicit child override PASS")
print("Receipts: " + str(out / "result.json"))
