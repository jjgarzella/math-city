# Analyze lifecycle — run the analyze step's verbatim bash end-to-end against a
# stub bd/gc + the REAL shared resolver, and assert it writes the DURABLE inputs
# and records the eligibility verdict the exit criteria call for. The agent-
# reasoned parts (summary text, eligibility judgment) are not deterministic; the
# transport that frames them IS, and that is what this pins.
#
# block 1 signature 'resolve-diff.sh' (unique to step 1); block 3 signature
# 'gc.review.eligible' (unique to step 3).

section "03 analyze lifecycle — durable inputs + recorded metadata"

# --- scenario A: a real range diff -------------------------------------------
repo="$(new_git_repo)"
( cd "$repo"; printf 'package app // v2\n' > app.go; git add app.go; git commit -q -m "change app" )

AB_CITY=""; AB_META_LOG=""; AB_ROOT="root-range"
run_analyze_block 'resolve-diff.sh' "HEAD~1..HEAD" "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on a real range diff"
assert_contains "$AB_OUT" "TARGET_KIND=range" "step 1 reports kind=range"
assert_file_nonempty "$AB_INPUTS/diff" "durable diff written + non-empty"
assert_contains "$(cat "$AB_INPUTS/diff" 2>/dev/null)" "app.go" "durable diff carries the changed file"
[ -f "$AB_INPUTS/files" ] && ok "durable touched-files list written" || fail "durable files list written"
assert_eq "$AB_INPUTS"  "$(meta_val gc.review.inputs_dir)" "root records gc.review.inputs_dir = the durable store"
assert_eq "range"       "$(meta_val gc.review.target_kind)" "root records gc.review.target_kind = range"
assert_eq "$repo"       "$(meta_val work_dir)"             "root records work_dir = the tree under review"

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

# --- scenario C: a path target -> whole-repo audit ---------------------------
repo="$(new_git_repo)"
AB_CITY=""; AB_META_LOG=""; AB_ROOT="root-path"
run_analyze_block 'resolve-diff.sh' "." "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on a path target (whole-repo audit)"
assert_eq "path" "$(meta_val gc.review.target_kind)" "path target -> gc.review.target_kind = path"
assert_contains "$(cat "$AB_INPUTS/diff" 2>/dev/null)" "whole-repo audit" "durable diff marks the whole-repo audit"
rm -rf "$repo"
