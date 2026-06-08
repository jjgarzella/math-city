# Compile check — the formula must compile to the expected ralph graph. This is
# the one test that needs the live `gc` binary; it is SKIPPED (not failed) when
# gc is absent, since test_01 already pins the structure from the TOML directly.

section "03 compile (gc formula show)"

if ! command -v gc >/dev/null 2>&1; then
  echo "  skip gc not on PATH — compile check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc formula show mol-review-loop 2>&1)"; rc=$?
assert_eq "0" "$rc" "gc formula show mol-review-loop exits 0 (compiles)"

# The ralph body expands one iteration of [review-pipeline -> apply-fixes].
assert_contains "$SHOW" "review-loop.iteration.1.review-pipeline" "compiled: review-pipeline in the ralph iteration body"
assert_contains "$SHOW" "review-loop.iteration.1.apply-fixes"     "compiled: apply-fixes in the ralph iteration body"
assert_contains "$SHOW" "mol-review-loop.review-loop:"            "compiled: review-loop ralph control bead"
assert_contains "$SHOW" "workflow-finalize"                       "compiled: clean terminal (workflow-finalize)"

# apply-fixes runs after the review-pipeline scope closes (body ordering).
assert_contains "$SHOW" "apply-fixes: Apply fixes + set review.verdict (fix-mode interface owned by gcs-6r2) [needs: mol-review-loop.review-loop.iteration.1.review-pipeline-scope-check" \
  "compiled: apply-fixes needs the review-pipeline scope (review -> fix ordering)"
