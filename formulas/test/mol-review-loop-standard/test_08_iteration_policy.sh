# Per-attempt convergence and finite verification budget. The policy is pure so
# the terminal cases can be pinned without a live beads store or model run.

section "08 per-attempt test gate and finite verification policy"

action() {
  . "$APPLY_FIXES_SH"
  review_apply_fixes_iteration_action "$1" "$2" "$3" "$4"
}

effective_synthesis() {
  . "$APPLY_FIXES_SH"
  review_apply_fixes_synthesis_for_attempt "$1" "$2" "$3" "$4"
}

assert_eq "done" "$(action pass pass no 1)" \
  "regular attempt converges only when synthesis and the test gate pass"
assert_eq "iterate" "$(action pass fail no 1)" \
  "a test failure blocks convergence even when synthesis is clean"
assert_eq "iterate" "$(action pass_with_findings pass no 1)" \
  "actionable findings cannot converge without a fix"
assert_eq "iterate" "$(action pass pass yes 1)" \
  "a commit after a clean pre-fix review still needs a fresh review"
assert_eq "iterate" "$(action pass_with_findings pass yes 2)" \
  "a regular attempt with fixes re-reviews"
assert_eq "done" "$(action pass pass no 3)" \
  "the third regular attempt may converge cleanly"
assert_eq "iterate" "$(action pass pass yes 3)" \
  "a third-attempt commit always gets the one verification pass"
assert_eq "iterate" "$(action pass_with_findings pass yes 3)" \
  "a fix committed on the third regular attempt gets one verification"
assert_eq "replan" "$(action pass_with_findings pass no 3)" \
  "unresolved work without a third-attempt commit requests agent replanning"
assert_eq "replan" "$(action pass fail yes 3)" \
  "a failed test gate on the third regular attempt cannot spend verification budget"

assert_eq "done" "$(action pass pass no 4)" \
  "the one final verification converges on synthesis pass plus test pass"
assert_eq "replan" "$(action pass_with_findings pass yes 4)" \
  "actionable findings in verification request agent replanning, even after a fix"
assert_eq "replan" "$(action pass fail no 4)" \
  "test failures in verification request agent replanning"
assert_not_contains "$(action pass_with_findings pass yes 5)" "iterate" \
  "attempt five can never start another verification loop"

assert_eq "pass_with_findings" "$(effective_synthesis pass fail '' 1)" \
  "a test failure after a clean review becomes actionable work"
assert_eq "pass_with_findings" "$(effective_synthesis pass pass 2 2)" \
  "fixes after a same-attempt test failure require a fresh review"
assert_eq "pass" "$(effective_synthesis pass pass 1 2)" \
  "a prior-attempt test failure does not prevent later clean convergence"
