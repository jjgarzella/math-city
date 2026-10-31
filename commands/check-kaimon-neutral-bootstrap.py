"""Actual ordinary-Julia guard controls; no image, gate, daemon or shared edits.

Fault injection edits only this test's generated Julia program and owned files.
It does not redefine Base/Pkg or alter installed package sources.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import shutil
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-project", required=True, help="prepared owned DeRham project; read only")
parser.add_argument("--artifact", required=True)
parser.add_argument("--julia", required=True)
parser.add_argument("--bootstrap-project", action="append", default=[])
parser.add_argument("--owned-root", required=True, help="parent for a new isolated test directory")
parser.add_argument("--selector", default=str(Path(__file__).with_name("kaimon-sysimage.py")))
args = parser.parse_args()
SOURCE = Path(args.source_project).resolve()
owner = Path(args.owned_root).resolve()
assert owner != Path("/") and owner != SOURCE
owner.mkdir(parents=True, exist_ok=True)
OUT = Path(tempfile.mkdtemp(prefix="neutral-guards-", dir=owner))
TARGET = OUT / "DeRham.jl"
ARTIFACT = Path(args.artifact).resolve()
META = json.loads((ARTIFACT / "metadata.json").read_text())
JULIA = str(Path(args.julia).resolve())
spec = importlib.util.spec_from_file_location("guard", args.selector)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
manifest = guard.manifest_path(SOURCE, META["spec"]["runtime"]["version"]).name
TARGET.mkdir(exist_ok=True)
for name in ("Project.toml", manifest):
    shutil.copy2(SOURCE / name, TARGET / name)
shutil.copytree(SOURCE / "src", TARGET / "src", dirs_exist_ok=True)
INFO = guard.runtime(JULIA, TARGET)
assert guard.runtime_identity(INFO) == META["spec"]["runtime"]
assert "Oscar" in guard.read_toml(TARGET / "Project.toml")["deps"]
original_run = guard.run_julia
results = []
tracked = [TARGET / "Project.toml", TARGET / manifest]
baseline = {p: p.read_bytes() for p in tracked}
prefs = TARGET / "LocalPreferences.toml"
marker = OUT / "instantiate-completed"


def quote(value):
    return json.dumps(str(value), ensure_ascii=False).replace("$", "\\$")


def run_case(name, injection="", before_prefs=None, expected=None):
    for path, data in baseline.items():
        path.write_bytes(data)
    prefs.unlink(missing_ok=True)
    marker.unlink(missing_ok=True)
    if before_prefs is not None:
        prefs.write_text(before_prefs)
    calls = []
    def injected(binary, code, *args, **kwargs):
        assert binary == JULIA and kwargs == {"project": TARGET, "preserve_load_path": True}
        calls.append(code)
        operation = "Pkg.instantiate(; io=devnull, allow_autoprecomp=false)\n"
        assert code.count(operation) == 1
        code = code.replace(operation, operation + injection + "\n", 1)
        return original_run(binary, code, *args, **kwargs)
    guard.run_julia = injected
    started = time.monotonic()
    try:
        audit = guard.check_project_compat(JULIA, TARGET, INFO, META,
                                          [Path(p).resolve() for p in args.bootstrap_project], instantiate=True)
        assert expected is None, (name, "expected rejection")
        assert all(context["empty"] for context in audit["contexts"])
        result = "PASS"
    except guard.Rejected as error:
        assert expected is not None and expected in str(error), (name, str(error))
        result = "PASS rejection: " + expected
    finally:
        guard.run_julia = original_run
        for path, data in baseline.items():
            path.write_bytes(data)
        prefs.unlink(missing_ok=True)
    assert len(calls) == 1
    if name == "preference veto before instantiate":
        assert not marker.exists(), "Pkg operation ran after the first audit veto"
    receipt = {"case": name, "result": result, "seconds": time.monotonic() - started,
               "ordinary_processes": len(calls)}
    results.append(receipt)
    (OUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)


run_case("success")
run_case("preference veto before instantiate", 'write(' + quote(marker) + ', "ran")',
         before_prefs="[Oscar]\ncity_guard_probe = true\n", expected="non-default preferences")
run_case("Project changed during instantiate", 'open(' + quote(TARGET / "Project.toml") +
         ', "a") do io; write(io, "\\n# mutation\\n"); end', expected="Project/Manifest changed")
run_case("Manifest changed during instantiate", 'open(' + quote(TARGET / manifest) +
         ', "a") do io; write(io, "\\n# mutation\\n"); end', expected="Project/Manifest changed")
run_case("post preference veto", 'write(' + quote(prefs) + ', "[Oscar]\\ncity_guard_probe = true\\n")',
         expected="non-default preferences")
run_case("preference file drift despite empty values", 'write(' + quote(prefs) + ', "# changed\\n")',
         before_prefs="# original\n", expected="preference inputs changed")
assert all(path.read_bytes() == content for path, content in baseline.items())
script = ('ENV["KAIMON_CITY_SYSIMAGE"] = "rejected: IOError: pipe_open: file already exists (EEXIST)"\n'
          f'cd({quote(TARGET)})\nimport Pkg\ntry; using Revise; catch; end\n'
          'using KaimonGate\nPkg.instantiate(; io=devnull)\n'
          '@async KaimonGate.serve(force=true, allow_mirror=true, allow_restart=true, spawned_by="agent")\n')
started = time.monotonic()
rewritten = guard.neutral_managed_bootstrap(JULIA, TARGET, script, INFO, META, ARTIFACT,
                                           [Path(p).resolve() for p in args.bootstrap_project])
assert rewritten.startswith(f'cd({quote(TARGET)})\n')
assert '# Pkg.instantiate completed in neutral prelaunch Julia.' in rewritten
assert all(path.read_bytes() == content for path, content in baseline.items())
results.append({"case": "managed hook literal status with real neutral guards", "result": "PASS",
                "seconds": time.monotonic() - started})
(OUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print("ALL 7 ACTUAL COLD GUARD CONTROLS PASS; no image or native session launched", flush=True)
print("Receipts: " + str(OUT / "results.json"), flush=True)
