# mol-review-loop-standard test suite

Deterministic, hermetic tests for the codex-free **standard-reviewer review→fix
loop variant** (`formulas/mol-review-loop-standard.toml`) and its shared
apply-fixes transport (`formulas/lib/review-apply-fixes.sh`). Built for gascity
**gcs-f4j.8.5**.

```bash
./run.sh          # all tests
./run.sh 02       # only test_02_*
```

Exits non-zero if any assertion fails. Needs `python3`, `jq`, `bash`; the
compile/expand check (test_03) additionally needs `gc` and is skipped without it.

This loop variant is the loop counterpart of the standalone host
`mol-standard-review`: the SAME canonical reviewer fragment
(`expansion-standard-reviewer`, gcs-f4j.8) `[[compose.expand]]`d into
`mol-review-loop`'s `review-pipeline` slot, with a REAL `apply-fixes` that maps
the reviewer's synthesis output onto the loop's `review.verdict`. It reuses the
shared verdict-glue check (`review-verdict.sh`) unchanged.

## What is covered

- **test_01_integrity** — structure pinned straight from the TOML: the
  `workspace-setup -> review-loop` shape; the ralph `[steps.check]` cap
  (`max_attempts = 3`), exec mode, `.gc-review-verdict.sh` path/timeout (the
  SHARED check, reused); the `[review-pipeline -> apply-fixes]` body, both pooled
  to `gasvillage.polecat`; the `[[compose.expand]]` of the canonical fragment
  into `review-pipeline` with a NO-DRIFT cross-check (every fragment var
  propagated, `review_target <- {target}` rename seam, single-brace override
  values, defaults mirror the fragment); `severity_threshold` doubling as the
  fragment threshold AND the apply-fixes `FIX_THRESHOLD`; `notify_target` as a
  loop-only knob; `apply-fixes` wiring every `review_apply_fixes_*` entry point;
  and the absence of any `on_complete`/`on_fail`/abort_scope directive.
- **test_02_apply_fixes_lib** — the verdict→severity→fix machinery, run against
  canned bead JSON (`bin/bd`, `bin/gc` stubs — never a real Dolt store): the
  synthesis-verdict → `review.verdict` map (pass→done; pass_with_findings→iterate
  iff fixes applied else done; fail→iterate; blocked→done; unknown→iterate); the
  severity→rank map; `load` resolving the run (verdict + counts + work_dir +
  threshold); `findings` enumerating durable severity-tagged findings ranked
  must-fix-first (closed / label-less excluded); `set_verdict` writing
  `review.verdict` and closing (invalid verdict rejected); and `escalate` —
  blocked → terminate-to-human (`gc.review.loop_outcome=blocked-needs-human` on
  the root, `review.verdict=done`, no nudge from the lib).
- **test_03_compile** — `gc formula show mol-review-loop-standard` compiles and
  EXPANDS: the eight reviewer passes (analyze → six lenses → synthesis)
  materialize inside the ralph iteration body ahead of `apply-fixes`, the DAG
  survives (lenses gate on analyze, synthesis on all six, apply-fixes on
  synthesis), the clean `workflow-finalize` terminal is appended, and the
  compose.expand var-propagation works default + overridden (resolver target /
  base_branch, synthesis threshold, lane opt_models). Skipped when `gc` is
  absent. NOTE: workflow `{{vars}}` (e.g. `{{severity_threshold}}` →
  `FIX_THRESHOLD` in apply-fixes) render at *sling* time, not at `formula show`,
  so they are intentionally not asserted-substituted here.

## What is NOT covered here

The model-dependent halves of a real run: the actual review (the reviewer's
lenses/synthesis are the agents' reasoning, pinned by the
`expansion-standard-reviewer` suite) and the actual fix application (the
`apply-fixes` fix-vs-surface call is the agent's ZFC judgment). A LIVE,
multi-session in-loop sling (review → fix → verdict → terminate) is the
codex-free integration + dogfood **gcs-f4j.8.6** — gated like the standalone
host's gcs-uvnp because the gascity polecat pool is `max=1`, so an across-session
loop needs a steered dispatch rather than self-driving the one slot.

## Files

- `run.sh` / `lib.sh` — runner + shared assertions, the fragment no-drift
  readers, the gc-show helpers, and the stub-backed `afx_run` apply-fixes runner.
- `_formula.py` — tomllib-backed inspector merging the loop-structure surface
  (steps, children, ralph check, metadata, bash blocks) with the compose.expand
  surface (expand target/with/vars).
- `bin/bd`, `bin/gc` — canned/recording stubs: return the minimum bead JSON the
  apply-fixes lib consumes (root verdict + durable findings) and record every
  metadata/status write so the assertions can check what apply-fixes wrote.
