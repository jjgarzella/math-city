#!/Users/jj-agents/.homebrew/opt/python@3.14/bin/python3.14
"""Fresh-process same-project image comparison, sampled aggregate child RSS.

These are process-cold launches using existing filesystem caches/depots. Nothing
flushes OS caches or substitutes for prescribed clean-depot acceptance gates.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
import time
import tomllib


def descendant_rss(pid):
    output = subprocess.run(["ps", "-axo", "pid=,ppid=,rss="],
                            capture_output=True, text=True, check=True).stdout
    processes = [tuple(map(int, line.split())) for line in output.splitlines()]
    owned = {pid}
    while True:
        children = {p for p, parent, rss in processes if parent in owned}
        if children <= owned:
            break
        owned |= children
    return sum(rss for p, parent, rss in processes if p in owned) * 1024


def measured(command, log, env):
    started = time.monotonic()
    with log.open("w+") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
        peak = 0
        event = threading.Event()
        while process.poll() is None:
            peak = max(peak, descendant_rss(process.pid))
            event.wait(0.1)
        elapsed = time.monotonic() - started
        stream.seek(0)
        output = stream.read()
    result = {"wall_seconds": elapsed, "aggregate_peak_rss_bytes": peak,
              "returncode": process.returncode, "log": str(log), "command": command}
    if process.returncode == 0:
        # Libraries may print banners before the explicit result marker.
        result["julia"] = tomllib.loads(output.split("CITY_BENCHMARK_RESULT\n")[-1])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--julia", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--threads", default="auto", help="same thread setting in both modes; Kaimon default is auto")
    parser.add_argument("--gate-project", required=True,
                        help="installed KaimonGate environment, shared by both modes")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    metadata = json.loads(Path(args.image).with_name("metadata.json").read_text())
    target_project = tomllib.loads((Path(args.project) / "Project.toml").read_text())
    roots = sorted(set(metadata["spec"]["roots"]) & set(target_project.get("deps", {})))
    root_package = target_project.get("name")
    if root_package:
        roots.append(root_package)
    imports = "; ".join("using " + p for p in roots)
    if "Oscar" in roots:
        math = '''R, (x,y,z) = Oscar.polynomial_ring(Oscar.QQ, ["x","y","z"])
f = x^2 + 2*x*y + 3*x*z + 4*y^2 + 5*y*z + 6*z^2
@assert f(1,2,3) == 114
@assert (x+y)^2 == x^2+2*x*y+y^2'''
        if root_package == "DeRham":
            math += '''\nv = DeRham.polynomial_to_vector(f,3)
@assert v == [6,5,4,3,2,1]
@assert DeRham.vector_to_polynomial(v,2,2,R) == f'''
    else:
        math = ("@assert length(collect(Combinatorics.combinations(1:20, 3))) == 1140"
                if "Combinatorics" in roots else "@assert sum(i^2 for i in 1:20) == 2870")
    bootstrap = '''import Pkg
try; using Revise; catch; end
using KaimonGate
Pkg.instantiate(;io=devnull)
'''
    startup = bootstrap + '''using TOML
println("CITY_BENCHMARK_RESULT")
TOML.print(Dict("version"=>string(VERSION), "project"=>Base.active_project(),
               "image"=>unsafe_string(Base.JLOptions().image_file)))'''
    workload = bootstrap + f'''using TOML
load_seconds = @elapsed begin {imports} end
function cpu_workload()
    {math}
end
first_seconds = @elapsed cpu_workload()
repeated_seconds = [@elapsed(cpu_workload()) for _ in 1:5]
sources = Dict(string(id.name)=>something(pathof(mod), "") for (id,mod) in Base.loaded_modules
               if id.name in {json.dumps(roots)})
println("CITY_BENCHMARK_RESULT")
TOML.print(Dict("version"=>string(VERSION), "project"=>Base.active_project(),
 "image"=>unsafe_string(Base.JLOptions().image_file), "load_seconds"=>load_seconds,
 "first_math_seconds"=>first_seconds, "repeated_math_seconds"=>repeated_seconds,
 "sources"=>sources))'''
    results = {"method": "sequential fresh processes; unchanged OS caches and shared depot; 0.1s RSS sampling",
               "artifact_id": metadata["id"], "bootstrap": "Pkg, optional Revise, KaimonGate, Pkg.instantiate (same as managed boot)",
               "gate_project": args.gate_project, "runs": []}
    env = os.environ.copy()
    env["JULIA_LOAD_PATH"] = os.pathsep.join(("@", "@v#.#", "@stdlib", args.gate_project))
    # Alternate modes to reduce the bias from steadily warming disk caches.
    for index in range(args.runs):
        modes = ("normal", "image") if index % 2 == 0 else ("image", "normal")
        for mode in modes:
            for name, code in (("startup", startup), ("cpu", workload)):
                command = [args.julia, "--startup-file=no", "-t", args.threads, f"--project={args.project}"]
                if mode == "image":
                    command.append(f"--sysimage={args.image}")
                command += ["-e", code]
                result = measured(command, output / f"{index}-{mode}-{name}.log", env)
                result.update(mode=mode, workload=name, run=index)
                results["runs"].append(result)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(json.dumps({k: result[k] for k in ("mode", "workload", "run", "wall_seconds",
                                                       "aggregate_peak_rss_bytes", "returncode")}), flush=True)
    results["summary"] = {}
    for mode in ("normal", "image"):
        for workload in ("startup", "cpu"):
            selected = [r for r in results["runs"] if r["mode"] == mode and r["workload"] == workload]
            successful = [r for r in selected if r["returncode"] == 0]
            results["summary"][f"{mode}-{workload}"] = {
                "passed": len(successful), "total": len(selected),
                "median_wall_seconds": statistics.median([r["wall_seconds"] for r in successful]) if successful else None,
                "peak_aggregate_rss_bytes": max(r["aggregate_peak_rss_bytes"] for r in selected),
                "all_under_60_seconds": len(successful) == len(selected) and all(r["wall_seconds"] < 60 for r in selected)}
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
