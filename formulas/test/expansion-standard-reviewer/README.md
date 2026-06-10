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

## What it covers (gcs-f4j.8.1 — analyze; gcs-f4j.8.2 — the six lenses)

- **test_01_integrity** — structure from the TOML directly: it is a
  `type=expansion`, `contract=graph.v2` fragment; the full var contract — the 4
  shared vars (`review_target`, `base_branch`, `aux_model`, `severity_threshold`)
  plus the 6 per-lane model vars (`quality_model`, `security_model`,
  `performance_model`, `architecture_model`, `testing_model`, `docs_model`) with
  their tiered defaults (deep `opus` for the judgment lenses, standard `sonnet`,
  cheap `haiku` for the mechanical lenses); single-brace var syntax with **zero**
  `{{double-brace}}` drift (the bug that renders `{{x}}` as a literal `{value}`);
  the seven templates (`{target}.analyze` + the six `{target}.<lens>`); every
  step's `gasvillage.polecat` run_target; each lens depending on
  `{target}.analyze` and carrying its per-lane `opt_model`; that no var is
  literally named `target` (reserved for the expansion placeholder); and that
  every lens prompt sources the shared lane helper, gates on eligibility, scopes
  to the changed surface, files `category:<lens>` wisps with the `Confidence`
  self-rating, and self-skips cleanly with zero findings.
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
  target `main`), proving the fragment EXPANDS into the analyze pass + all six
  lenses + a clean `workflow-finalize` terminal, that var substitution leaves no
  `{{double}}` or unsubstituted single-brace vars, and that each lens's
  `opt_model` metadata substitutes to its tiered model value (not a literal
  brace) — the per-lane model-selection mechanism.
- **test_05_lib_review_lane** — the shared `lib/review-lane.sh` transport, tested
  directly and via a lane's verbatim eligibility-gate block against the stub
  `bd`: `review_lane_load_inputs` resolves the root + reads the analyze pass's
  durable handles; `review_lane_file_finding` creates the `<root>.findings`
  container once and files an ephemeral `category:<lens>` wisp whose first body
  line is the `Confidence: X/100` self-rating; `review_lane_close` closes the
  lane pass; and a lens lane self-skips to a clean pass (no findings) when the
  change is ineligible.

## What it does NOT cover

The model-dependent outcomes — the actual change-summary text, the eligibility
judgment, and each lens's findings on a real diff — are not asserted here; only
the deterministic transport that frames them is. Those are a dogfood concern
(gcs-f4j.8.4 proves the standalone reviewer on a real diff).

## Stubs (`bin/`)

- `bd` — recording stub: returns canned bead JSON (root id + `work_dir`, plus the
  analyze pass's `gc.review.*` handles when the `BD_REVIEW_*` env is set),
  appends every `--set-metadata key=value` to `BD_META_LOG`, and records each
  `bd create` / `bd update` to `BD_CREATE_LOG` / `BD_UPDATE_LOG`. Never touches
  Dolt.
- `gc` — no-op success (the blocks only call `gc bd heartbeat`).
- `gh` — canned `gh pr diff` so the resolver's PR branch is testable offline.
