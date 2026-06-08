# mol-triage-review — test suite (gcs-t0a.5)

Deterministic tests + fixture corpus for the `mol-triage-review` Tier-1 triage
code-review formula (`../../mol-triage-review.toml`). Build epic `gcs-t0a`;
design `gcs-o84`.

## Run

```bash
./run.sh            # all tests
./run.sh 02 04      # only test_02_*, test_04_*
```

Requires `python3`, `git`, `jq`. Exits non-zero on any failed assertion. The
suite touches **no real Dolt store** and **no network** — `bd` and `gh` are
stubbed (`bin/`), and every temp artifact lives under one run-scoped `TMPDIR`
that is removed on exit.

## What is — and is not — deterministic

`mol-triage-review` is ONE claude session whose review intelligence (the five
angles, the per-issue scoring) is **model judgment**, wrapped in a shell of
**deterministic transport**: target→diff resolution (step 0), findings-container
+ wisp persistence (step 4b), the ≥threshold filter (step 6), the dedup-merge
commands (step 7), and promote/burn + audit (step 9).

This suite locks down the transport and the fixture corpus around the model. It
does **not** — and cannot — assert what the model decides; that is the job of
the `gcs-t0a.6` dogfood, which runs the real formula on these fixtures and tunes.
The split mirrors the `.3`/`.4` handoffs (they punted "live behavioral checks
against a real diff" and the dedup coverage to `.5`, and semantic tuning to `.6`).

| Test file | Covers (deterministic) |
| --- | --- |
| `test_01_integrity.sh` | parses; 6 vars resolve 1:1; model-tier + threshold defaults; the Anthropic 0–100 **rubric** and **false-positive list** reproduced **verbatim** (checked against the upstream command, so paraphrase fails the build); 5 angles + category labels; vendor-neutral rule files; scope discipline. |
| `test_02_step0.sh` | step-0 target→diff over real throwaway git repos: empty→clean exit 0 (**acceptance [2]**); path/whole-tree rejection; `kind=pr\|branch\|range` classification; local targets resolve `kind=branch\|range`, never `pr`, and never call `gh` — the precondition behind **acceptance [3]** (angle d self-skips). |
| `test_03_lifecycle.sh` | every embedded bash block is valid bash (this caught a broken step-7 here-doc); container create-once + root resolution; step-7 merge labels/notes; step-9 promote/burn flags; audit + container close; and the **[1]/[4]/[5]** outcomes given fixed decisions, incl. the dedup→one-bead path and the `promoted+merged+burned = considered` audit invariant. |
| `test_04_fixtures.sh` | each fixture builds a real repo, step 0 routes it as its `expected.env` says, and the corpus is internally consistent (planted rule+bug present; dedup findings genuinely collide on file+line+root-cause; nitpick drop-reasons map to the verbatim FP list). |

## Fixture corpus (`fixtures/`)

Each scenario is a self-contained, reusable fixture:

- `build.sh` — sources `_lib.sh`, plants the change in a throwaway git repo, and
  leaves `REPO` (worktree) + `TARGET` (the formula's `target` var) set.
- `expected.env` — `EXPECTED_EMPTY`, `EXPECTED_KIND`, `EXPECTED_OUTCOME`, `NOTES`.

| Fixture | Acceptance | Expected semantic outcome (for `.6`) |
| --- | --- | --- |
| `empty-diff` | [2a] | step 0 stops, empty diff, pipeline never runs |
| `trivial-diff` | [2b] | non-empty range; step-1 eligibility skips (whitespace-only) |
| `no-pr-context` | [3] | `kind=branch`; angle (d) → `skipped: no PR context`, a/b/c/e run |
| `rule-and-bug` | [1] | 2 promoted: a written-rule violation + a real bug (distinct, not merged) |
| `dedup-two-angles` | [4] | bug-scan + git-history collide → **1** promoted bead (both labels + merge note), dup burned |
| `nitpick-fp` | [5] | 0 promoted: every issue is a false-positive category |

### Using the corpus in the `.6` dogfood

```bash
source fixtures/dedup-two-angles/build.sh        # sets REPO, TARGET
cd "$REPO" && gc sling <addr> mol-triage-review --formula --var target="$TARGET"
# then compare the promoted/burned beads against fixtures/.../expected.env
```

## Note on a transport fix made here

`test_03` found the step-7 dedup-merge block's here-document had an **indented
`EOF` terminator**, so "run it verbatim" produced invalid bash. The block was
dedented to column 0 (matching every other bash block in the formula) so the
here-doc closes. No behavior change beyond making the verbatim block runnable.

## Version control

The formula and this suite are intentionally untracked in `math-city/formulas/`
(VC deferred per the `gcs-t0a.1` overseer decision; carried through `.2`–`.4`).
When VC happens, formula + tests + fixtures land together. Nothing here belongs
in the gascity worktree — the formula is a city config, not SDK code.
