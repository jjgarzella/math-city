#!/usr/bin/env python3
"""Inspection + render helper for the expansion-standard-reviewer fragment TOML.

Unlike the workflow helpers (mol-review-loop, mol-triage-review), this fragment
is `type = "expansion"`: its steps live under [[template]] and its vars are
substituted with SINGLE braces ({name}) by the expansion engine, while {target}
is the reserved expansion placeholder (the host's target step id). The `render-*`
commands mirror that engine substitution so the embedded bash blocks can be run.

Usage: _formula.py <fragment.toml> <command> [args...]

Commands:
  formula-name              top-level `formula = "..."` value
  contract                  top-level `contract = "..."` value
  ftype                     top-level `type = "..."` value
  defined-vars              sorted [vars.*] names, one per line
  var-default <name>        the `default` of [vars.<name>]
  template-ids              [[template]] ids, one per line
  meta <id> <key>           metadata[<key>] of template <id>
  needs <id>                needs[] of template <id>, one per line
  title <id>                title of template <id>
  desc <id>                 raw (unsubstituted) description of template <id>
  var-refs                  sorted unique single-brace {name} refs across template
                            text that name a DEFINED var, one per line
  double-braces             count of `{{...}}` occurrences in template text (a
                            drift guard — expansion templates must use single brace)
  rendered-desc <id>        description with {target} and the single-brace vars
                            substituted (RENDER_TARGET, RENDER_<VAR>, else defaults)
  block <id> <signature>    first ```bash block in rendered <id> whose body
                            contains <signature>; exits 1 if none
"""
import os
import pathlib
import re
import sys
import tomllib

BASH_BLOCK_RE = re.compile(r"```bash\n(.*?)```", re.S)
SINGLE_REF_RE = re.compile(r"\{(\w+)\}")
DOUBLE_REF_RE = re.compile(r"\{\{\s*\w+\s*\}\}")


def templates(data):
    return data.get("template", [])


def find_template(data, tid):
    for t in templates(data):
        if t.get("id") == tid:
            return t
    return None


def all_template_text(data):
    chunks = []
    for t in templates(data):
        chunks.append(t.get("id", ""))
        chunks.append(t.get("title", ""))
        chunks.append(t.get("description", ""))
    return "\n".join(chunks)


def render(text, data, target):
    """Mirror the engine: substitute {target} first, then single-brace vars."""
    text = text.replace("{target}", target)
    for name, spec in data.get("vars", {}).items():
        envname = "RENDER_" + name.upper()
        val = os.environ.get(envname)
        if val is None:
            val = spec.get("default", "")
        text = text.replace("{" + name + "}", val)
    return text


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    toml_path = pathlib.Path(sys.argv[1])
    cmd = sys.argv[2]
    raw = toml_path.read_text()
    data = tomllib.loads(raw)
    target = os.environ.get("RENDER_TARGET", "main")

    if cmd == "formula-name":
        print(data["formula"]); return 0
    if cmd == "contract":
        print(data.get("contract", "")); return 0
    if cmd == "ftype":
        print(data.get("type", "")); return 0
    if cmd == "defined-vars":
        for name in sorted(data.get("vars", {})):
            print(name)
        return 0
    if cmd == "var-default":
        print(data["vars"][sys.argv[3]]["default"]); return 0
    if cmd == "template-ids":
        for t in templates(data):
            print(t.get("id", ""))
        return 0
    if cmd == "meta":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        print(t.get("metadata", {}).get(sys.argv[4], "")); return 0
    if cmd == "needs":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        for n in t.get("needs", []):
            print(n)
        return 0
    if cmd == "title":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        print(t.get("title", "")); return 0
    if cmd == "desc":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        sys.stdout.write(t.get("description", "")); return 0
    if cmd == "var-refs":
        defined = set(data.get("vars", {}))
        refs = {r for r in SINGLE_REF_RE.findall(all_template_text(data)) if r in defined}
        for r in sorted(refs):
            print(r)
        return 0
    if cmd == "double-braces":
        print(len(DOUBLE_REF_RE.findall(all_template_text(data)))); return 0
    if cmd == "rendered-desc":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        sys.stdout.write(render(t.get("description", ""), data, target)); return 0
    if cmd == "block":
        t = find_template(data, sys.argv[3])
        if t is None:
            sys.stderr.write(f"no template {sys.argv[3]!r}\n"); return 1
        signature = sys.argv[4]
        rendered = render(t.get("description", ""), data, target)
        for body in BASH_BLOCK_RE.findall(rendered):
            if signature in body:
                sys.stdout.write(body); return 0
        sys.stderr.write(f"no bash block in {sys.argv[3]!r} contains {signature!r}\n")
        return 1

    sys.stderr.write(f"unknown command {cmd!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
