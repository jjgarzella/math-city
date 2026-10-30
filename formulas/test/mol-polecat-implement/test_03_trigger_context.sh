section "03 trigger context behavior"

TRIGGER_TEST_ROOT="$TMPDIR/implement-trigger-$$"
mkdir -p "$TRIGGER_TEST_ROOT/bin" "$TRIGGER_TEST_ROOT/worktree"
TRIGGER_BASE_SHA="0123456789abcdef0123456789abcdef01234567"
TRIGGER_WORK_DIR="$(cd "$TRIGGER_TEST_ROOT/worktree" && pwd -P)"
TRIGGER_BRANCH="polecat/review-context"
TRIGGER_ROOT="trigger-root"
mkdir -p "$TRIGGER_TEST_ROOT/logs"
: > "$TRIGGER_TEST_ROOT/logs/bd.log"
: > "$TRIGGER_TEST_ROOT/logs/gc.log"
: > "$TRIGGER_TEST_ROOT/logs/git.log"

cat > "$TRIGGER_TEST_ROOT/bin/bd" <<'BD'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    target="${2:-}"
    if [ "$target" = "${GC_BEAD_ID:-}" ]; then
      jq -nc --arg id "$target" --arg root "$BD_ROOT_ID" \
        '[{id:$id,metadata:{"gc.root_bead_id":$root}}]'
    elif [ "$target" = "$BD_ROOT_ID" ]; then
      jq -nc --arg id "$target" --arg wd "$BD_WORK_DIR" \
        --arg branch "$BD_BRANCH" --arg base_ref "$BD_BASE_REF" \
        '[{id:$id,metadata:{work_dir:$wd,branch:$branch,base_ref:$base_ref}}]'
    else
      printf '[]\n'
    fi
    ;;
  update)
    printf '%s\n' "$*" >> "$BD_LOG"
    ;;
  *)
    echo "unexpected bd command: $*" >&2
    exit 2
    ;;
esac
BD
cat > "$TRIGGER_TEST_ROOT/bin/gc" <<'GC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GC_LOG"
python3 - "$GC_ARGV_LOG" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "a") as out:
    out.write(json.dumps(sys.argv[2:]) + "\n")
PY
if [ "${1:-}" = "sling" ]; then
  [ -z "${GC_SLING_OUTPUT:-}" ] || printf '%s\n' "$GC_SLING_OUTPUT"
  exit "${GC_SLING_EXIT_CODE:-0}"
fi
GC
cat > "$TRIGGER_TEST_ROOT/bin/git" <<'GIT'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$GIT_LOG"
case "$*" in
  "status --porcelain") : ;;
  "branch --show-current") echo "fallback-branch" ;;
  "merge-base origin/review-loop-repair HEAD") echo "$TRIGGER_BASE_SHA" ;;
  "rev-parse --verify $TRIGGER_BASE_SHA^{commit}") echo "$TRIGGER_BASE_SHA" ;;
  remote) echo origin ;;
  push\ *) : ;;
  *) echo "unexpected git command: $*" >&2; exit 2 ;;
esac
GIT
chmod +x "$TRIGGER_TEST_ROOT/bin/bd" "$TRIGGER_TEST_ROOT/bin/gc" "$TRIGGER_TEST_ROOT/bin/git"

