# The caller selects a required remote; no destination policy is inferred.
section "06 explicit push remote"

AFX_ROOT="root-explicit-remote"; AFX_VERDICT="pass_with_findings"
AFX_WORKDIR="$(afx_git_repo)"; AFX_BASE_SHA="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
AFX_ALLOWED_PATHS="app.txt"; AFX_TEST_GATE="strict"; AFX_ROOT_TEST_COMMAND=""
AFX_CREATE_LOG="$(mktemp)"; AFX_META_LOG="$(mktemp)"; AFX_UPDATE_LOG="$(mktemp)"; AFX_NUDGE_LOG="$(mktemp)"
remote_test_marker="$AFX_WORKDIR/test-ran"
AFX_TEST_COMMAND="touch '$remote_test_marker'"
printf 'fix\n' > "$AFX_WORKDIR/app.txt"
afx_sandbox

for remote_arg in '' ' ""'; do
  afx_run "review_apply_fixes_commit_and_push 'fix: missing remote'$remote_arg"
  assert_eq "2" "$AFX_RC" "missing or empty remote is rejected"
  assert_contains "$AFX_ERR" "push remote is required" "missing remote has a clear diagnostic"
  assert_eq "$AFX_BASE_SHA" "$(git -C "$AFX_WORKDIR" rev-parse HEAD)" "missing remote creates no commit"
  assert_eq "0" "$(git -C "$AFX_WORKDIR" diff --cached --quiet; echo $?)" "missing remote stages nothing"
  assert_eq "absent" "$([ -e "$remote_test_marker" ] && echo present || echo absent)" "missing remote does not run tests"
done
afx_run 'review_apply_fixes_push_branch'
assert_eq "2" "$AFX_RC" "direct push helper also requires a remote"

origin_repo="$(mktemp -d)"; fork_repo="$(mktemp -d)"
git init --bare -q "$origin_repo"
git init --bare -q "$fork_repo"
git -C "$AFX_WORKDIR" remote add origin "$origin_repo"
git -C "$AFX_WORKDIR" remote add review-fork "$fork_repo"
review_branch="$(git -C "$AFX_WORKDIR" branch --show-current)"
git -C "$AFX_WORKDIR" push -q origin "HEAD:refs/heads/$review_branch"
AFX_TEST_COMMAND=true
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: selected fork" "review-fork"'
assert_eq "0" "$AFX_RC" "commit and push succeeds with an explicitly selected fork"
fork_head="$(git -C "$AFX_WORKDIR" rev-parse HEAD)"
assert_eq "$fork_head" "$(git --git-dir="$fork_repo" rev-parse "refs/heads/$review_branch")" "selected fork receives the fix commit"
assert_eq "$AFX_BASE_SHA" "$(git --git-dir="$origin_repo" rev-parse "refs/heads/$review_branch")" "origin is untouched when another remote is selected"

printf 'another fix\n' > "$AFX_WORKDIR/app.txt"
afx_run 'review_apply_fixes_load apply-fixes >/dev/null || exit $?; review_apply_fixes_commit_and_push "fix: selected origin" "origin"'
assert_eq "0" "$AFX_RC" "caller may explicitly select origin too"
assert_eq "$(git -C "$AFX_WORKDIR" rev-parse HEAD)" "$(git --git-dir="$origin_repo" rev-parse "refs/heads/$review_branch")" "explicit origin selection is honored"
assert_eq "$fork_head" "$(git --git-dir="$fork_repo" rev-parse "refs/heads/$review_branch")" "other remote remains unchanged"

unset AFX_ROOT AFX_VERDICT AFX_WORKDIR AFX_BASE_SHA AFX_ALLOWED_PATHS AFX_TEST_GATE
unset AFX_ROOT_TEST_COMMAND AFX_TEST_COMMAND AFX_CREATE_LOG AFX_META_LOG AFX_UPDATE_LOG AFX_NUDGE_LOG
