# Shared helpers for the expansion-triage-reviewer deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions, formula inspection (formula_py),
# throwaway-git-repo builders, the shared diff resolver runner (run_step0), and
# run_analyze_block / run_lane_block + lane/synth sandboxes — sandboxed runners for
# the fragment's analyze + lane bash blocks against a stub bd/gc + the real shared
# libs. These are the SAME helpers the expansion-standard-reviewer suite uses (the
# shared libs are reviewer-agnostic); only the FORMULA under test differs.

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../expansion-triage-reviewer.toml}"
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

# --- review-lane (lib + lane) runners ----------------------------------------
LANE_LIB="$SUITE_DIR/../../lib/review-lane.sh"

# lane_sandbox — create (once per scenario) a sandbox GC_CITY carrying the real
# review-lane.sh and a populated durable-input store for LB_ROOT, then export the
# scenario env the stub bd reads. Caller may pre-set LB_ROOT / LB_ELIGIBLE /
# LB_TARGET_KIND before the first call; sensible defaults otherwise. Sets/refreshes
# LB_CITY, LB_INPUTS_DIR, LB_CREATE_LOG, LB_UPDATE_LOG, LB_META_LOG.
lane_sandbox() {
  LB_ROOT="${LB_ROOT:-root-lane-$$}"
  LB_WORKDIR="${LB_WORKDIR:-${TMPDIR:-/tmp}}"
  LB_TARGET_KIND="${LB_TARGET_KIND:-range}"
  LB_ELIGIBLE="${LB_ELIGIBLE:-yes}"
  LB_REASON="${LB_REASON:-eligible: non-trivial change}"
  if [ -z "${LB_CITY:-}" ]; then
    LB_CITY="$(mktemp -d "${TMPDIR:-/tmp}/esr-lanecity.XXXXXX")"
    mkdir -p "$LB_CITY/formulas/lib"
    cp -f "$LANE_LIB" "$LB_CITY/formulas/lib/review-lane.sh"
    chmod +x "$LB_CITY/formulas/lib/review-lane.sh"
    LB_INPUTS_DIR="$LB_CITY/.gc/review-inputs/$LB_ROOT"
    mkdir -p "$LB_INPUTS_DIR"
    printf 'diff --git a/app.go b/app.go\n+func Added() {}\n' > "$LB_INPUTS_DIR/diff"
    printf 'app.go\n' > "$LB_INPUTS_DIR/files"
    printf 'a small test change\n' > "$LB_INPUTS_DIR/summary.md"
  fi
  : "${LB_CREATE_LOG:=$(mktemp)}"
  : "${LB_UPDATE_LOG:=$(mktemp)}"
  : "${LB_META_LOG:=$(mktemp)}"
}

# lane_env <args...> — run the given command with the sandbox scenario env + the
# stub bd/gc on PATH. Used to source the lib directly or run a rendered block.
lane_env() {
  GC_CITY="$LB_CITY" \
  GC_BEAD_ID="${LB_BEAD_ID:-lane-bead}" \
  GC_AGENT="gascity/test.polecat" \
  BD_ROOT="$LB_ROOT" \
  BD_WORKDIR="$LB_WORKDIR" \
  BD_META_LOG="$LB_META_LOG" \
  BD_CREATE_LOG="$LB_CREATE_LOG" \
  BD_UPDATE_LOG="$LB_UPDATE_LOG" \
  BD_REVIEW_INPUTS_DIR="$LB_INPUTS_DIR" \
  BD_REVIEW_TARGET_KIND="$LB_TARGET_KIND" \
  BD_REVIEW_ELIGIBLE="$LB_ELIGIBLE" \
  BD_REVIEW_ELIGIBILITY_REASON="$LB_REASON" \
  PATH="$SUITE_DIR/bin:$PATH" \
  "$@"
}

# run_lane_block <lens> <signature> — render the lens lane's ```bash block
# containing <signature> and run it verbatim against the sandbox + stubs. Sets
# LB_RC (exit code) and LB_OUT (combined stdout+stderr). Re-uses the scenario set
# up by lane_sandbox (call it first).
run_lane_block() {
  local lens="$1" sig="$2" script
  LB_BEAD_ID="lane-bead-$lens"
  script="$(formula_py block "{target}.$lens" "$sig")" || {
    LB_RC=99; LB_OUT="render failed: no block with signature [$sig] in $lens"; return 1; }
  LB_OUT="$(lane_env bash -c "$script" 2>&1)"
  LB_RC=$?
}

