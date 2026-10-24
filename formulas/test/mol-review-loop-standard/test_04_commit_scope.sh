# Commit gate coverage: tests must pass before commit, commits must be pushed,
# and the default allowlist covers the reviewed diff plus its related tests.

section "04 commit, test, push, and scope gates"

# --- H. a failing test records a testing finding and creates no commit --------
AFX_ROOT="root-test-failure"; AFX_VERDICT="pass_with_findings"; AFX_WORKDIR="$(afx_git_repo)"
AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"
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
