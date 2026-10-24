# Test the temporary no-new-failures gate, its fail-closed paths, and strict
# compatibility using real disposable git worktrees and stubbed bead writes.

section "07 apply-fixes test gate modes"
AFX_CITY="" # prior test_04 leaves a deliberately overridden helper in its sandbox

make_runner() {
  local mode="$1" log_file="$2" runner
  runner="$(mktemp "$TMPDIR/test-gate-runner.XXXXXX")"
  cat > "$runner" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$PWD" >> "$log_file"
case "$mode" in
  existing-custom-id)
    printf 'CASE: T_OLD\\n'
    exit 1
    ;;
  existing-plus-new)
    if grep -q '^head$' app.txt; then printf 'FAIL T_OLD\\nFAIL T_NEW\\n'; else printf 'FAIL T_OLD\\n'; fi
    exit 1
    ;;
  baseline-unavailable)
    if [[ "\$PWD" == */review-apply-fixes-base.*/worktree ]]; then
      printf 'baseline runner unavailable\\n' >&2
      exit 127
    fi
    printf 'FAIL T_HEAD\\n'
    exit 1
    ;;
  strict)
    printf 'FAIL T_STRICT\\n'
    exit 1
    ;;
esac
EOF
  chmod +x "$runner"
  printf '%s\n' "$runner"
}

read_root_meta() {
  local root="$1" key="$2"
  jq -Rsc -r --arg root "$root" --arg key "$key" '
    split("\n") | map(select(startswith($root + "\t")) | split("\t")[1] | select(startswith($key + "=")) | sub("^[^=]*="; "")) | .[0] // ""
  ' < "$AFX_META_LOG"
}

# Existing failures on base and fix-head have the same custom identifier. The
# comparison permits the commit, writes root metadata, records the set in the
# apply-fixes note, and removes its temporary base worktree.
AFX_ROOT="root-test-gate-existing"; AFX_VERDICT="pass_with_findings"
AFX_ITERATION=1
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""
AFX_TEST_GATE="no-new-failures"; AFX_TEST_FAILURE_PATTERN='^CASE: (.+)$'
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner existing-custom-id "$run_log")"
AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; git() { if [ "${1:-}" = "-C" ] && [ "${3:-}" = "push" ]; then return 0; fi; command git "$@"; }; review_apply_fixes_commit_and_push "fix: allow existing test failures" || exit $?; review_apply_fixes_set_verdict iterate "existing-only test failure fixture"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "0" "$AFX_RC" "pre-existing-only failures allow the guarded commit"
assert_not_contains "$before" "$after" "allowed pre-existing failures still create the reviewed commit"
assert_eq "fix: allow existing test failures" "$(git -C "$AFX_WORKDIR" log -1 --format=%s)" "commit uses the guarded commit path"
assert_eq '["T_OLD"]' "$(read_root_meta "$AFX_ROOT" gc.review.preexisting_test_failures)" "immutable-base failure identifiers are recorded on the root"
assert_eq "no-new-failures" "$(read_root_meta "$AFX_ROOT" gc.review.test_gate_mode)" "root metadata records the active gate mode"
assert_eq "pass" "$(read_root_meta "$AFX_ROOT" gc.review.test_result)" "pre-existing-only failures count as a passing gate result"
assert_eq "1" "$(read_root_meta "$AFX_ROOT" gc.review.test_attempt)" "the passing result is tied to this attempt"
updates="$(cat "$AFX_UPDATE_LOG")"
assert_contains "$updates" 'pre-existing failures=["T_OLD"]' "apply-fixes note records the pre-existing failure set"
assert_eq "2" "$(wc -l < "$run_log" | tr -d ' ')" "the test command runs once on fix-head and once on the immutable base"
base_pwd="$(sed -n '2p' "$run_log")"
assert_not_contains "$AFX_WORKDIR" "$base_pwd" "baseline command runs outside the review worktree"
assert_eq "removed" "$([ -d "$base_pwd" ] && echo present || echo removed)" "disposable baseline worktree is removed after comparison"