# create_log_has <needle> — true if any bd-create record contains <needle>.
create_log_has() { grep -q -- "$1" "${LB_CREATE_LOG:-/nonexistent}" 2>/dev/null; }
# update_log_has <needle> — true if any bd-update record contains <needle>.
update_log_has() { grep -q -- "$1" "${LB_UPDATE_LOG:-/nonexistent}" 2>/dev/null; }

# --- review-synthesis (lib) runner -------------------------------------------
SYNTH_LIB="$SUITE_DIR/../../lib/review-synthesis.sh"

# synth_sandbox — create (once per scenario) a sandbox GC_CITY carrying the real
# review-synthesis.sh + a populated durable-input store for SY_ROOT, and write the
# candidate wisps (SY_CANDIDATES_JSON, a JSON array) to a file the stub bd returns
# as the findings container's .children. Caller may pre-set SY_ROOT / SY_ELIGIBLE /
# SY_TARGET_KIND / SY_CANDIDATES_JSON before the first call. Sets SY_CITY,
# SY_INPUTS_DIR, SY_FINDINGS, SY_CANDIDATES_FILE, SY_UPDATE_LOG, SY_META_LOG,
# SY_PROMOTE_LOG.
synth_sandbox() {
  SY_ROOT="${SY_ROOT:-root-synth-$$}"
  SY_ELIGIBLE="${SY_ELIGIBLE:-yes}"
  SY_TARGET_KIND="${SY_TARGET_KIND:-range}"
  SY_FINDINGS="$SY_ROOT.findings"
  if [ -z "${SY_CITY:-}" ]; then
    SY_CITY="$(mktemp -d "${TMPDIR:-/tmp}/esr-synthcity.XXXXXX")"
    mkdir -p "$SY_CITY/formulas/lib"
    cp -f "$SYNTH_LIB" "$SY_CITY/formulas/lib/review-synthesis.sh"
    chmod +x "$SY_CITY/formulas/lib/review-synthesis.sh"
    SY_INPUTS_DIR="$SY_CITY/.gc/review-inputs/$SY_ROOT"
    mkdir -p "$SY_INPUTS_DIR"
    printf 'diff --git a/app.go b/app.go\n+func Added() {}\n' > "$SY_INPUTS_DIR/diff"
    printf 'a small test change\n' > "$SY_INPUTS_DIR/summary.md"
  fi
  : "${SY_CANDIDATES_FILE:=$(mktemp)}"
  : "${SY_UPDATE_LOG:=$(mktemp)}"
  : "${SY_META_LOG:=$(mktemp)}"
  : "${SY_PROMOTE_LOG:=$(mktemp)}"
  printf '%s' "${SY_CANDIDATES_JSON:-[]}" > "$SY_CANDIDATES_FILE"
}

# synth_env <args...> — run a command with the synthesis sandbox env + the stub
# bd/gc on PATH. The stub returns SY_CANDIDATES_FILE as the findings container's
# children and logs promote/label/burn to SY_PROMOTE_LOG.
synth_env() {
  GC_CITY="$SY_CITY" \
  GC_BEAD_ID="${SY_BEAD_ID:-synthesis-bead}" \
  GC_AGENT="gascity/test.polecat" \
  BD_ROOT="$SY_ROOT" \
  BD_REVIEW_INPUTS_DIR="$SY_INPUTS_DIR" \
  BD_REVIEW_TARGET_KIND="$SY_TARGET_KIND" \
  BD_REVIEW_ELIGIBLE="$SY_ELIGIBLE" \
  BD_FINDINGS="$SY_FINDINGS" \
  BD_CANDIDATES_FILE="$SY_CANDIDATES_FILE" \
  BD_UPDATE_LOG="$SY_UPDATE_LOG" \
  BD_META_LOG="$SY_META_LOG" \
  BD_PROMOTE_LOG="$SY_PROMOTE_LOG" \
  PATH="$SUITE_DIR/bin:$PATH" \
  "$@"
}

# synth_meta_val <key> — last recorded --set-metadata value in SY_META_LOG.
synth_meta_val() { grep "^$1=" "${SY_META_LOG:-/nonexistent}" 2>/dev/null | tail -1 | sed "s/^$1=//"; }
# promote_log_has <needle> — true if any promote/label/burn record contains <needle>.
promote_log_has() { grep -q -- "$1" "${SY_PROMOTE_LOG:-/nonexistent}" 2>/dev/null; }
