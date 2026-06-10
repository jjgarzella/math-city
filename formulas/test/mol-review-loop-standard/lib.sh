# Shared helpers for the mol-review-loop-standard deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions, formula inspection (formula_py +
# thin wrappers), a reader for the FRAGMENT's var contract (fragment_* — used for
# the no-drift cross-check), gc-show helpers for the compile/expand test, and the
# apply-fixes lib runner (afx_sandbox/afx_env — stub-backed, no real Dolt).

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../mol-review-loop-standard.toml}"
: "${FRAGMENT:=$SUITE_DIR/../../expansion-standard-reviewer.toml}"
: "${VERDICT_SH:=$SUITE_DIR/../../lib/review-verdict.sh}"
: "${APPLY_FIXES_SH:=$SUITE_DIR/../../lib/review-apply-fixes.sh}"
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

# --- fragment inspection (for no-drift: the loop must propagate every fragment
# var). The fragment uses [[template]] + [vars]; this reads ONLY its var contract.
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
gc_show() { gc formula show "$(formula_py formula-name)" "$@" 2>/dev/null; }
gc_show_json() { gc formula show "$(formula_py formula-name)" "$@" --json 2>/dev/null; }

# --- apply-fixes lib runner (the new verdict->severity->fix machinery) --------
# afx_sandbox — create (once per scenario) a sandbox GC_CITY carrying the real
# review-apply-fixes.sh, and write the durable findings (AFX_FINDINGS_JSON, a JSON
# array) to a file the stub bd returns as the findings container's .children.
# Caller may pre-set AFX_ROOT / AFX_VERDICT / AFX_PROMOTED / AFX_BURNED /
# AFX_WORKDIR / AFX_FINDINGS_JSON / FIX_THRESHOLD before the first call. Sets
# AFX_CITY, AFX_FINDINGS, AFX_FINDINGS_FILE, AFX_META_LOG, AFX_UPDATE_LOG,
# AFX_NUDGE_LOG.
afx_sandbox() {
  AFX_ROOT="${AFX_ROOT:-root-afx-$$}"
  AFX_FINDINGS="$AFX_ROOT.findings"
  if [ -z "${AFX_CITY:-}" ]; then
    AFX_CITY="$(mktemp -d "${TMPDIR:-/tmp}/mrls-afxcity.XXXXXX")"
    mkdir -p "$AFX_CITY/formulas/lib"
    cp -f "$APPLY_FIXES_SH" "$AFX_CITY/formulas/lib/review-apply-fixes.sh"
    chmod +x "$AFX_CITY/formulas/lib/review-apply-fixes.sh"
  fi
  : "${AFX_FINDINGS_FILE:=$(mktemp)}"
  : "${AFX_META_LOG:=$(mktemp)}"
  : "${AFX_UPDATE_LOG:=$(mktemp)}"
  : "${AFX_NUDGE_LOG:=$(mktemp)}"
  printf '%s' "${AFX_FINDINGS_JSON:-[]}" > "$AFX_FINDINGS_FILE"
}

# afx_env <args...> — run a command with the apply-fixes sandbox env + the stub
# bd/gc on PATH. The stub returns AFX_FINDINGS_FILE as the findings container's
# children and logs every metadata/status write.
afx_env() {
  GC_CITY="$AFX_CITY" \
  GC_BEAD_ID="${AFX_BEAD_ID:-apply-fixes-bead}" \
  GC_AGENT="gascity/test.polecat" \
  FIX_THRESHOLD="${FIX_THRESHOLD:-minor}" \
  BD_ROOT="$AFX_ROOT" \
  BD_SYNTH_VERDICT="${AFX_VERDICT:-}" \
  BD_SYNTH_PROMOTED="${AFX_PROMOTED:-}" \
  BD_SYNTH_BURNED="${AFX_BURNED:-}" \
  BD_WORKDIR="${AFX_WORKDIR:-}" \
  BD_FINDINGS="$AFX_FINDINGS" \
  BD_FINDINGS_FILE="$AFX_FINDINGS_FILE" \
  BD_META_LOG="$AFX_META_LOG" \
  BD_UPDATE_LOG="$AFX_UPDATE_LOG" \
  GC_NUDGE_LOG="$AFX_NUDGE_LOG" \
  PATH="$SUITE_DIR/bin:$PATH" \
  "$@"
}

# afx_run <snippet> — source the real lib in the sandbox env and run <snippet>.
# Sets globals (NOT echoed — a command-substitution subshell would lose AFX_RC):
#   AFX_RC   exit code      AFX_OUT  stdout      AFX_ERR  stderr
# Call it directly (never inside $(...)), then read $AFX_OUT / $AFX_ERR / $AFX_RC.
AFX_RC=0
AFX_OUT=""
AFX_ERR=""
afx_run() {
  local snippet="$1" out err
  out="$(mktemp)"; err="$(mktemp)"
  afx_env bash -c '
    set -uo pipefail
    . "$GC_CITY/formulas/lib/review-apply-fixes.sh"
    '"$snippet"'
  ' >"$out" 2>"$err"
  AFX_RC=$?
  AFX_OUT="$(cat "$out")"
  AFX_ERR="$(cat "$err")"
  rm -f "$out" "$err"
}
