# mol-polecat-implement test suite

Deterministic contract tests for `formulas/mol-polecat-implement.toml` — the
native graph.v2 polecat **IMPLEMENT lifecycle** (gascity gcs-f4j.6 / gcs-6r2).

## Run

```bash
./run.sh          # all tests
./run.sh 01       # only test_01_*
```

Needs `python3` + `bash`. The compile test (test_02) additionally needs `gc` on
PATH; it is skipped (not failed) when `gc` is absent.

## What it locks down

- **test_01_integrity** — pure-TOML structure: the six-step single-session
  lifecycle (load-context → workspace-setup → preflight-tests → implement →
  self-review → trigger-review), every step continuation-pinned to one polecat
  (`gc.continuation_group=main`, `gc.session_affinity=require`, no
  `gc.run_target`), the vars + defaults (`review_formula=mol-review-loop`), the
  idempotent feature-branch resume, the post-setup `cd "$WORK_DIR"` re-entry, and
  the **NON-MERGING terminal**: push + sling `{{review_formula}}` (reviewer-agnostic)
  + drain, leaving the work bead open for the human gate (never merges, never
  `bd close`, no refinery).
- **test_02_compile** — `gc formula show` compiles the formula to the expected
  prefixed step beads + the auto-appended `workflow-finalize` terminal.

## The seam

workspace-setup records `branch` + `work_dir` on the work bead (the molecule
ROOT). `mol-review-loop`'s workspace-setup and apply-fixes read that `work_dir`
to resume the branch under review — so "idempotent resume" here IS the fix-mode
interface the review loop references. See `formulas/test/mol-review-loop/`.
