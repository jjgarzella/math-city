# mol-review-loop test suite

Deterministic, hermetic tests for the shared reviewer-agnostic review→fix loop
(`formulas/mol-review-loop.toml`) and its verdict-glue check
(`formulas/lib/review-verdict.sh`). Built for gascity **gcs-f4j.3**.

```bash
./run.sh          # all tests
./run.sh 02       # only test_02_*
```

Exits non-zero if any assertion fails. Needs `python3`, `jq`, `bash`; the
compile check (test_03) additionally needs `gc` and is skipped without it.

## What is covered

- **test_01_integrity** — structure pinned straight from the TOML: the
  `workspace-setup -> review-loop` shape; the ralph `[steps.check]` cap
  (`max_attempts = 3`), exec mode, `.gc-review-verdict.sh` path and timeout; the
  `[review-pipeline -> apply-fixes]` body; `apply-fixes` pooled to
  `gasvillage.polecat`; `review-pipeline` as the compose.expand placeholder; the
  absence of any `on_complete`/`on_fail`/abort_scope directive; and a no-drift
  pin that `workspace-setup` installs exactly the file the check reads.
- **test_02_verdict** — the reviewer-agnostic verdict glue, run against canned
  bead JSON (`bin/bd`, `bin/gc` stubs — never a real Dolt store): the exit-code
  contract (0 = converged on done/approved/pass, 1 = iterate on
  iterate/fail/retry/unknown, 2 = undetermined), two-read newest-verdict-wins,
  attempt-scoping, and the optional fire-and-forget notify (converged/capped
  fires, mid-loop does not, no-target disables, a failing nudge is swallowed).
- **test_03_compile** — `gc formula show mol-review-loop` compiles to the
  expected ralph graph (review-pipeline → apply-fixes inside the iteration body,
  the ralph control bead, the clean `workflow-finalize` terminal). Skipped when
  `gc` is not on PATH.

## What is NOT covered here

The model-dependent halves of a real run: the actual review (the quorum reviewer
is composed into `review-pipeline` by gcs-f4j.5) and the actual fix application
(the `apply-fixes` fix-mode interface is owned by gcs-6r2). Those land with the
full-pipeline integration test (gcs-f4j.7). The live ralph dispatch + relative
work_dir check-path mechanism was already proven end-to-end by the smoke
(gcs-f4j.1), whose shape this loop mirrors.

## Files

- `run.sh` / `lib.sh` — runner + shared assertions and the stub-backed
  `run_verdict` helper.
- `_formula.py` — tomllib-backed inspector for the multi-step graph.v2 formula
  (steps, children, the ralph check spec, per-step metadata, bash blocks).
- `bin/bd`, `bin/gc` — canned/recording stubs; return the minimum bead JSON the
  verdict check consumes and record `gc session nudge` calls.
