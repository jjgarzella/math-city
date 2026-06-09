# Shared helpers for the expansion-standard-reviewer deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions, formula inspection (formula_py),
# throwaway-git-repo builders, the shared diff resolver runner (run_step0, same
# contract the triage suite pins), and run_analyze_block — a sandboxed runner for
# the fragment's analyze bash blocks against a stub bd/gc + a real resolver.

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../expansion-standard-reviewer.toml}"
: "${RESOLVER:=$SUITE_DIR/../../lib/resolve-diff.sh}"
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

# assert_file_nonempty <file> <msg>
assert_file_nonempty() {
  if [ -s "$1" ]; then ok "$2"; else fail "$2" "[$1] missing or empty"; fi
}

# --- formula inspection ------------------------------------------------------
formula_py() { python3 "$FORMULA_PY" "$FORMULA" "$@"; }

# --- throwaway git repos -----------------------------------------------------
# new_git_repo — create and echo the path of an isolated git repo with one
# committed file on the base branch named by RENDER_BASE_BRANCH (default main).
new_git_repo() {
  local base="${RENDER_BASE_BRANCH:-main}" dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/esr-repo.XXXXXX")"
  (
    cd "$dir"
    git init -q -b "$base"
    git config user.email t@t.test
    git config user.name test
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m seed
  )
  printf '%s' "$dir"
}

# --- the shared diff resolver (the single source of truth the analyze step calls)
# run_step0 <repo> <target> — run the shared resolver inside <repo>. Sets globals
# (NOT echoed — a subshell would lose the exit code):
#   STEP0_STDOUT  the eval-able machine result (empty on an empty diff)
#   STEP0_OUT     stderr narration + the machine result, combined
#   STEP0_RC      exit code
STEP0_OUT=""
STEP0_STDOUT=""
STEP0_RC=0
run_step0() {
  local repo="$1" target="$2" base="${RENDER_BASE_BRANCH:-main}" err
  err="$(mktemp)"
  STEP0_STDOUT="$(cd "$repo" && PATH="$SUITE_DIR/bin:$PATH" bash "$RESOLVER" "$target" "$base" 2>"$err")"
  STEP0_RC=$?
  STEP0_OUT="$(cat "$err")
$STEP0_STDOUT"
  rm -f "$err"
}

# --- analyze block runner ----------------------------------------------------
# run_analyze_block <signature> <review_target> <work_dir> — render the analyze
# ```bash block containing <signature>, then run it in a sandbox: a temp GC_CITY
# carrying the real resolver, the bin/ stub bd+gc on PATH, and a recording
# BD_META_LOG. Sets globals:
#   AB_RC        exit code
#   AB_OUT       combined stdout+stderr
#   AB_INPUTS    the durable inputs dir ($GC_CITY/.gc/review-inputs/$AB_ROOT)
#   AB_META_LOG  file of recorded `key=value` --set-metadata pairs
#   AB_CITY      the sandbox GC_CITY
# Re-uses AB_ROOT/AB_CITY/AB_META_LOG across calls in the same scenario when the
# caller pre-sets them; otherwise fresh ones are minted.
AB_RC=0
AB_OUT=""
AB_INPUTS=""
AB_META_LOG=""
AB_CITY=""
AB_ROOT=""
run_analyze_block() {
  local sig="$1" rtarget="$2" workdir="$3" script
  AB_ROOT="${AB_ROOT:-root-$$}"
  if [ -z "${AB_CITY:-}" ]; then
    AB_CITY="$(mktemp -d "${TMPDIR:-/tmp}/esr-city.XXXXXX")"
    mkdir -p "$AB_CITY/formulas/lib"
    cp -f "$RESOLVER" "$AB_CITY/formulas/lib/resolve-diff.sh"
    chmod +x "$AB_CITY/formulas/lib/resolve-diff.sh"
  fi
  [ -z "${AB_META_LOG:-}" ] && AB_META_LOG="$(mktemp)"
  AB_INPUTS="$AB_CITY/.gc/review-inputs/$AB_ROOT"

  script="$(RENDER_REVIEW_TARGET="$rtarget" RENDER_BASE_BRANCH="${RENDER_BASE_BRANCH:-main}" \
    formula_py block '{target}.analyze' "$sig")" || {
      AB_RC=99; AB_OUT="render failed: no block with signature [$sig]"; return 1; }

  local out
  out="$(
    cd "$workdir" 2>/dev/null || cd "${TMPDIR:-/tmp}"
    GC_CITY="$AB_CITY" \
    GC_BEAD_ID="analyze-bead-1" \
    GC_AGENT="gascity/test.polecat" \
    BD_ROOT="$AB_ROOT" \
    BD_WORKDIR="$workdir" \
    BD_META_LOG="$AB_META_LOG" \
    PATH="$SUITE_DIR/bin:$PATH" \
    bash -c "$script" 2>&1
  )"
  AB_RC=$?
  AB_OUT="$out"
}

# meta_val <key> — last recorded value for a --set-metadata key in AB_META_LOG.
meta_val() {
  [ -f "${AB_META_LOG:-/nonexistent}" ] || { printf ''; return; }
  grep "^$1=" "$AB_META_LOG" | tail -1 | sed "s/^$1=//"
}
