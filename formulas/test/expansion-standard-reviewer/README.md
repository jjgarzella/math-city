# expansion-standard-reviewer test suite

Deterministic tests for `formulas/expansion-standard-reviewer.toml` — the
canonical standard (8-pass) code-review reviewer fragment (gcs-f4j.8). The
fragment is built incrementally; this suite grows with it.

```sh
./run.sh           # every test_*.sh
./run.sh 01 03     # only the matching files
```

Requires `python3`, `git`, `jq`, `bash`. `gc` is optional — the compile test
(test_04) is skipped, not failed, when it is absent.

## What it covers (gcs-f4j.8.1 — the analyze pass)

- **test_01_integrity** — structure from the TOML directly: it is a
  `type=expansion`, `contract=graph.v2` fragment; the exact five-var contract
  (`review_target`, `base_branch`, `review_model`, `aux_model`,
  `severity_threshold`) with documented defaults; single-brace var syntax with
  **zero** `{{double-brace}}` drift (the bug that renders `{{x}}` as a literal
  `{value}`); the single `{target}.analyze` template; its `gasvillage.polecat`
  run_target; and that no var is literally named `target` (reserved for the
  expansion placeholder).
- **test_02_resolver** — the shared `lib/resolve-diff.sh` contract the analyze
  step delegates to, exercised directly against throwaway git repos (the
  range/branch/pr/empty/path classifications the analyze branches key on), plus
  the no-drift wiring: the analyze prompt calls the shared resolver via
  `$GC_CITY`, passes both vars, does not inline the git logic, and branches on
  the resolver's exit codes (2/3) and empty stdout.
- **test_03_analyze_lifecycle** — the analyze bash run end-to-end against a
  recording stub `bd`/`gc` (`bin/`) and the REAL resolver: a real range diff
  produces durable `diff`/`files`/`summary.md` under
  `$GC_CITY/.gc/review-inputs/<root>` and records `gc.review.inputs_dir`,
  `gc.review.target_kind`, `work_dir`, `gc.review.eligible`, and
  `gc.review.eligibility_reason` on the molecule root; the empty-diff and
  whole-repo-audit (`path`) branches set the right `target_kind`.
- **test_04_compile** — `gc formula show` materializes the expansion (synthetic
  target `main`), proving the fragment EXPANDS and that var substitution leaves
  no `{{double}}` or unsubstituted single-brace vars.

## What it does NOT cover

The model-dependent outcomes — the actual change-summary text and the
eligibility judgment for a non-trivial diff — are not asserted here; only the
deterministic transport that frames them is. Those are a dogfood concern
(gcs-f4j.8.4 proves the standalone reviewer on a real diff).

## Stubs (`bin/`)

- `bd` — recording stub: returns canned bead JSON (root id, work_dir from
  `BD_ROOT`/`BD_WORKDIR`) and appends every `--set-metadata key=value` to
  `BD_META_LOG`. Never touches Dolt.
- `gc` — no-op success (the analyze block only calls `gc bd heartbeat`).
- `gh` — canned `gh pr diff` so the resolver's PR branch is testable offline.
