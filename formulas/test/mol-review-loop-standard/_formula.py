#!/usr/bin/env python3
"""Inspection helper for the mol-review-loop-standard formula TOML.

mol-review-loop-standard is BOTH a multi-step graph.v2 ralph loop (like
mol-review-loop: [[steps]], nested [[steps.children]], a [steps.check] ralph
spec) AND a thin host that `[[compose.expand]]`s the canonical reviewer fragment
into its review-pipeline slot (like mol-standard-review). So this helper merges
the two sibling helpers' command surfaces: the loop-structure commands navigate
the step tree, and the compose.expand commands read the var mapping. Structure
is read via tomllib; template refs are scanned from the raw text because that is
the surface `gc sling` renders.

Usage: _formula.py <formula.toml> <command> [args...]

Loop-structure commands (mol-review-loop parity):
  formula-name                 top-level `formula = "..."` value
  contract                     top-level `contract = "..."` value
  defined-vars                 sorted [vars.*] names, one per line
  template-refs                sorted unique {{name}} refs in the raw file
  var-default <name>           the `default` of [vars.<name>]
  step-ids                     top-level [[steps]] ids, one per line
  child-ids <step-id>          [[steps.children]] ids of <step-id>, one per line
  desc <step-id>               description of <step-id> (top-level or child)
  meta <step-id> <key>         metadata[<key>] of <step-id> (top-level or child)
  ralph-max <step-id>          [steps.check].max_attempts of <step-id>
  ralph-check <step-id> <key>  [steps.check.check].<key> (mode|path|timeout)
  has-compose                  print "yes"/"no" — whether a [compose] table exists
  block <step-id> <signature>  first ```bash block in <step-id>'s description
                               whose body contains <signature>; exits 1 if none

Compose.expand commands (mol-standard-review parity):
  expand-count                 number of [[compose.expand]] rules
  expand-target [i]            `target` of expand rule i (default 0)
  expand-with [i]              `with` of expand rule i (default 0)
  expand-var-keys [i]          sorted keys of expand rule i's `vars`, one per line
  expand-var <key> [i]         value of vars[<key>] in expand rule i
  double-braces-in-vars        count of `{{...}}` across all expand rules' vars
                               values (a drift guard — override vars are single-brace)
"""
import pathlib
import re
import sys
import tomllib

REF_RE = re.compile(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}")
BASH_BLOCK_RE = re.compile(r"```bash\n(.*?)```", re.S)
DOUBLE_REF_RE = re.compile(r"\{\{\s*\w+\s*\}\}")


def all_steps(data):
    """Yield every step dict, recursing into children."""
    def walk(steps):
        for s in steps:
            yield s
            yield from walk(s.get("children", []))
    yield from walk(data.get("steps", []))


def find_step(data, step_id):
    for s in all_steps(data):
        if s.get("id") == step_id:
            return s
    return None


def expand_rules(data):
    return (data.get("compose", {}) or {}).get("expand", []) or []


def rule(data, i):
    rules = expand_rules(data)
    if i >= len(rules):
        sys.stderr.write(f"no compose.expand rule at index {i}\n")
        raise SystemExit(1)
    return rules[i]


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    toml_path = pathlib.Path(sys.argv[1])
    cmd = sys.argv[2]
    raw = toml_path.read_text()
    data = tomllib.loads(raw)

    if cmd == "formula-name":
        print(data["formula"]); return 0
    if cmd == "contract":
        print(data.get("contract", "")); return 0
    if cmd == "defined-vars":
        for name in sorted(data.get("vars", {})):
            print(name)
        return 0
    if cmd == "template-refs":
        for name in sorted(set(REF_RE.findall(raw))):
            print(name)
        return 0
    if cmd == "var-default":
        print(data["vars"][sys.argv[3]]["default"]); return 0
    if cmd == "step-ids":
        for s in data.get("steps", []):
            print(s.get("id", ""))
        return 0
    if cmd == "child-ids":
        parent = find_step(data, sys.argv[3])
        if parent is None:
            sys.stderr.write(f"no step {sys.argv[3]!r}\n"); return 1
        for c in parent.get("children", []):
            print(c.get("id", ""))
        return 0
    if cmd == "desc":
        step = find_step(data, sys.argv[3])
        if step is None:
            sys.stderr.write(f"no step {sys.argv[3]!r}\n"); return 1
        sys.stdout.write(step.get("description", "")); return 0
    if cmd == "meta":
        step = find_step(data, sys.argv[3])
        if step is None:
            sys.stderr.write(f"no step {sys.argv[3]!r}\n"); return 1
        print((step.get("metadata", {}) or {}).get(sys.argv[4], "")); return 0
    if cmd == "ralph-max":
        step = find_step(data, sys.argv[3])
        if step is None or "check" not in step:
            sys.stderr.write(f"no [steps.check] on {sys.argv[3]!r}\n"); return 1
        print(step["check"].get("max_attempts", "")); return 0
    if cmd == "ralph-check":
        step = find_step(data, sys.argv[3])
        if step is None or "check" not in step or "check" not in step["check"]:
            sys.stderr.write(f"no [steps.check.check] on {sys.argv[3]!r}\n"); return 1
        print(step["check"]["check"].get(sys.argv[4], "")); return 0
    if cmd == "has-compose":
        print("yes" if "compose" in data else "no"); return 0
    if cmd == "block":
        step = find_step(data, sys.argv[3])
        if step is None:
            sys.stderr.write(f"no step {sys.argv[3]!r}\n"); return 1
        signature = sys.argv[4]
        for body in BASH_BLOCK_RE.findall(step.get("description", "")):
            if signature in body:
                sys.stdout.write(body); return 0
        sys.stderr.write(f"no bash block in {sys.argv[3]!r} contains {signature!r}\n")
        return 1
    if cmd == "expand-count":
        print(len(expand_rules(data))); return 0
    if cmd == "expand-target":
        i = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        print(rule(data, i).get("target", "")); return 0
    if cmd == "expand-with":
        i = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        print(rule(data, i).get("with", "")); return 0
    if cmd == "expand-var-keys":
        i = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        for k in sorted((rule(data, i).get("vars", {}) or {})):
            print(k)
        return 0
    if cmd == "expand-var":
        key = sys.argv[3]
        i = int(sys.argv[4]) if len(sys.argv) > 4 else 0
        print((rule(data, i).get("vars", {}) or {}).get(key, "")); return 0
    if cmd == "double-braces-in-vars":
        n = 0
        for r in expand_rules(data):
            for v in (r.get("vars", {}) or {}).values():
                n += len(DOUBLE_REF_RE.findall(v))
        print(n); return 0

    sys.stderr.write(f"unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
