# Exercise real routing writes against the recording store. Recovery must not
# complete the phase: that would advance the old compiled loop before repair.
section "09 autonomous recovery and replanning"

assert_eq recover "$(. "$APPLY_FIXES_SH"; review_apply_fixes_map_verdict blocked no)" \
  "blocked synthesis requests agent recovery"
assert_eq recover "$(. "$APPLY_FIXES_SH"; review_apply_fixes_iteration_action pass running no 1)" \
  "unfinished validation requests recovery rather than a new review"
assert_eq replan "$(. "$APPLY_FIXES_SH"; review_apply_fixes_iteration_action fail pass no 3)" \
  "no progress at the attempt limit requests agent replanning"
assert_eq replan "$(. "$APPLY_FIXES_SH"; review_apply_fixes_iteration_action pass fail no 4)" \
  "failed final verification requests agent replanning"
assert_eq replan "$(. "$APPLY_FIXES_SH"; review_apply_fixes_iteration_action pass pass yes 4)" \
  "a new commit cannot inherit approval from its pre-fix review"

for disposition in recover replan; do
  AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""
  AFX_ROOT="root-$disposition"; AFX_NOTIFY="review-owner"; afx_sandbox
  afx_run "review_apply_fixes_load apply-fixes >/dev/null || exit \$?; review_apply_fixes_$disposition 'repairable failure'"
  assert_eq 0 "$AFX_RC" "$disposition records an agent-owned request"
  meta="$(cat "$AFX_META_LOG")"; updates="$(cat "$AFX_UPDATE_LOG")"
  assert_contains "$meta" "gc.review.loop_outcome=$disposition" "$disposition is durable on the root"
  assert_contains "$meta" "review.verdict=$disposition" "$disposition is visible on the current phase"
  assert_contains "$meta" "gc.failure_class=transient" "$disposition explicitly remains recoverable"
  assert_not_contains "$updates" "status=closed" "$disposition leaves the phase owned and open"
  assert_not_contains "$meta" "gc.outcome=pass" "$disposition never reports success"
  assert_not_contains "$meta" "blocked-needs-human" "$disposition does not ask a human"
  assert_contains "$(cat "$AFX_NUDGE_LOG")" "$disposition" "$disposition wakes the configured agent coordinator"
done

AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_escalate "mktemp not found"'
assert_eq 0 "$AFX_RC" "already-compiled generic escalation remains compatible"
assert_contains "$(cat "$AFX_META_LOG")" "gc.review.loop_outcome=recover" \
  "legacy generic escalation defaults to agent recovery"
assert_not_contains "$(cat "$AFX_UPDATE_LOG")" "status=closed" \
  "legacy callers cannot advance the loop before recovery"

AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_require_human authority "Publishing requires authority outside this task"'
assert_eq 0 "$AFX_RC" "a specific authority question can request a human"
assert_contains "$(cat "$AFX_META_LOG")" "gc.review.loop_outcome=blocked-needs-human" \
  "the human route is reserved for explicit external authority"
assert_contains "$(cat "$AFX_META_LOG")" "gc.review.human_reason_kind=authority" \
  "human requests retain their specific reason category"
assert_not_contains "$(cat "$AFX_UPDATE_LOG")" "status=closed" \
  "a human decision does not trigger retries on the installed engine"

AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_require_human tooling "mktemp not found"'
assert_eq 2 "$AFX_RC" "tooling errors cannot be declared human decisions"
assert_eq "" "$(cat "$AFX_META_LOG")" "invalid human categories write no result"
AFX_NOTIFY=""

# Execute the real first apply-fixes block: the clean early returns must obey
# the same HEAD policy as the final post-fix block.
EARLY_BLOCK="$(formula_py block apply-fixes review_apply_fixes_synthesis_for_attempt)"
EARLY_BLOCK_FILE="$(mktemp)"
printf '%s\n' "$EARLY_BLOCK" > "$EARLY_BLOCK_FILE"
AFX_CITY=""; AFX_WORKDIR="$(afx_git_repo)"; AFX_VERDICT=pass
AFX_TEST_COMMAND=""; AFX_ROOT_TEST_COMMAND=""; AFX_BASE_SHA=""; AFX_ALLOWED_PATHS=""
AFX_FINDINGS_JSON='[]'; AFX_FINDINGS_FILE=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
ORIGINAL_HEAD="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
for state in clean changed dirty missing; do
  if [ "$state" = changed ]; then
    printf 'fix\n' >> "$AFX_WORKDIR/app.txt"
    git -C "$AFX_WORKDIR" commit -qam 'later unreviewed commit'
  fi
  if [ "$state" = dirty ]; then printf 'draft\n' >> "$AFX_WORKDIR/app.txt"; fi
  for attempt in 1 4; do
    AFX_ITERATION="$attempt"; AFX_ROOT="root-early-$state-$attempt"
    AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
    afx_sandbox
    if [ "$state" != missing ]; then
      printf '%s\tgc.review.iteration_start_head=%s\n' "$AFX_ROOT" "$ORIGINAL_HEAD" >> "$AFX_META_LOG"
    fi
    printf '%s\tgc.review.test_attempt=%s\n%s\tgc.review.test_result=pass\n' \
      "$AFX_ROOT" "$attempt" "$AFX_ROOT" >> "$AFX_META_LOG"
    afx_env "${AFX_SHELL:-bash}" "$EARLY_BLOCK_FILE" > "$EARLY_BLOCK_FILE.out" 2>&1
    assert_eq 0 "$?" "$state attempt $attempt records a concrete disposition"
    meta="$(cat "$AFX_META_LOG")"; updates="$(cat "$AFX_UPDATE_LOG")"
    case "$state/$attempt" in
      clean/*) expected=done ;;
      changed/1) expected=iterate ;;
      changed/4) expected=replan ;;
      *) expected=recover ;;
    esac
    assert_contains "$meta" "review.verdict=$expected" "$state attempt $attempt routes to $expected"
    if [ "$expected" != done ]; then
      assert_not_contains "$meta" 'review.verdict=done' "$state attempt $attempt cannot inherit clean approval"
    fi
    if [ "$expected" = recover ] || [ "$expected" = replan ]; then
      assert_not_contains "$updates" 'status=closed' "$state attempt $attempt stays owned and open"
    fi
  done
done
AFX_ITERATION=1
