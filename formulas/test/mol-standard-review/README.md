# mol-standard-review test suite

Deterministic tests for **`formulas/mol-standard-review.toml`** — the standalone,
directly-slingable host for the canonical standard (8-pass) reviewer fragment
(`expansion-standard-reviewer`, gcs-f4j.8). Built for **gcs-f4j.8.4**.

`mol-standard-review` is a *thin* graph.v2 host: one placeholder step plus a
`[[compose.expand]]` that materializes the fragment (analyze → six review lenses
→ synthesis) into it, with **zero prompt duplication** — every reviewer prompt
lives in the one fragment. The host's entire contract is therefore its declared
`[vars]` and the compose.expand mapping that propagates them into the fragment
(renaming the host's `target` onto the fragment's `review_target`, every other
var 1:1). These tests lock exactly that contract.

## Running

```bash
./run.sh          # all tests
./run.sh 01       # just integrity
./run.sh 02       # just the compile/expand lifecycle
```

`python3` is required. The lifecycle test needs the `gc` binary; it is **skipped
(not failed)** when `gc` is absent, so the integrity half stays CI-portable.

## What's covered

**`test_01_integrity.sh`** — pure structural assertions over the TOML (no `gc`):
- top-level shape: `formula = mol-standard-review`, `contract = graph.v2`, exactly
  one placeholder step (`review-pipeline`) carrying `gc.run_target=gasvillage.polecat`;
- exactly one `[[compose.expand]]`, targeting the placeholder `with =
  expansion-standard-reviewer`;
- **no-drift**: the compose.expand var keys reproduce the fragment's *entire* var
  contract (read live from `expansion-standard-reviewer.toml`) — if the fragment
  gains or renames a var, this fails until the host propagates it;
- the host re-declares that contract with `review_target` renamed to `target`;
- every override value is a single-brace ref to a *defined* host var (never
  `{{double}}`, which would be a render-time/compile-time confusion), the
  `review_target ← {target}` rename seam is pinned, and no host var is dead;
- every host var default mirrors the fragment's default (an un-tuned sling
  behaves exactly like the fragment's documented model tiering).

**`test_02_lifecycle.sh`** — compile/expand through the live `gc` binary
(`gc formula show mol-standard-review`), the materialization `gc sling` performs:
- the `{target}` placeholder substitutes to the host's step id, and the eight
  fragment passes materialize under `mol-standard-review.review-pipeline.*`;
- the DAG survives: each lens needs `analyze`, `synthesis` needs all six lenses,
  the clean `workflow-finalize` terminal needs `synthesis`;
- **var propagation, default**: no leftover `{{double}}` braces, no unsubstituted
  single-brace fragment vars, the default `target`/`base_branch` reach the shared
  resolver (`"" "main"`), and each lens's `opt_model` + `run_target` propagate
  (tiered, no literal brace);
- **var propagation, overridden**: `--var target=#123 --var base_branch=develop`
  reach the resolver (`"#123" "develop"`) and `--var security_model=sonnet`
  retargets the security lens — proving the host's whole point: tune the reviewer
  from one `--var` surface.

## What's NOT covered here (by design)

- **The fragment's execution transport** (analyze durable inputs, the six lanes'
  eligibility/finding plumbing, synthesis dedup-merge + severity promotion) is
  owned and tested by `formulas/test/expansion-standard-reviewer/` (225
  assertions). This suite does not re-test it; it pins the *host wiring* around it.
- **The live, model-dependent outcome** — what findings the six LLM lenses
  actually surface on a real diff — is the dogfood's job. See `DOGFOOD.md`.
