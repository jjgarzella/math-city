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

TRIGGER_BLOCK="$(formula_py block trigger-review 'gc sling')"
TRIGGER_BLOCK="$(printf '%s' "$TRIGGER_BLOCK" | \
  TRIGGER_FORMULA_VALUE=mol-review-loop-standard \
  TRIGGER_WORKER_VALUE=gasvillage.polecat \
  TRIGGER_BASE_BRANCH_VALUE=review-loop-repair \
  TRIGGER_PUSH_REMOTE_VALUE=review-fork \
  python3 -c 'import os,sys; s=sys.stdin.read();
for key, env in (("review_formula","TRIGGER_FORMULA_VALUE"),("review_worker_target","TRIGGER_WORKER_VALUE"),("base_branch","TRIGGER_BASE_BRANCH_VALUE"),("push_remote","TRIGGER_PUSH_REMOTE_VALUE")):
    s=s.replace("{{"+key+"}}", os.environ[env])
sys.stdout.write(s)')"
TRIGGER_OUT="$TRIGGER_TEST_ROOT/output"
if (
  cd "$TRIGGER_TEST_ROOT/worktree" && \
  env PATH="$TRIGGER_TEST_ROOT/bin:$PATH" \
    GC_BEAD_ID=trigger-step GC_AGENT=trigger-test GC_RIG=math-experiments \
    BD_ROOT_ID="$TRIGGER_ROOT" BD_WORK_DIR="$TRIGGER_WORK_DIR" \
    BD_BRANCH="$TRIGGER_BRANCH" BD_BASE_REF=origin/review-loop-repair \
    BD_LOG="$TRIGGER_TEST_ROOT/logs/bd.log" \
    GC_LOG="$TRIGGER_TEST_ROOT/logs/gc.log" \
    GIT_LOG="$TRIGGER_TEST_ROOT/logs/git.log" \
    TRIGGER_BASE_SHA="$TRIGGER_BASE_SHA" bash -c "$TRIGGER_BLOCK"
) > "$TRIGGER_OUT" 2>&1; then
  TRIGGER_RC=0
else
  TRIGGER_RC=$?
fi
TRIGGER_GC_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/gc.log")"
TRIGGER_GIT_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/git.log")"
TRIGGER_BD_LOG="$(cat "$TRIGGER_TEST_ROOT/logs/bd.log")"

assert_eq "0" "$TRIGGER_RC" "trigger-review completes with a valid worktree context"
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

rm -rf "$TRIGGER_TEST_ROOT"
