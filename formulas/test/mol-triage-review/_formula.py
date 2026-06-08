#!/usr/bin/env python3
"""Inspection helper for the mol-triage-review formula TOML.

Gives the bash test harness deterministic access to the formula's structure
(vars, template refs, step description) and to the verbatim bash blocks embedded
in the single review step. Structure is read via tomllib; template refs are
scanned from the raw text because that is exactly the surface `gc sling`
renders.

Usage: _formula.py <formula.toml> <command> [arg]

Commands:
  formula-name        top-level `formula = "..."` value
  step-count          number of [[steps]]
  defined-vars        sorted [vars.*] names, one per line
  template-refs       sorted unique {{name}} refs in the raw file, one per line
  var-default <name>  the `default` of [vars.<name>]
  step-desc           steps[0].description (the whole review prompt)
  block <signature>   first ```bash fenced block (in steps[0].description) whose
                      body contains <signature>; exits 1 if none match
  blocks              every ```bash block body in steps[0].description, each
                      followed by a line `@@@BLOCK@@@` sentinel
"""
import pathlib
import re
import sys
import tomllib

REF_RE = re.compile(r"\{\{\s*([A-Za-z0-9_]+)\s*\}\}")
BASH_BLOCK_RE = re.compile(r"```bash\n(.*?)```", re.S)


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    toml_path = pathlib.Path(sys.argv[1])
    cmd = sys.argv[2]
    raw = toml_path.read_text()
    data = tomllib.loads(raw)

    if cmd == "formula-name":
        print(data["formula"])
        return 0
    if cmd == "step-count":
        print(len(data.get("steps", [])))
        return 0
    if cmd == "defined-vars":
        for name in sorted(data.get("vars", {})):
            print(name)
        return 0
    if cmd == "template-refs":
        for name in sorted(set(REF_RE.findall(raw))):
            print(name)
        return 0
    if cmd == "var-default":
        print(data["vars"][sys.argv[3]]["default"])
        return 0
    if cmd == "step-desc":
        sys.stdout.write(data["steps"][0]["description"])
        return 0
    if cmd == "block":
        signature = sys.argv[3]
        desc = data["steps"][0]["description"]
        for body in BASH_BLOCK_RE.findall(desc):
            if signature in body:
                sys.stdout.write(body)
                return 0
        sys.stderr.write(f"no bash block contains {signature!r}\n")
        return 1
    if cmd == "blocks":
        desc = data["steps"][0]["description"]
        for body in BASH_BLOCK_RE.findall(desc):
            sys.stdout.write(body)
            if not body.endswith("\n"):
                sys.stdout.write("\n")   # ensure the sentinel starts its own line
            sys.stdout.write("@@@BLOCK@@@\n")
        return 0

    sys.stderr.write(f"unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