# A new identifier on the fix-head is recorded as a testing finding and stops
# before commit; the old identifier remains documented as pre-existing.
AFX_ROOT="root-test-gate-new-failure"; AFX_VERDICT="pass_with_findings"
AFX_ITERATION=2
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""; AFX_TEST_GATE="no-new-failures"
AFX_TEST_FAILURE_PATTERN=""; AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner existing-plus-new "$run_log")"; AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: reject new test failure"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "10" "$AFX_RC" "new failure returns the recorded-failure status"
assert_eq "$before" "$after" "new failure refuses to create a commit"
assert_eq "fail" "$(read_root_meta "$AFX_ROOT" gc.review.test_result)" "new failures are recorded as a failed gate result"
assert_eq "2" "$(read_root_meta "$AFX_ROOT" gc.review.test_attempt)" "failed test result is associated with attempt two"
assert_eq "2" "$(read_root_meta "$AFX_ROOT" gc.review.test_failure_attempt)" "test finding records the attempt that found it"
assert_eq '["FAIL T_OLD"]' "$(read_root_meta "$AFX_ROOT" gc.review.preexisting_test_failures)" "fallback parser records the base failure line"
assert_contains "$(cat "$AFX_CREATE_LOG")" "new failure identifiers: FAIL T_NEW" "finding explains which failure was introduced"
assert_contains "$(cat "$AFX_META_LOG")" "$AFX_ROOT	gc.review.test_gate_error=" "successful base comparison records no gate error"
assert_contains "$(cat "$AFX_UPDATE_LOG")" 'pre-existing failures=["FAIL T_OLD"]' "iterate note retains known base failures"

# If the base test command cannot complete, the gate fails closed and records
# why it could not compare the runs.
AFX_ROOT="root-test-gate-base-unavailable"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""; AFX_TEST_GATE="no-new-failures"; AFX_TEST_FAILURE_PATTERN=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner baseline-unavailable "$run_log")"; AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_test_before_commit'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "10" "$AFX_RC" "an impossible baseline comparison returns the recorded-failure status"
assert_eq "$before" "$after" "an impossible baseline comparison makes no commit"
assert_eq "null" "$(read_root_meta "$AFX_ROOT" gc.review.preexisting_test_failures)" "unavailable baseline is recorded as an unknown failure set"
assert_contains "$(read_root_meta "$AFX_ROOT" gc.review.test_gate_error)" "baseline test command could not be run" "root metadata explains the unavailable baseline run"
assert_contains "$(cat "$AFX_CREATE_LOG")" "comparison failed closed" "testing finding explains the fail-closed comparison"
base_pwd="$(sed -n '2p' "$run_log")"
assert_eq "removed" "$([ -d "$base_pwd" ] && echo present || echo removed)" "failed baseline worktree is still removed"

# Strict mode retains the previous rule: any non-zero fix-head result blocks
# commit and the test command is not run at the base.
AFX_ROOT="root-test-gate-strict"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""; AFX_TEST_GATE="strict"; AFX_TEST_FAILURE_PATTERN=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner strict "$run_log")"; AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: strict test gate"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "10" "$AFX_RC" "strict mode preserves the existing failing-test status"
assert_eq "$before" "$after" "strict mode refuses to commit any failing test run"
assert_eq "1" "$(wc -l < "$run_log" | tr -d ' ')" "strict mode runs the command only on fix-head"
assert_eq "strict" "$(read_root_meta "$AFX_ROOT" gc.review.test_gate_mode)" "root metadata records strict mode"
assert_contains "$(cat "$AFX_CREATE_LOG")" "strict mode: any non-zero test result blocks" "strict finding preserves the original gate behavior"

# With no explicit environment override, the helper loads per-rig values from
# the durable root formula metadata.
AFX_ROOT="root-test-gate-var-fallback"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR=""; AFX_BASE_SHA=""; AFX_BASE_BRANCH="main"; AFX_TEST_GATE=""; AFX_TEST_FAILURE_PATTERN=""
AFX_ROOT_TEST_GATE="strict"; AFX_ROOT_TEST_FAILURE_PATTERN='^FAIL (.+)$'
AFX_ROOT_TEST_COMMAND=""; AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; printf "GATE=%s\\nPATTERN=%s\\n" "$REVIEW_TEST_GATE" "$REVIEW_TEST_FAILURE_PATTERN"'
assert_contains "$AFX_OUT" "GATE=strict" "test_gate falls back to the rig value recorded on the root"
assert_contains "$AFX_OUT" "PATTERN=^FAIL (.+)$" "failure pattern falls back to the rig value recorded on the root"