TRIGGER_TEST_COMMAND="julia --project=. -e 'using Pkg; Pkg.test(test_args=[\"--workflow=presubmit\"])'"
export TRIGGER_TEST_COMMAND
TRIGGER_BLOCK_TEMPLATE="$(formula_py block trigger-review 'gc sling')"
render_trigger_block() {
printf '%s' "$TRIGGER_BLOCK_TEMPLATE" | \
  TRIGGER_FORMULA_VALUE=mol-review-loop-standard \
  TRIGGER_WORKER_VALUE=gasvillage.polecat \
  TRIGGER_BASE_BRANCH_VALUE=review-loop-repair \
  TRIGGER_PUSH_REMOTE_VALUE=review-fork \
  python3 -c 'import os,sys; s=sys.stdin.read();
for key, env in (("review_formula","TRIGGER_FORMULA_VALUE"),("review_worker_target","TRIGGER_WORKER_VALUE"),("base_branch","TRIGGER_BASE_BRANCH_VALUE"),("push_remote","TRIGGER_PUSH_REMOTE_VALUE"),("test_command","TRIGGER_TEST_COMMAND")):
    s=s.replace("{{"+key+"}}", os.environ[env])
sys.stdout.write(s)'
}
TRIGGER_OUT="$TRIGGER_TEST_ROOT/output"
run_trigger_block() {
TRIGGER_BLOCK="$(render_trigger_block)"
if (
  cd "$TRIGGER_TEST_ROOT/worktree" && \
  env PATH="$TRIGGER_TEST_ROOT/bin:$PATH" \
    GC_BEAD_ID=trigger-step GC_AGENT=trigger-test GC_RIG=math-experiments \
    BD_ROOT_ID="$TRIGGER_ROOT" BD_WORK_DIR="$TRIGGER_WORK_DIR" \
    BD_BRANCH="$TRIGGER_BRANCH" BD_BASE_REF=origin/review-loop-repair \
    BD_LOG="$TRIGGER_TEST_ROOT/logs/bd.log" \
    GC_LOG="$TRIGGER_TEST_ROOT/logs/gc.log" \
    GC_ARGV_LOG="$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl" \
    GIT_LOG="$TRIGGER_TEST_ROOT/logs/git.log" \
    TRIGGER_BASE_SHA="$TRIGGER_BASE_SHA" \
    GC_SLING_EXIT_CODE="${GC_SLING_EXIT_CODE:-0}" \
    GC_SLING_OUTPUT="${GC_SLING_OUTPUT:-}" bash -c "$TRIGGER_BLOCK"
) > "$TRIGGER_OUT" 2>&1; then
  TRIGGER_RC=0
else
  TRIGGER_RC=$?
fi
}
run_trigger_block
TRIGGER_GC_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/gc.log")"
TRIGGER_GIT_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/git.log")"
TRIGGER_BD_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/bd.log")"

assert_eq "0" "$TRIGGER_RC" "trigger-review completes with a valid worktree context"
assert_contains "$TRIGGER_GC_LOG" "runtime drain-ack" "successful trigger-review drains after dispatch"
assert_contains "$TRIGGER_GIT_LOG" "merge-base origin/review-loop-repair HEAD" "trigger resolves its base from the recorded base ref"
MERGE_BASE_CALLS="$(grep -c '^merge-base ' "$TRIGGER_TEST_ROOT/logs/git.log" || true)"
assert_eq "1" "$MERGE_BASE_CALLS" "trigger resolves the merge base exactly once"
assert_contains "$TRIGGER_GC_LOG" "sling math-experiments/gasvillage.polecat trigger-root --on mol-review-loop-standard" "trigger selects the standard reviewer by default"
assert_contains "$TRIGGER_GC_LOG" "--var work_dir=$TRIGGER_WORK_DIR" "trigger passes work_dir to the review loop"
assert_contains "$TRIGGER_GIT_LOG" "push -u -- review-fork HEAD:$TRIGGER_BRANCH" "trigger pushes to the selected remote"
assert_contains "$TRIGGER_GC_LOG" "--var push_remote=review-fork" "trigger passes the selected remote to review"
assert_contains "$TRIGGER_GC_LOG" "--var branch=$TRIGGER_BRANCH" "trigger passes branch to the review loop"
assert_contains "$TRIGGER_GC_LOG" "--var base_sha=$TRIGGER_BASE_SHA" "trigger passes the immutable base SHA to the review loop"
assert_contains "$TRIGGER_GC_LOG" "--var target=$TRIGGER_BASE_SHA..HEAD" "trigger passes the exact immutable range target"
assert_contains "$TRIGGER_BD_LOG" "set-metadata base_sha=$TRIGGER_BASE_SHA" "trigger records the immutable SHA on the work bead"

