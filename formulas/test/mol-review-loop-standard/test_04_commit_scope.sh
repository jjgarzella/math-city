# Commit gate coverage: tests must pass before commit, commits must be pushed,
# and the default allowlist covers the reviewed diff plus its related tests.

section "04 commit, test, push, and scope gates"

# --- H. a failing test records a testing finding and creates no commit --------
AFX_ROOT="root-test-failure"; AFX_VERDICT="pass_with_findings"; AFX_WORKDIR="$(afx_git_repo)"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"
AFX_TEST_GATE="strict" # this legacy case pins the original any-nonzero-fails behavior
AFX_TEST_COMMAND='printf "fixture failing output\n"; exit 42'
AFX_ROOT_TEST_COMMAND=""
AFX_CREATE_LOG="$(mktemp)"
AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
printf 'fixed source\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: guarded commit"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "10" "$AFX_RC" "failed test gate returns its recorded-failure status"
assert_eq "$before" "$after" "failed tests do not create a commit"
assert_eq "0" "$(git -C "$AFX_WORKDIR" diff --cached --quiet; echo $?)" "failed tests do not stage files"
created="$(cat "$AFX_CREATE_LOG")"
assert_contains "$created" "parent=root-test-failure.findings" "failed test is recorded under the review findings container"
assert_contains "$created" "severity:major,category:testing" "failed test is labeled as a testing finding"
assert_contains "$created" "fixture failing output" "finding preserves the test failure output"
meta="$(cat "$AFX_META_LOG")"; updates="$(cat "$AFX_UPDATE_LOG")"
assert_contains "$meta" "apply-fixes-bead	review.verdict=iterate" "failed tests write review.verdict=iterate"
assert_contains "$updates" "status=closed" "test-failure path closes the apply-fixes bead"
assert_contains "$AFX_ERR" "refusing to commit" "failed test emits a commit refusal"
unset AFX_TEST_GATE

# --- I. commit succeeds locally, then a failed push is returned loudly -------
AFX_ROOT="root-push-failure"; AFX_VERDICT="pass_with_findings"; AFX_WORKDIR="$(afx_git_repo)"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_TEST_COMMAND=""; AFX_ROOT_TEST_COMMAND="true"; AFX_CREATE_LOG="$(mktemp)"
AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
printf 'fixed source\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'push_calls=0; git() { if [ "${1:-}" = "-C" ] && [ "${3:-}" = "push" ]; then push_calls=$((push_calls + 1)); if [ "$push_calls" -eq 1 ]; then echo "simulated push failure" >&2; return 23; fi; echo "simulated push retry success"; return 0; fi; command git "$@"; }; review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: push failure fixture"; first=$?; review_apply_fixes_commit_and_push "fix: push failure fixture"; second=$?; printf "FIRST=%s SECOND=%s\n" "$first" "$second"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "0" "$AFX_RC" "push retry after a failure succeeds without a second commit"
assert_contains "$AFX_OUT" "FIRST=1 SECOND=0" "failed push is reported and an idempotent retry succeeds"
assert_not_contains "$before" "$after" "commit is created before the push is attempted"
assert_eq "fix: push failure fixture" "$(git -C "$AFX_WORKDIR" log -1 --format=%s)" "successful local commit remains after push failure"
assert_contains "$AFX_ERR" "simulated push failure" "remote failure detail is visible"
assert_contains "$AFX_ERR" "failed to push review branch" "push failure is reported clearly"

# --- J. test-generated out-of-scope files are caught before git add ------------
AFX_ROOT="root-test-scope"; AFX_VERDICT="pass_with_findings"; AFX_WORKDIR="$(afx_git_repo)"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_TEST_COMMAND='printf "generated\n" > unrelated.txt'; AFX_ROOT_TEST_COMMAND=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
printf 'fixed source\n' > "$AFX_WORKDIR/app.txt"
before="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: test scope fixture"'
after="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "3" "$AFX_RC" "test-generated out-of-scope edit is refused before commit"
assert_eq "$before" "$after" "out-of-scope test artifact does not create a commit"
assert_contains "$AFX_ERR" "out-of-scope edit refused: unrelated.txt" "post-test scope check reports the generated path"

