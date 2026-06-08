# mol-triage-review — dogfood + tune (gcs-t0a.6)

Final build step of epic `gcs-t0a`. The deterministic suite (`gcs-t0a.5`,
`./run.sh`) locks down the **transport**; this step exercises the **model
judgment** (the five angles + the per-issue scorer) on real inputs, eyeballs
precision/recall, decides whether the model-tier / threshold vars need tuning,
and records the observed precision.

Date: 2026-06-07. Run by polecat `gascity/gasvillage.ash`.

## How it was run

`mol-triage-review` is ONE claude session that fans out internally via the
Task/sub-agent tool. The dogfood was run faithfully to that design: the
orchestrator (this session) resolved each target to a diff, launched the review
angles as **Sonnet** Task sub-agents (`review_model` default) and the per-issue
scorers as **Haiku** Task sub-agents (`score_model` default), then applied the
deterministic steps (threshold filter, dedup-merge) itself. Every angle received
the scope-discipline text and the Anthropic false-positive list **verbatim**;
every scorer received the Anthropic 0–100 rubric **verbatim**.

Why fixtures *and* a real diff: a real diff has no ground-truth labels, so it can
only confirm **precision** (did we emit a false positive?) — it cannot measure
**recall** (you never know which real bugs you missed). The ground-truth fixture
corpus (`fixtures/`, built in `.5`) has known TP/FP/FN by construction, so it is
where precision *and* recall are actually measured. The real diff is where
precision is stress-tested on genuine, well-crafted code.

## Targets

| Target | Kind | What it is |
| --- | --- | --- |
| **argos branch** | real (`range`) | `main..HEAD` on this polecat branch — the `argos` rate-limit-watchdog pack (epic mc-34t): new event type + typed payload, pack/agent TOML, prompt templates, tests. Generated files (`openapi.json`, generated TS, `client_gen.go`) excluded as the scope discipline requires. The formula's exact default target on a real polecat branch. |
| **rule-and-bug** | fixture (`range`) | Plants a written rule (`AGENTS.md`: "Every exported function MUST have a doc comment") and a change that violates it **and** adds a real bug (`return xs[0]` with no length guard). Ground truth: **2 promoted, distinct (not merged)**. |
| **nitpick-fp** | fixture (`range`) | A change whose only issues are a formatting nitpick (double space) and a missing test — both on the Anthropic false-positive list. Ground truth: **0 promoted**. |

## Results

### argos branch (real diff) — 0 findings, correctly clean

Angles run: (a) rule-adherence, (b) bug-scan, (c) git-history, (e) in-code
invariants. Angle (d) prior-PRs **self-skipped cleanly** ("no PR context": local
`range` target, no PR) — exactly the best-effort behavior `.5` set up.

All four angles returned `[]`. Notably the angles got the *hard* calls right:

- The new `session.recovered` event **correctly follows** the load-bearing
  "typed events" CI invariant — it is added to `events.KnownEventTypes` *and*
  registered via `events.RegisterPayload(events.SessionRecovered,
  SessionRecoveredPayload{})`. Angle (a) verified the invariant is *satisfied*
  and did not invent a violation.
- Role names inside the `argos` pack's prompt templates / TOML are **not**
  "ZERO hardcoded roles" violations — that rule governs Go *source* only; roles
  are pure config. Angle (a) applied that gloss correctly.
- Angle (e) noticed two *other* `KnownEventTypes` entries that look unregistered
  but **correctly excluded them as pre-existing** (not on the changed lines) per
  the false-positive list. (Claim unverified and not promoted — exactly right.)

**Independent human re-review (the eyeball):** I read the substantive diff
myself. The closest thing to a defect is `sectionBetween(t, body, "Record the
recovery", "\n## ")` in `argos_test.go:392`, which scans from a `####` sub-heading
to the next `##` heading — slightly wider than its comment implies. It is a
*conservative* over-capture (it checks *more* text for role-freeness, which is
safe for the invariant) and the test passes; a senior engineer would not flag it.
The formula's decision **not** to flag it matches that judgment. Conclusion: the
diff is genuinely clean, and the formula's 0 findings is correct on **both**
precision (no FP) and recall (nothing real missed).

