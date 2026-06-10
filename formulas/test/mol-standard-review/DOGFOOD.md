# Dogfooding mol-standard-review

gcs-f4j.8.4 asks the host to be proven **standalone on a real diff**. There are
two layers, and they have very different cost profiles.

## Layer 1 — deterministic real-diff materialization (DONE, in-session)

The host must *assemble the real fragment into a real molecule on a real diff
target* — the compose.expand path, end to end, with the target threaded through.
This is deterministic and cheap, so it is done here and re-runnable any time:

```bash
cd "$GC_CITY"   # math-city
REAL_RANGE="e1266ea~1..e1266ea"     # the real gcs-f4j.8.3 synthesis commit diff
gc formula show mol-standard-review --var target="$REAL_RANGE" --json
```

Confirmed (2026-06-10):
- all eight passes materialize: `analyze, quality, security, performance,
  architecture, testing, docs, synthesis` under `mol-standard-review.review-pipeline.*`;
- the real range is threaded into the analyze pass and reaches the shared
  `resolve-diff.sh` (target `"e1266ea~1..e1266ea"`, base `"main"`);
- zero unsubstituted fragment vars; per-lens `opt_model` tiering intact.

`test_02_lifecycle.sh` pins the same path on the default + a synthetic
overridden target as a permanent regression guard.

## Layer 2 — live multi-session run (GATED — needs a steered dispatch)

The model-dependent half: actually run the eight passes as eight live sessions
and confirm synthesis emits **deduped, severity-tagged finding beads** under the
molecule root's findings container.

```bash
# Pick a real, non-trivial diff bead, then:
gc sling gascity/gasvillage.polecat <bead> --on mol-standard-review \
  --var target="<pr|branch|range>" --nudge
```

**Why it is gated, not fired here:**
- Every lane carries `gc.run_target=gasvillage.polecat`, and the gascity polecat
  pool is **max=1**. A polecat slinging this from inside the only slot cannot
  also service the lanes — they queue behind its own drain. The live run is an
  *across-sessions* flow, not a self-driven one.
- It is the expensive, model-dependent step; per project convention (and the
  overseer's steer-dispatch preference) heavy review slings are steered, not
  fired autonomously by the building polecat.

The fragment's **execution transport** is already proven deterministically by
`formulas/test/expansion-standard-reviewer/` (analyze durable inputs, the six
lanes, synthesis dedup-merge + severity promotion + verdict — 225 assertions),
so Layer 2 validates LLM *judgment quality* on a real diff, not the plumbing.

Tracked as a gated follow-up (see the gcs-f4j.8.4 close notes).