# --- K. default allowlist includes reviewed files + related tests, rejects rest
AFX_ROOT="root-scope"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mrls-scope.XXXXXX")"
git -C "$AFX_WORKDIR" init -q
git -C "$AFX_WORKDIR" config user.name "Review Apply Fixes Test"
git -C "$AFX_WORKDIR" config user.email "review-apply-fixes@example.invalid"
mkdir -p "$AFX_WORKDIR/formulas/lib" "$AFX_WORKDIR/formulas/test/mol-review-loop-standard"
printf 'base formula\n' > "$AFX_WORKDIR/formulas/mol-review-loop-standard.toml"
printf 'base helper\n' > "$AFX_WORKDIR/formulas/lib/review-apply-fixes.sh"
printf 'uses review-apply-fixes.sh\n' > "$AFX_WORKDIR/formulas/test/mol-review-loop-standard/test_02_apply_fixes_lib.sh"
git -C "$AFX_WORKDIR" add formulas
git -C "$AFX_WORKDIR" commit -q -m "scope base"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
printf 'reviewed formula change\n' >> "$AFX_WORKDIR/formulas/mol-review-loop-standard.toml"
printf 'reviewed helper change\n' >> "$AFX_WORKDIR/formulas/lib/review-apply-fixes.sh"
git -C "$AFX_WORKDIR" add formulas
git -C "$AFX_WORKDIR" commit -q -m "reviewed changes"
printf 'new related test\n' > "$AFX_WORKDIR/formulas/test/mol-review-loop-standard/test_new.sh"
AFX_ALLOWED_PATHS=""; AFX_TEST_COMMAND=""; AFX_ROOT_TEST_COMMAND=""; AFX_CREATE_LOG="$(mktemp)"
AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_allowed_paths'
assert_eq "0" "$AFX_RC" "default allowlist is derived from the reviewed diff"
assert_contains "$AFX_OUT" "formulas/mol-review-loop-standard.toml" "default allowlist includes the reviewed formula"
assert_contains "$AFX_OUT" "formulas/lib/review-apply-fixes.sh" "default allowlist includes the reviewed helper"
assert_contains "$AFX_OUT" "formulas/test/mol-review-loop-standard/" "default allowlist includes the formula test suite"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "0" "$AFX_RC" "new test under the related suite is allowed"
printf 'out of scope\n' > "$AFX_WORKDIR/unrelated.txt"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "3" "$AFX_RC" "out-of-scope edit is refused"
assert_contains "$AFX_ERR" "out-of-scope edit refused: unrelated.txt" "scope refusal identifies the unauthorized path"

# --- L. default allowlist includes only existing top-level test trees ----------
section "05 top-level test tree allowlists"

# Julia-style rigs keep package tests under test/.
AFX_ROOT="root-julia-test-tree"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mrls-julia-scope.XXXXXX")"
git -C "$AFX_WORKDIR" init -q
git -C "$AFX_WORKDIR" config user.name "Review Apply Fixes Test"
git -C "$AFX_WORKDIR" config user.email "review-apply-fixes@example.invalid"
mkdir -p "$AFX_WORKDIR/src" "$AFX_WORKDIR/scripts" "$AFX_WORKDIR/test"
printf 'module Foo\nend\n' > "$AFX_WORKDIR/src/Foo.jl"
printf 'println(:runner)\n' > "$AFX_WORKDIR/scripts/x.jl"
printf '@test true\n' > "$AFX_WORKDIR/test/test_existing.jl"
git -C "$AFX_WORKDIR" add src scripts test
git -C "$AFX_WORKDIR" commit -q -m "Julia base"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
printf '# reviewed Foo change\n' >> "$AFX_WORKDIR/src/Foo.jl"
printf '# reviewed script change\n' >> "$AFX_WORKDIR/scripts/x.jl"
git -C "$AFX_WORKDIR" add src scripts
git -C "$AFX_WORKDIR" commit -q -m "reviewed Julia sources"
printf '@test true\n' > "$AFX_WORKDIR/test/test_foo.jl"
AFX_ALLOWED_PATHS=""; AFX_TEST_COMMAND=""; AFX_ROOT_TEST_COMMAND=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_allowed_paths'
assert_eq "0" "$AFX_RC" "Julia-style default allowlist resolves"
assert_contains "$AFX_OUT" "test/" "Julia-style reviewed src/scripts files allow the existing test/ tree"
assert_not_contains "$AFX_OUT" "src/Bar.jl" "Julia-style allowlist does not add unreviewed source files"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "0" "$AFX_RC" "new Julia test under test/ is allowed"
printf 'unreviewed source\n' > "$AFX_WORKDIR/src/Bar.jl"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "3" "$AFX_RC" "unreviewed Julia source remains outside scope"
assert_contains "$AFX_ERR" "out-of-scope edit refused: src/Bar.jl" "Julia source refusal names the path"

