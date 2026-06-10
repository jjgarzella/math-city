# Analyze lifecycle — run the analyze step's verbatim bash end-to-end against a
# stub bd/gc + the REAL shared resolver, and assert the triage-specific transport:
# diff resolution + DURABLE inputs + the PATH-TARGET REJECTION (triage reviews
# CHANGES, unlike the standard reviewer's whole-repo audit) + project rule-file
# discovery. The agent-reasoned parts (summary text, eligibility judgment) are not
# deterministic; the transport that frames them IS, and that is what this pins.
#
# step 1 signature 'resolve-diff.sh' (unique to step 1); step 3 signature
# 'gc.review.eligible' (unique to step 3).

section "02 analyze lifecycle — durable inputs, rule discovery, path rejection"

# --- scenario A: a real range diff + a project rule file ----------------------
repo="$(new_git_repo)"
( cd "$repo"
  printf '# Project rules\n\n- Always return errors, never panic\n' > CLAUDE.md
  git add CLAUDE.md; git commit -q -m "add rules"
  printf 'package app // v2\n' > app.go; git add app.go; git commit -q -m "change app" )

AB_CITY=""; AB_META_LOG=""; AB_ROOT="root-range"
run_analyze_block 'resolve-diff.sh' "HEAD~1..HEAD" "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on a real range diff"
assert_contains "$AB_OUT" "TARGET_KIND=range" "step 1 reports kind=range"
assert_file_nonempty "$AB_INPUTS/diff" "durable diff written + non-empty"
assert_contains "$(cat "$AB_INPUTS/diff" 2>/dev/null)" "app.go" "durable diff carries the changed file"
[ -f "$AB_INPUTS/files" ] && ok "durable touched-files list written" || fail "durable files list written"
assert_eq "$AB_INPUTS" "$(meta_val gc.review.inputs_dir)" "root records gc.review.inputs_dir = the durable store"
assert_eq "range"      "$(meta_val gc.review.target_kind)" "root records gc.review.target_kind = range"
assert_eq "$repo"      "$(meta_val work_dir)"             "root records work_dir = the tree under review"

# triage-specific: project rule-file discovery into durable inputs
[ -f "$AB_INPUTS/rule-files" ] && ok "durable rule-files path list written" || fail "rule-files list written"
[ -f "$AB_INPUTS/rules.md" ]   && ok "durable rules.md (line-numbered contents) written" || fail "rules.md written"
assert_contains "$(cat "$AB_INPUTS/rule-files" 2>/dev/null)" "CLAUDE.md" "rule-file discovery found the project CLAUDE.md"
assert_contains "$(cat "$AB_INPUTS/rules.md" 2>/dev/null)" "RULE FILE: CLAUDE.md" "rules.md carries the rule-file header"
assert_contains "$(cat "$AB_INPUTS/rules.md" 2>/dev/null)" "never panic" "rules.md carries the rule contents"

# step 3 reuses the same sandbox: writes the summary + eligibility verdict.
run_analyze_block 'gc.review.eligible' "HEAD~1..HEAD" "$repo"
assert_eq "0" "$AB_RC" "analyze step 3 exits 0"
[ -f "$AB_INPUTS/summary.md" ] && ok "durable change summary written" || fail "durable summary written"
assert_eq "yes" "$(meta_val gc.review.eligible)" "root records gc.review.eligible (default yes)"
[ -n "$(meta_val gc.review.eligibility_reason)" ] && ok "root records a gc.review.eligibility_reason" \
  || fail "root records eligibility_reason"
rm -rf "$repo"

# --- scenario B: an empty diff -> TARGET_KIND=empty --------------------------
repo="$(new_git_repo)"   # HEAD == base, default target "" -> empty
AB_CITY=""; AB_META_LOG=""; AB_ROOT="root-empty"
run_analyze_block 'resolve-diff.sh' "" "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on an empty diff"
assert_contains "$AB_OUT" "empty diff" "step 1 reports the empty diff"
assert_eq "empty" "$(meta_val gc.review.target_kind)" "empty diff -> gc.review.target_kind = empty"
[ -f "$AB_INPUTS/diff" ] && [ ! -s "$AB_INPUTS/diff" ] && ok "durable diff is an empty file" \
  || fail "durable diff is an empty file"
rm -rf "$repo"

# --- scenario C: a path target is REJECTED (triage reviews CHANGES) -----------
# This is the key triage-vs-standard difference: the standard reviewer treats a
# path target as a whole-repo audit; triage hard-errors and points at mol-standard-review.
repo="$(new_git_repo)"
AB_CITY=""; AB_META_LOG=""; AB_ROOT="root-path"
run_analyze_block 'resolve-diff.sh' "." "$repo"
assert_eq "2" "$AB_RC" "analyze step 1 exits 2 on a path target (triage rejects whole-tree)"
assert_contains "$AB_OUT" "triage reviews CHANGES" "the rejection explains triage reviews changes, not a path"
assert_contains "$AB_OUT" "mol-standard-review" "the rejection points at mol-standard-review for a whole-repo audit"
rm -rf "$repo"
