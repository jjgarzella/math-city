# Dogfooding mol-triage-review-independent

gcs-f4j.10.1 asks the independent triage reviewer to be proven on a real diff.
There are two layers with very different cost profiles.

## Layer 1 — deterministic real-diff materialization (DONE, in-session)

The host must *assemble the real fragment into a real molecule on a real diff
target* — the compose.expand path, end to end, with the target threaded through.
Deterministic and cheap, so it is done here and re-runnable any time:

```bash
cd "$GC_CITY"   # math-city
REAL_RANGE="8659521~1..8659521"     # a real gcs-f4j commit diff
gc formula show mol-triage-review-independent --var target="$REAL_RANGE" --json
```

Confirmed (2026-06-10):
- all seven passes materialize: `analyze, rule-adherence, bug-scan, git-history,
  prior-prs, in-code-invariants, synthesis` under
  `mol-triage-review-independent.review-pipeline.*`, plus the clean
  `workflow-finalize` terminal;
- the real range is threaded into the analyze pass and reaches the shared
  `resolve-diff.sh`;
- zero unsubstituted fragment vars; per-lane `opt_model` tiering intact
  (haiku for the mechanical angles, sonnet for the judgment angles + synthesis).

`test_02_lifecycle.sh` pins the same path on the default + synthetic overridden
targets as a permanent regression guard.

## Layer 2 — live multi-session run (GATED)

The model-dependent half: actually run the seven passes as live sessions and
confirm synthesis emits **deduped, severity-tagged finding beads** (only the
candidates that cleared the confidence threshold) under the molecule root's
findings container, plus a `gc.review.synthesis_verdict`.

```bash
# Pick a real, non-trivial diff bead, then:
gc sling gascity/gasvillage.polecat <bead> --on mol-triage-review-independent \
  --var target="<pr|branch|range>" --nudge
```

**Why it is gated, not fired here:**
- Every lane carries `gc.run_target=gasvillage.polecat`, and the gascity polecat
  pool is **max=1**. A polecat slinging this from inside the only slot cannot also
  service the lanes — they queue behind its own drain. The live run is an
  *across-sessions* flow, not a self-driven one.
- The live per-lane `opt_model` → session `--model` **fold** is gated on the gc
  rebuild (parent gcs-f4j.10; live string/effect test gcs-f4j.8.2.1). Until then
  `opt_model` substitutes into the bead metadata (proven here) but does not yet
  retarget the spawned session's model.
- It is the expensive, model-dependent step; per the overseer's steer-dispatch
  preference, heavy review slings are steered, not fired autonomously by the
  building polecat.

The fragment's **execution transport** is already proven deterministically by
`formulas/test/expansion-triage-reviewer/` (analyze durable inputs + path
rejection + rule discovery, the five lanes' gate/self-skip/category filing, the
synthesis confidence gate + verdict), so Layer 2 validates LLM *judgment quality*
on a real diff, not the plumbing.

Tracked as a gated follow-up (see the gcs-f4j.10.1 close notes).
