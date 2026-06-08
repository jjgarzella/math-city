# Shared helpers for the mol-triage-review deterministic test suite.
# Sourced by run.sh and every test_*.sh. Not executable on its own.
#
# Exposes: counters (PASS/FAIL), assertions (ok/fail/assert_*), formula
# inspection (formula_block, formula_*), template rendering (render), and
# throwaway-git-repo builders for the step-0 resolution tests.

# --- locations (run.sh exports these; provide safe fallbacks) ----------------
: "${SUITE_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
: "${FORMULA:=$SUITE_DIR/../../mol-triage-review.toml}"
: "${ANTHROPIC_SRC:=$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md}"
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
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    fail "$3" "expected [$1], got [$2]"
  fi
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

# assert_file_contains <file> <needle> <msg>
assert_file_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    ok "$3"
  else
    fail "$3" "[$1] missing [$2]"
  fi
}

# --- formula inspection ------------------------------------------------------
formula_py() { python3 "$FORMULA_PY" "$FORMULA" "$@"; }
# formula_block <signature> -> the verbatim ```bash block containing it
formula_block() { formula_py block "$1"; }

# --- template rendering ------------------------------------------------------
# render <text>  — substitute {{var}} with the formula's default values, then
# apply any RENDER_<VAR> env overrides. Used to make the embedded bash blocks
# (which carry {{target}}, {{base_branch}}, {{threshold}}) runnable.
render() {
  local text="$1" name def envname val
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    envname="RENDER_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    eval "val=\${$envname-__UNSET__}"
    if [ "$val" = "__UNSET__" ]; then
      def="$(formula_py var-default "$name" 2>/dev/null || true)"
      val="$def"
    fi
    text="${text//\{\{$name\}\}/$val}"
  done < <(formula_py template-refs)
  printf '%s' "$text"
}

# --- throwaway git repos for step-0 ------------------------------------------
# new_git_repo — create and echo the path of an isolated git repo with one
# committed file on the default branch named by RENDER_BASE_BRANCH (default main).
new_git_repo() {
  local base="${RENDER_BASE_BRANCH:-main}" dir
  dir="$(mktemp -d)"
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

# run_step0 <repo> <target> — run the rendered step-0 block inside <repo> with
# RENDER_TARGET=<target>. Sets two globals (NOT echoed — a command-substitution
# subshell would lose the exit code): STEP0_OUT (combined stdout+stderr) and
# STEP0_RC (exit code). A bin/ shim dir (gh stub) is prepended to PATH so the PR
# branch is testable without network.
STEP0_OUT=""
STEP0_RC=0
run_step0() {
  local repo="$1" target="$2" block rendered
  block="$(formula_block 'TARGET="{{target}}"')"
  rendered="$(RENDER_TARGET="$target" render "$block")"
  STEP0_OUT="$(cd "$repo" && PATH="$SUITE_DIR/bin:$PATH" bash -c "$rendered" 2>&1)"
  STEP0_RC=$?
}