GC_SLING_OUTPUT='review loop accepted trigger-root'
: > "$TRIGGER_TEST_ROOT/logs/bd.log"
: > "$TRIGGER_TEST_ROOT/logs/gc.log"
: > "$TRIGGER_TEST_ROOT/logs/git.log"
: > "$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl"
run_trigger_block
assert_eq "0" "$TRIGGER_RC" "successful trigger-review accepts a non-empty sling result"
assert_contains "$(cat "$TRIGGER_OUT")" "$GC_SLING_OUTPUT" \
  "successful trigger-review preserves captured sling output"

# Verify actual argv boundaries and bytes, rather than the ambiguous $* log.
# Commands are data during handoff: neither substitution nor execution is safe.
check_test_command_argv() {
  if python3 - "$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl" <<'PY'
import json, os, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
slings = [argv for argv in calls if argv[0] == "sling"]
assert len(slings) == 1, slings
argv = slings[0]
values = [argv[i + 1] for i, arg in enumerate(argv[:-1]) if arg == "--var"]
assert [v for v in values if v.startswith("test_command=")] == [
    "test_command=" + os.environ["TRIGGER_TEST_COMMAND"]
], values
PY
  then ok "$1"; else fail "$1"; fi
}
check_test_command_argv "trigger forwards the configured short test gate as one argument"

TRIGGER_TEST_COMMAND=$(cat <<'COMMAND'
printf '%s\n' "quoted \"text\" and $HOME" 'single quotes'
$(touch "$TRIGGER_SIDE_EFFECT")
`touch "$TRIGGER_SIDE_EFFECT"`
COMMAND
)
TRIGGER_TEST_COMMAND="$TRIGGER_TEST_COMMAND"$'\n\n'
TRIGGER_SIDE_EFFECT="$TRIGGER_TEST_ROOT/command-was-executed"
export TRIGGER_SIDE_EFFECT
: > "$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl"
run_trigger_block
assert_eq "0" "$TRIGGER_RC" "trigger accepts a multiline test command"
check_test_command_argv "multiline quotes, dollars, backticks and trailing newlines survive unchanged"
if [ ! -e "$TRIGGER_SIDE_EFFECT" ]; then
  ok "trigger does not execute the forwarded test command"
else
  fail "trigger does not execute the forwarded test command"
fi

TRIGGER_TEST_COMMAND=""
: > "$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl"
run_trigger_block
assert_eq "0" "$TRIGGER_RC" "trigger accepts an explicitly empty test command"
check_test_command_argv "empty test command is forwarded explicitly"

GC_SLING_EXIT_CODE=1
GC_SLING_OUTPUT='formulas v2 target dr-4qzeq is closed'
: > "$TRIGGER_TEST_ROOT/logs/bd.log"
: > "$TRIGGER_TEST_ROOT/logs/gc.log"
: > "$TRIGGER_TEST_ROOT/logs/git.log"
: > "$TRIGGER_TEST_ROOT/logs/gc-argv.jsonl"
run_trigger_block
TRIGGER_GC_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/gc.log")"
TRIGGER_BD_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/bd.log")"
assert_eq "1" "$TRIGGER_RC" "trigger-review fails when the review target is closed"
assert_contains "$TRIGGER_GC_LOG" "runtime drain-ack" "failed trigger-review drains after dispatch"
assert_contains "$(cat "$TRIGGER_OUT")" "gc sling failed (exit 1)" "trigger reports the failed review dispatch"
assert_contains "$(cat "$TRIGGER_OUT")" "$GC_SLING_OUTPUT" "trigger preserves the closed-target diagnostic"
assert_not_contains "$TRIGGER_BD_LOG" "gc.outcome=pass" "failed dispatch does not mark trigger-review passed"
assert_not_contains "$TRIGGER_BD_LOG" "--status=closed" "failed dispatch does not close trigger-review"
assert_not_contains "$TRIGGER_BD_LOG" "slung" "failed dispatch does not record a false slung success note"

rm -rf "$TRIGGER_TEST_ROOT"
