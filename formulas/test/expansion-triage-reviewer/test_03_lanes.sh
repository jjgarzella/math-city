# Lane transport — run each lens' verbatim STEP-1 block (load durable inputs ->
# eligibility gate -> for the repo-dependent angles, resume work_dir / self-skip)
# against the shared review-lane.sh + a stub bd/gc, and pin the STEP-3 filing
# block structurally (each lens files under its OWN category; the real-bug lenses
# carry the verbatim Anthropic false-positive list). The lens REASONING is the
# agent's and is not deterministic; the transport that frames it IS.
#
# The shared lib/review-lane.sh itself (load_inputs / file_finding / close) is
# tested by the expansion-standard-reviewer suite; this does not re-test it.
#
# step-1 signature 'REVIEW_ELIGIBLE' (the eligibility gate, unique to step 1).

section "03 lane transport — gate, repo-dependent self-skip, per-lens category"

LENSES="rule-adherence bug-scan git-history prior-prs in-code-invariants"

# --- A. durable-input lens (bug-scan), eligible: step 1 loads, does NOT close --
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-bs-elig"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
run_lane_block bug-scan REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "bug-scan step 1 exits 0 on an eligible change"
assert_contains "$LB_OUT" "[bug-scan] kind=range" "eligible: step 1 reports the target kind + durable inputs"
update_log_has "status=closed" && fail "eligible: step 1 does not close (review + filing come next)" \
  || ok "eligible: step 1 does not close (review + filing come next)"
[ -s "$LB_CREATE_LOG" ] && fail "eligible: step 1 files no findings on its own" \
  || ok "eligible: step 1 files no findings on its own"

# --- B. durable-input lens (rule-adherence), ineligible: self-skip clean -------
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-ra-inelig"; LB_ELIGIBLE="no"; LB_TARGET_KIND="empty"
LB_REASON="empty diff, nothing to review"
lane_sandbox
run_lane_block rule-adherence REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "rule-adherence step 1 exits 0 on an ineligible change (clean no-op)"
update_log_has "status=closed" && ok "ineligible: step 1 closes the lane pass" \
  || fail "ineligible: step 1 closes the lane pass"
update_log_has "ineligible" && ok "ineligible: the close note records the skip reason" \
  || fail "ineligible: the close note records the skip reason"
[ -s "$LB_CREATE_LOG" ] && fail "ineligible: no findings filed" || ok "ineligible: no findings filed"

# --- C. git-history (repo-dependent): self-skips clean when work_dir is not git -
# LB_WORKDIR defaults to a non-git temp dir, so the git rev-parse guard fails.
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-gh-nogit"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
run_lane_block git-history REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "git-history step 1 exits 0 when work_dir has no git (best-effort)"
update_log_has "status=closed" && ok "git-history self-skips to a clean pass without git access" \
  || fail "git-history self-skips clean without git"
update_log_has "no git work_dir" && ok "git-history close note records the no-git skip" \
  || fail "git-history close note records the no-git skip"
[ -s "$LB_CREATE_LOG" ] && fail "git-history files nothing when self-skipped" || ok "git-history files nothing when self-skipped"

# --- D. prior-prs (repo-dependent, best-effort): self-skips when no PR context -
# The stub gh errors on `gh repo view`, so the PR-context guard fails -> skip.
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-pp-noctx"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
run_lane_block prior-prs REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "prior-prs step 1 exits 0 with no PR context (best-effort)"
update_log_has "status=closed" && ok "prior-prs self-skips to a clean pass with no PR context" \
  || fail "prior-prs self-skips clean with no PR context"
update_log_has "no PR context" && ok "prior-prs close note records the no-PR-context skip" \
  || fail "prior-prs close note records the no-PR-context skip"

# --- E. in-code-invariants (diff-or-repo): step 1 loads, does NOT close --------
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-ici-elig"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
run_lane_block in-code-invariants REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "in-code-invariants step 1 exits 0 on an eligible change"
assert_contains "$LB_OUT" "[in-code-invariants] kind=range" "in-code-invariants step 1 reports the target kind"
update_log_has "status=closed" && fail "in-code-invariants step 1 does not close (review comes next)" \
  || ok "in-code-invariants step 1 does not close (review comes next)"

# --- F. structural: each lens files under its OWN category (step-3 block) ------
for lens in $LENSES; do
  desc="$(formula_py desc "{target}.$lens")"
  assert_contains "$desc" "review_lane_file_finding $lens " "$lens files candidates under category:$lens"
  assert_contains "$desc" "category:$lens" "$lens exit criteria name its category label"
done

# --- G. structural: EVERY lens carries the VERBATIM Anthropic FP list ----------
# Each lane is a separate session with no shared context, so each must carry the
# discipline in its own prompt — a reference to "the other lenses" would be unseen.
FP_LINE="Pedantic nitpicks that a senior engineer wouldn't call out"
for lens in $LENSES; do
  assert_contains "$(formula_py desc "{target}.$lens")" "$FP_LINE" \
    "$lens hands the agent the verbatim Anthropic false-positive list (self-contained)"
done
