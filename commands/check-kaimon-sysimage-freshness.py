"""Actual Julia/Pkg freshness probes; no image or production session required."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location("image", Path(__file__).with_name("kaimon-sysimage.py"))
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--julia", required=True)
parser.add_argument("--scratch-root", required=True)
args = parser.parse_args()
scratch_root = Path(args.scratch_root).resolve()
scratch_root.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="freshness-", dir=scratch_root) as directory:
    owner = Path(directory)
    target = owner / "target"
    dependency = owner / "dependency"
    for path in (target, dependency):
        (path / "src").mkdir(parents=True)
    (dependency / "Project.toml").write_text(
        'name = "LocalDependency"\nuuid = "a3033311-2222-4333-8444-555555555555"\nversion = "0.1.0"\n')
    source = dependency / "src/LocalDependency.jl"
    source.write_text("module LocalDependency\nvalue() = 41\nend\n")
    (target / "Project.toml").write_text(
        'name = "FreshnessTarget"\nuuid = "b3033311-2222-4333-8444-555555555555"\nversion = "0.1.0"\n'
        '[deps]\nLocalDependency = "a3033311-2222-4333-8444-555555555555"\n'
        '[sources.LocalDependency]\npath = ' + json.dumps(str(dependency)) + '\n')
    (target / "src/FreshnessTarget.jl").write_text("module FreshnessTarget\nusing LocalDependency\nend\n")
    subprocess.run([args.julia, "--startup-file=no", f"--project={target}", "-e", "import Pkg; Pkg.resolve()"], check=True)
    legacy = (target / "Manifest.toml").read_bytes()
    mapping = owner / "paths.toml"
    mapping.write_text('LocalDependency = ' + json.dumps(str(dependency)) + '\n')
    subprocess.run([str(Path(__file__).with_name("kaimon-sysimage.py")), "prepare",
                    "--project", str(target), "--owned-root", str(owner), "--julia", args.julia,
                    "--union-manifest", str(target / "Manifest.toml"), "--path-map", str(mapping)], check=True)
    info = image.runtime(args.julia)
    manifest = image.manifest_path(target, info["version"])
    original_manifest = manifest.read_bytes()
    project = target / "Project.toml"
    original_project = project.read_bytes()
    image.check_project_compat(args.julia, target, info)
    assert manifest.read_bytes() == original_manifest
    assert (target / "Manifest.toml").read_bytes() == legacy
    print("FRESH_MANIFEST_UNCHANGED_PASS", flush=True)

    project.write_text(project.read_text().replace('[deps]', '[deps]\nRandom = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"'))
    try:
        image.check_project_compat(args.julia, target, info)
        raise AssertionError("stale root Project was accepted")
    except image.Rejected as error:
        assert "stale" in str(error), str(error)
    finally:
        project.write_bytes(original_project)
    print("STALE_ROOT_PROJECT_REJECTED_PASS", flush=True)

    dependency_project = dependency / "Project.toml"
    original_dependency = dependency_project.read_bytes()
    dependency_project.write_text(dependency_project.read_text() + '\n[compat]\njulia = "1.13"\n')
    try:
        image.check_project_compat(args.julia, target, info)
        raise AssertionError("stale path-source Project was accepted")
    except image.Rejected as error:
        assert "stale" in str(error), str(error)
    finally:
        dependency_project.write_bytes(original_dependency)
    print("STALE_PATH_PROJECT_REJECTED_PASS", flush=True)

    source.write_text("module LocalDependency\nvalue() = 42\nend\n")
    image.check_project_compat(args.julia, target, info)
    assert manifest.read_bytes() == original_manifest
    print("SOURCE_CODE_EDIT_ALLOWED_PASS", flush=True)