# A failed test step records the durable finding and per-attempt result without
# writing the loop verdict or closing itself as an apply-fixes step.
AFX_ROOT="root-test-gate-test-step"; AFX_VERDICT="pass"; AFX_ITERATION=2
AFX_STEP_ID=test; AFX_BEAD_ID="test-phase-bead"
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""; AFX_TEST_GATE="strict"; AFX_TEST_FAILURE_PATTERN=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner strict "$run_log")"; AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
afx_sandbox
afx_run 'review_apply_fixes_load test >/dev/null || exit $?; review_apply_fixes_test_before_commit "$REVIEW_TEST_COMMAND"'
assert_eq "10" "$AFX_RC" "test step returns the expected recorded-failure signal"
assert_eq "fail" "$(read_root_meta "$AFX_ROOT" gc.review.test_result)" "test step records its failed result on the root"
assert_eq "2" "$(read_root_meta "$AFX_ROOT" gc.review.test_attempt)" "test step ties its result to the current attempt"
assert_not_contains "$(cat "$AFX_META_LOG")" 'test-phase-bead	review.verdict=' "test step does not write review.verdict"
assert_not_contains "$(cat "$AFX_UPDATE_LOG")" 'id=test-phase-bead	status=closed' "test step leaves its close to the formula block"
assert_contains "$(cat "$AFX_CREATE_LOG")" "parent=$AFX_ROOT.findings" "test step records the failure under durable findings"

# A commit-time failure on the third regular attempt terminates to the human
# gate instead of spending the one final-verification attempt.
AFX_ROOT="root-test-gate-at-cap"; AFX_VERDICT="pass_with_findings"; AFX_ITERATION=3
AFX_STEP_ID=apply-fixes; AFX_BEAD_ID="apply-fixes-bead"
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_ROOT_TEST_COMMAND=""; AFX_TEST_GATE="strict"; AFX_TEST_FAILURE_PATTERN=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
run_log="$(mktemp)"; runner="$(make_runner strict "$run_log")"; AFX_TEST_COMMAND="$runner"
printf 'head\n' > "$AFX_WORKDIR/app.txt"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_test_before_commit "$REVIEW_TEST_COMMAND"'
assert_eq "10" "$AFX_RC" "third-attempt test failure returns its recorded-failure signal"
assert_contains "$(cat "$AFX_META_LOG")" "$AFX_ROOT	gc.review.loop_outcome=blocked-needs-human" "third-attempt test failure escalates"
assert_contains "$(cat "$AFX_META_LOG")" "$AFX_BEAD_ID	review.verdict=done" "third-attempt test failure stops the loop"
assert_contains "$(cat "$AFX_UPDATE_LOG")" "id=$AFX_BEAD_ID	status=closed" "escalation closes the apply-fixes bead"

# The fallback parser canonicalizes volatile addresses/timings before comparing
# lines, so the same failure remains one identifier across runs.
afx_run 'input_file=$(mktemp); printf "ERROR runner at 0xABCDEF took 12ms\\nERROR runner at 0x123456 took 15ms\\n" > "$input_file"; review_apply_fixes__failure_set "$input_file"; result=$?; rm -f "$input_file"; exit "$result"'
assert_eq "ERROR runner at <ADDR> took <TIME>" "$AFX_OUT" "fallback parser strips memory addresses and timings before deduplication"

unset AFX_ROOT AFX_VERDICT AFX_WORKDIR AFX_BASE_SHA AFX_ALLOWED_PATHS AFX_ROOT_TEST_COMMAND
unset AFX_ROOT_TEST_GATE AFX_ROOT_TEST_FAILURE_PATTERN
unset AFX_TEST_GATE AFX_TEST_FAILURE_PATTERN AFX_TEST_COMMAND AFX_CREATE_LOG AFX_META_LOG AFX_UPDATE_LOG AFX_NUDGE_LOG
unset AFX_ITERATION AFX_STEP_ID AFX_BEAD_ID
