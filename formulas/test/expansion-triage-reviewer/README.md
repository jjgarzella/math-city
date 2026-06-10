# expansion-triage-reviewer test suite

Deterministic tests for **`formulas/expansion-triage-reviewer.toml`** — the
canonical, provider-INDEPENDENT Tier-1 triage reviewer fragment. Built for
**gcs-f4j.10.1**.

This fragment is the bead-native sibling of the legacy single-session
`mol-triage-review`: it runs triage's five real-bugs angles (rule-adherence /
bug-scan / git-history / prior-prs / in-code-invariants) as
**separately-dispatched lanes**, each its own session with its own per-lane
`opt_model`, preceded by an analyze pass and followed by a synthesis pass that
applies triage's high-precision confidence gate. It reuses the standard reviewer's
machinery (gcs-f4j.8.*) — the shared `lib/resolve-diff.sh`, `lib/review-lane.sh`,
and `lib/review-synthesis.sh` — narrowed to triage's lens set.

## Running

```bash
./run.sh          # all tests
./run.sh 01       # just integrity
./run.sh 02 03    # just the analyze + lane transport
```

`python3`, `git`, `jq`, and `bash` are required. The verbatim-against-source
checks (test_04) need the Anthropic code-review command at `$ANTHROPIC_SRC`; they
**skip (not fail)** when it is absent. The compile check (test_05) needs the `gc`
binary; it **skips (not fails)** when `gc` is absent.

## What's covered

- **`test_01_integrity.sh`** — pure structural assertions over the TOML: it is an
  `expansion` of `graph.v2`; the templates are analyze → the five real-bugs lenses
  → synthesis; the lens set **excludes** the standard reviewer's six breadth
  lenses (triage's differentiator); each lens is separately dispatched
  (`gc.run_target=gasvillage.polecat`) with its OWN per-lane `opt_model` var; the
  DAG wires every lens to analyze and synthesis to all five; the ten vars + their
  cheap-first model tiering + the confidence `threshold=80` default are locked; and
  no var defaults to the deep (opus) tier (triage is the cheap, always-on tier).
- **`test_02_analyze.sh`** — runs the analyze bash end-to-end against a stub bd/gc
  + the REAL shared resolver: diff resolution + DURABLE inputs, the
  **path-target REJECTION** (triage reviews CHANGES, unlike the standard reviewer's
  whole-repo audit), and project rule-file discovery into `rule-files` + `rules.md`.
- **`test_03_lanes.sh`** — runs each lens' STEP-1 block against the shared
  `review-lane.sh`: the eligibility gate (eligible loads / ineligible self-skips),
  the repo-dependent angles' graceful self-skip (git-history with no git, prior-prs
  with no PR context), and structurally pins each lens' own `category:` label + the
  verbatim Anthropic false-positive list carried by every (self-contained) lane.
- **`test_04_synthesis.sh`** — pins triage's precision gate on the shared
  `review-synthesis.sh`: the verbatim Anthropic 0-100 rubric, the `{threshold}`
  burn gate, the verdict vocabulary, a runnable ineligible→clean-pass check, and
  the verbatim-against-source checks of the rubric + false-positive list.
- **`test_05_compile.sh`** — expands the fragment through the live `gc` binary
  (`gc formula show`): the seven passes materialize, the clean `workflow-finalize`
  terminal is appended, no leftover braces remain, and each lane's `opt_model`
  substitutes to its tiered model.

## What's NOT covered here (by design)

- **The shared, reviewer-agnostic libs** (`resolve-diff.sh`, `review-lane.sh`,
  `review-synthesis.sh`) this fragment reuses are tested directly by
  `formulas/test/expansion-standard-reviewer/`. This suite does not re-test them —
  it pins the triage-specific contract layered on top.
- **The live, model-dependent outcome** — what findings the five LLM lenses
  actually surface on a real diff, and the live per-lane `opt_model` → `--model`
  fold (gated on the gc rebuild, parent gcs-f4j.10) — is the dogfood's job. See the
  host suite's `DOGFOOD.md`.
