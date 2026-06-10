#!/usr/bin/env python3
"""Inspection helper for the mol-standard-review host formula TOML.

mol-standard-review is a THIN graph.v2 host: one placeholder [[steps]] entry +
a [[compose.expand]] that materializes the canonical expansion-standard-reviewer
fragment into it. Unlike a single-session workflow (mol-triage-review) there is
no embedded review prompt here — the host's whole contract is (a) its declared
[vars] and (b) the compose.expand mapping that propagates them into the fragment.
This helper gives the bash suite deterministic access to exactly that surface,
read from the raw TOML (the structure `gc sling` compiles).

Usage: _formula.py <host.toml> <command> [args...]

Commands:
  formula-name              top-level `formula = "..."` value
  contract                  top-level `contract = "..."` value
  step-count                number of [[steps]]
  step-ids                  [[steps]] ids, one per line
  step-meta <id> <key>      metadata[<key>] of step <id>
  defined-vars              sorted [vars.*] names, one per line
  var-default <name>        the `default` of [vars.<name>]
  expand-count              number of [[compose.expand]] rules
  expand-target [i]         `target` of expand rule i (default 0)
  expand-with [i]           `with` of expand rule i (default 0)
  expand-var-keys [i]       sorted keys of expand rule i's `vars`, one per line
  expand-var <key> [i]      value of vars[<key>] in expand rule i
  double-braces-in-vars     count of `{{...}}` across all expand rules' vars
                            values (a drift guard — override vars are single-brace)
"""
import pathlib
import re
import sys
import tomllib

DOUBLE_REF_RE = re.compile(r"\{\{\s*\w+\s*\}\}")


def expand_rules(data):
    return (data.get("compose", {}) or {}).get("expand", []) or []


def rule(data, i):
    rules = expand_rules(data)
    if i >= len(rules):
        sys.stderr.write(f"no compose.expand rule at index {i}\n")
        raise SystemExit(1)
    return rules[i]


def find_step(data, sid):
    for s in data.get("steps", []):
        if s.get("id") == sid:
            return s
    return None


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    toml_path = pathlib.Path(sys.argv[1])
    cmd = sys.argv[2]
    data = tomllib.loads(toml_path.read_text())

    if cmd == "formula-name":
        print(data["formula"]); return 0
    if cmd == "contract":
        print(data.get("contract", "")); return 0
    if cmd == "step-count":
        print(len(data.get("steps", []))); return 0
    if cmd == "step-ids":
        for s in data.get("steps", []):
            print(s.get("id", ""))
        return 0
    if cmd == "step-meta":
        s = find_step(data, sys.argv[3])
        if s is None:
            sys.stderr.write(f"no step {sys.argv[3]!r}\n"); return 1
        print((s.get("metadata", {}) or {}).get(sys.argv[4], "")); return 0
    if cmd == "defined-vars":
        for name in sorted(data.get("vars", {})):
            print(name)
        return 0
    if cmd == "var-default":
        print(data["vars"][sys.argv[3]]["default"]); return 0
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
