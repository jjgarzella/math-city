# Shared helpers for the mol-triage-review-independent deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions, host-formula inspection
# (formula_py), a reader for the FRAGMENT's var contract (used for the no-drift
# cross-check), and gc-show helpers for the compile/expand tests.

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../mol-triage-review-independent.toml}"
: "${FRAGMENT:=$SUITE_DIR/../../expansion-triage-reviewer.toml}"
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

# --- host-formula inspection -------------------------------------------------
formula_py() { python3 "$FORMULA_PY" "$FORMULA" "$@"; }

# --- fragment inspection (for no-drift: the host must propagate every fragment
# var). The fragment uses [[template]] + [vars]; this reads ONLY its var contract,
# which is all the host cross-check needs.
# fragment_var_defaults — emits `name=default` for each [vars.*], one per line.
fragment_var_defaults() {
  python3 - "$FRAGMENT" <<'PY'
import sys, tomllib
data = tomllib.loads(open(sys.argv[1], "rb").read().decode())
for name in sorted(data.get("vars", {})):
    print(f"{name}={data['vars'][name].get('default','')}")
PY
}
# fragment_vars — sorted [vars.*] names of the fragment, one per line.
fragment_vars() { fragment_var_defaults | sed 's/=.*//'; }

# --- gc compile/expand helpers -----------------------------------------------
HAVE_GC=0
command -v gc >/dev/null 2>&1 && HAVE_GC=1

# gc_show [extra gc args...] — `gc formula show mol-standard-review` (tree text).
gc_show() { gc formula show "$(formula_py formula-name)" "$@" 2>/dev/null; }
# gc_show_json [extra gc args...] — the --json render of the compiled host.
gc_show_json() { gc formula show "$(formula_py formula-name)" "$@" --json 2>/dev/null; }