# Python-style rigs keep package tests under tests/.
AFX_ROOT="root-python-test-tree"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mrls-python-scope.XXXXXX")"
git -C "$AFX_WORKDIR" init -q
git -C "$AFX_WORKDIR" config user.name "Review Apply Fixes Test"
git -C "$AFX_WORKDIR" config user.email "review-apply-fixes@example.invalid"
mkdir -p "$AFX_WORKDIR/tests"
printf 'def app(): return 1\n' > "$AFX_WORKDIR/app.py"
printf 'def test_existing(): assert True\n' > "$AFX_WORKDIR/tests/test_existing.py"
git -C "$AFX_WORKDIR" add app.py tests
git -C "$AFX_WORKDIR" commit -q -m "Python base"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
printf '# reviewed app change\n' >> "$AFX_WORKDIR/app.py"
git -C "$AFX_WORKDIR" add app.py
git -C "$AFX_WORKDIR" commit -q -m "reviewed Python source"
printf 'def test_app(): assert True\n' > "$AFX_WORKDIR/tests/test_app.py"
AFX_ALLOWED_PATHS=""; AFX_TEST_COMMAND=""; AFX_ROOT_TEST_COMMAND=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_allowed_paths'
assert_eq "0" "$AFX_RC" "Python-style default allowlist resolves"
assert_contains "$AFX_OUT" "tests/" "Python-style reviewed source allows the existing tests/ tree"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "0" "$AFX_RC" "new Python test under tests/ is allowed"
printf 'unreviewed source\n' > "$AFX_WORKDIR/other.py"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_check_allowed_paths'
assert_eq "3" "$AFX_RC" "unreviewed Python source remains outside scope"
assert_contains "$AFX_ERR" "out-of-scope edit refused: other.py" "Python source refusal names the path"

# --- M. the apply-fixes body escalates helper statuses 2/3 and keeps 10 --------
section "06 apply-fixes commit error escalation"
COMMIT_BLOCK="$(formula_py block apply-fixes review_apply_fixes_commit_and_push)"
COMMIT_BLOCK_FILE="$(mktemp)"
printf '%s\n' "$COMMIT_BLOCK" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read().replace("{{test_command}}", "").replace("{{allowed_paths}}", ""))' > "$COMMIT_BLOCK_FILE"
AFX_CITY=""; AFX_ROOT="root-commit-error-seed"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR=""; AFX_BASE_SHA=""; AFX_TEST_COMMAND=""; AFX_ALLOWED_PATHS=""; AFX_ROOT_TEST_COMMAND=""
AFX_FINDINGS_JSON='[]'; AFX_FINDINGS_FILE=""; AFX_CREATE_LOG="$(mktemp)"
AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
afx_sandbox
cat >> "$AFX_CITY/formulas/lib/review-apply-fixes.sh" <<'OVERRIDE'
review_apply_fixes_commit_and_push() {
  printf '%s\n' "$MOCK_COMMIT_DIAGNOSTIC" >&2
  return "$MOCK_COMMIT_STATUS"
}
OVERRIDE

for commit_status in 2 3 10; do
  AFX_ROOT="root-commit-error-$commit_status"; AFX_VERDICT="pass_with_findings"
  AFX_WORKDIR=""; AFX_BASE_SHA=""; AFX_TEST_COMMAND=""; AFX_ALLOWED_PATHS=""; AFX_ROOT_TEST_COMMAND=""
  AFX_FINDINGS_JSON='[]'; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
  afx_sandbox
  if [ "$commit_status" -eq 3 ]; then
    MOCK_COMMIT_DIAGNOSTIC="ERROR: out-of-scope edit refused: src/Bar.jl"
  elif [ "$commit_status" -eq 2 ]; then
    MOCK_COMMIT_DIAGNOSTIC="ERROR: cannot inspect changed paths: git diff failed"
  else
    MOCK_COMMIT_DIAGNOSTIC="ERROR: test command failed; finding recorded"
  fi
  MOCK_COMMIT_STATUS="$commit_status"
  export MOCK_COMMIT_STATUS MOCK_COMMIT_DIAGNOSTIC
  commit_out_file="$(mktemp)"; commit_err_file="$(mktemp)"
  afx_env bash "$COMMIT_BLOCK_FILE" > "$commit_out_file" 2> "$commit_err_file"
  block_status=$?
  commit_out="$(cat "$commit_out_file")"; commit_err="$(cat "$commit_err_file")"
  rm -f "$commit_out_file" "$commit_err_file"
  assert_eq "0" "$block_status" "apply-fixes handles commit status $commit_status without escaping nonzero"
  if [ "$commit_status" -eq 10 ]; then
    assert_contains "$commit_out" "test failure recorded as a finding" "status 10 keeps the test-failure terminal message"
    assert_not_contains "$(cat "$AFX_META_LOG")" "gc.review.loop_outcome" "status 10 does not escalate to human"
  else
    meta="$(cat "$AFX_META_LOG")"; updates="$(cat "$AFX_UPDATE_LOG")"
    assert_contains "$meta" "$AFX_ROOT	gc.review.loop_outcome=blocked-needs-human" "status $commit_status records blocked-needs-human on the root"
    assert_contains "$meta" "gc.review.loop_blocked_reason=" "status $commit_status records a blocked reason"
    assert_contains "$meta" "$MOCK_COMMIT_DIAGNOSTIC" "status $commit_status preserves the scope or inspection diagnostic"
    assert_contains "$meta" "apply-fixes-bead	review.verdict=done" "status $commit_status stops the review loop"
    assert_contains "$updates" "status=closed" "status $commit_status closes the apply-fixes bead"
    assert_contains "$commit_err" "TERMINATE-TO-HUMAN" "status $commit_status emits a human escalation"
  fi
done
rm -f "$COMMIT_BLOCK_FILE"
