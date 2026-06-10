# mol-triage-review-independent test suite

Deterministic tests for **`formulas/mol-triage-review-independent.toml`** — the
standalone, directly-slingable host for the canonical provider-independent triage
reviewer fragment (`expansion-triage-reviewer`, gcs-f4j.10.1).

`mol-triage-review-independent` is a *thin* graph.v2 host: one placeholder step
plus a `[[compose.expand]]` that materializes the fragment (analyze → five
real-bugs lenses → synthesis) into it, with **zero prompt duplication** — every
reviewer prompt lives in the one fragment. The host's entire contract is its
declared `[vars]` and the compose.expand mapping that propagates them into the
fragment (renaming the host's `target` onto the fragment's `review_target`, every
other var 1:1). These tests lock exactly that contract.

## Running

```bash
./run.sh          # all tests
./run.sh 01       # just integrity
./run.sh 02       # just the compile/expand lifecycle
```

`python3` is required. The lifecycle test needs the `gc` binary; it is **skipped
(not failed)** when `gc` is absent, so the integrity half stays CI-portable.

## What's covered

- **`test_01_integrity.sh`** — pure structural assertions over the TOML: top-level
  shape (`formula = mol-triage-review-independent`, `contract = graph.v2`, one
  placeholder `review-pipeline` step with `gc.run_target=gasvillage.polecat`);
  exactly one `[[compose.expand]]` targeting it `with = expansion-triage-reviewer`;
  a **no-drift** cross-check that the expand var keys reproduce the fragment's
  *entire* var contract (read live from the fragment) with `review_target` renamed
  to `target`; every override is a single-brace ref to a defined host var; the
  `review_target ← {target}` rename seam; no dead var; and every host default
  mirrors the fragment's.
- **`test_02_lifecycle.sh`** — compile/expand through the live `gc` binary: the
  `{target}` placeholder substitutes to `review-pipeline`, the seven fragment
  passes materialize, the DAG survives (lenses need analyze, synthesis needs all
  five, finalize needs synthesis), and var propagation works both default (resolver
  sees `"" "main"`, each lane's `opt_model` + `run_target` propagate tiered) and
  overridden (`--var target/base_branch` reach the resolver, `--var threshold`
  reaches the synthesis gate, `--var bug_scan_model` retargets the bug-scan lens).

## What's NOT covered here (by design)

- **The fragment's execution transport** (analyze durable inputs + path rejection +
  rule discovery, the five lanes' eligibility/self-skip/finding plumbing, the
  synthesis confidence gate) is owned and tested by
  `formulas/test/expansion-triage-reviewer/`. This suite pins the *host wiring*
  around it.
- **The live, model-dependent outcome** is the dogfood's job. See `DOGFOOD.md`.
