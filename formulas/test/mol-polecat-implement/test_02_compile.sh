# Compile check — the formula must compile to the expected single-session graph.
# This is the one test that needs the live `gc` binary; it is SKIPPED (not
# failed) when gc is absent, since test_01 already pins the structure from the
# TOML directly.

section "02 compile (gc formula show)"

if ! command -v gc >/dev/null 2>&1; then
  echo "  skip gc not on PATH — compile check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc formula show mol-polecat-implement 2>&1)"; rc=$?
assert_eq "0" "$rc" "gc formula show mol-polecat-implement exits 0 (compiles)"

# Every lifecycle step compiles to a prefixed step bead, in order, with the
# auto-appended clean terminal.
for s in load-context workspace-setup preflight-tests implement self-review trigger-review; do
  assert_contains "$SHOW" "mol-polecat-implement.$s" "compiled: step $s present"
done
assert_contains "$SHOW" "workflow-finalize" "compiled: clean terminal (workflow-finalize)"
