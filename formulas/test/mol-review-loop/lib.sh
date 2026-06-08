# Shared helpers for the mol-review-loop deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions (ok/fail/assert_*), formula
# inspection (formula_py + thin wrappers), and run_verdict — a stub-backed
# runner for the shared verdict-glue check (formulas/lib/review-verdict.sh).

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../mol-review-loop.toml}"
: "${VERDICT_SH:=$SUITE_DIR/../../lib/review-verdict.sh}"
FORMULA_PY="$SUITE_DIR/_formula.py"

# --- counters ----------------------------------------------------------------
PASS=0
FAIL=0
CURRENT_SECTION=""

section() {
  CURRENT_SECTION="$1"
  printf '\n## %s\n' "$1"
}

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

# assert_eq <expected> <actual> <msg>
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) fail "$3" "missing substring [$2]" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3" "unexpected substring [$2]" ;;
    *) ok "$3" ;;
  esac
}

# --- formula inspection ------------------------------------------------------
formula_py() { python3 "$FORMULA_PY" "$FORMULA" "$@"; }

# --- the shared verdict-glue check (the single source of truth the loop runs) -
# run_verdict — run review-verdict.sh with the stub bd/gc on PATH (the stubs
# return canned bead JSON from BD_* env knobs; see bin/bd and bin/gc). Sets
# globals (NOT echoed — a command-substitution subshell would lose the rc):
#   V_RC      exit code (0=converged/stop, 1=iterate, 2=undetermined)
#   V_OUT     stdout
#   V_ERR     stderr
#   V_NUDGE   the fire-and-forget nudge message logged (empty if none fired)
# Scenario env consumed by the stubs / script:
#   GC_BEAD_ID GC_ITERATION BD_ATTEMPT BD_ROOT BD_NOTIFY BD_MAXATT
#   BD_LIST_VERDICTS GC_NUDGE_FAIL
V_RC=0
V_OUT=""
V_ERR=""
V_NUDGE=""
run_verdict() {
  local out err nudgelog
  out="$(mktemp)"; err="$(mktemp)"; nudgelog="$(mktemp)"
  GC_NUDGE_LOG="$nudgelog" PATH="$SUITE_DIR/bin:$PATH" \
    bash "$VERDICT_SH" >"$out" 2>"$err"
  V_RC=$?
  V_OUT="$(cat "$out")"
  V_ERR="$(cat "$err")"
  V_NUDGE="$(cat "$nudgelog")"
  rm -f "$out" "$err" "$nudgelog"
}