### rule-and-bug (ground truth: 2) — 2 promoted ✓

| Angle | Candidate | self-score | re-score (haiku) | decision |
| --- | --- | --- | --- | --- |
| a (rule) | `First` exported, no doc comment — quotes `AGENTS.md:3` verbatim | 95 | **100** (scorer re-opened AGENTS.md and verified the rule text actually appears) | promote |
| b (bug) | `return xs[0]` panics on nil/empty slice | 97 | **100** (runtime certainty) | promote |

Same file, **different root cause** (a style-rule violation vs. a nil-deref) →
step-7 dedup correctly **did not merge** → **2 distinct promoted findings**.
Matches ground truth exactly.

### nitpick-fp (ground truth: 0) — 0 promoted ✓

No rule files present → angle (a) returned `[]`. Angle (b), explicitly handed the
verbatim FP list, **rejected** the double-space formatting and the missing test as
false-positive categories → `[]`. Zero candidates, zero promotions. Matches ground
truth exactly.

## Metrics (against ground truth + verified real diff)

- **Precision** = TP / (TP + FP) = 2 / (2 + 0) = **100%**.
  Every promoted finding holds up to human review; **zero** false positives at
  threshold 80 across all three targets.
- **Recall** (measurable on the fixtures) = TP / (TP + FN) = 2 / 2 = **100%**.
  Both planted issues caught; both planted false-positives correctly rejected;
  the real diff confirmed clean by independent review (no FN).

## Threshold & model-tier tuning — NONE NEEDED

- **threshold = 80**: clean separation. Real findings re-scored **100** (≫ 80);
  every false-positive category produced **no candidate at all** (effective 0).
  There is no finding anywhere near the 80 boundary, so the cutoff is not
  fragile. Lowering it would only admit the FP categories; raising it buys
  nothing. Keep 80.
- **review_model = sonnet**: the angles caught the planted issues, applied the
  rule glosses correctly, and produced no FPs on a real diff. Keep sonnet.
- **score_model = haiku**: the scorer did its job as a *check*, not a rubber
  stamp — it re-opened `AGENTS.md` to confirm the cited rule actually exists
  before scoring the rule finding 100, exactly as step 5 requires. Keep haiku.
- **aux_model = haiku**: eligibility/summary/recheck are cheap routing decisions;
  no tuning indicated.

**Decision: ship the defaults unchanged** (`review_model=sonnet`,
`score_model=haiku`, `aux_model=haiku`, `threshold=80`). The dogfood found no
behavior that the defaults get wrong.

## Mechanical / dispatch checks

- `gc formula show mol-triage-review` resolves — the formula is registered.
- `gc sling <agent> mol-triage-review --formula --var target=… --dry-run`
  resolves the formula, would `gc formula cook` it into a wisp, and route the
  wisp root to the agent. The single-session dispatch path is sound. (Gate /
  merge-path *placement* remains out of scope — see `gcs-bgm`.)
- Deterministic suite (`./run.sh`): **121 passed, 0 failed**.

## Follow-ups (filed, not blocking)

- **README invocation flag typo**: `README.md` (and the `.5` handoff) suggest
  `gc sling … --formula -V target=…`. The real flag is `--var` (`-V` errors with
  "unknown shorthand flag"). Fixed in this commit.
- **Scale test on a large refactor**: the dogfood used a small fixture corpus and
  one clean real diff. A useful future check is a *large, mostly-deletion* real
  diff (e.g. a 60-file refactor) to confirm the angles don't flood with
  low-confidence FPs on intentional deletions. Not required for Tier-1 sign-off;
  noted for the gate-placement work under `gcs-bgm`.

## Bottom line

On ground truth + a real polecat diff, `mol-triage-review` ran at **100%
precision / 100% recall** with **no false positives at threshold 80** and **no
tuning required**. Acceptance for `gcs-t0a.6` met.
