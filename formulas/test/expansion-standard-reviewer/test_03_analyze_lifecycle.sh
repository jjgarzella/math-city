# Analyze lifecycle — run the analyze step's verbatim bash end-to-end against a
# stub bd/gc + the REAL shared resolver, and assert it writes the DURABLE inputs
# and records the eligibility verdict the exit criteria call for. The agent-
# reasoned parts (summary text, eligibility judgment) are not deterministic; the
# transport that frames them IS, and that is what this pins.
#
# block 1 signature 'resolve-diff.sh' (unique to step 1); block 3 signature
# 'gc.review.eligible' (unique to step 3).

section "03 analyze lifecycle — durable inputs + per-attempt provenance"

# --- scenario A: a real range diff -------------------------------------------
repo="$(new_git_repo)"
( cd "$repo"; printf 'package app // v2\n' > app.go; git add app.go; git commit -q -m "change app" )

AB_CITY=""; AB_META_LOG=""; AB_PHASE_META_LOG=""; AB_ROOT="root-range"
AB_PHASE_BEAD="analyze-range"; AB_ELIGIBLE="yes"; AB_REASON="eligible: non-trivial change under review"
run_analyze_block 'resolve-diff.sh' "HEAD~1..HEAD" "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on a real range diff"
assert_contains "$AB_OUT" "TARGET_KIND=range" "step 1 reports kind=range"
assert_file_nonempty "$AB_INPUTS/diff" "durable diff written + non-empty"
assert_contains "$(cat "$AB_INPUTS/diff" 2>/dev/null)" "app.go" "durable diff carries the changed file"
[ -f "$AB_INPUTS/files" ] && ok "durable touched-files list written" || fail "durable files list written"
assert_eq "$AB_INPUTS"  "$(meta_val gc.review.inputs_dir)" "root records gc.review.inputs_dir = the durable store"
assert_eq "range"       "$(meta_val gc.review.target_kind)" "root records gc.review.target_kind = range"
assert_eq "$repo"       "$(meta_val work_dir)"             "root records work_dir = the tree under review"
expected_head="$(git -C "$repo" rev-parse HEAD)"
expected_base="$(git -C "$repo" rev-parse 'HEAD~1')"
expected_diff_sha="$(LC_ALL=C shasum -a 256 "$AB_INPUTS/diff" | awk '{print $1}')"
assert_eq "$expected_head" "$(phase_meta_val analyze-range input_head_sha)" \
  "analyze phase records the input HEAD SHA on its own bead"
assert_eq "$expected_base" "$(phase_meta_val analyze-range base_sha)" \
  "analyze phase records the resolved range base SHA on its own bead"
assert_eq "$expected_diff_sha" "$(phase_meta_val analyze-range diff_sha256)" \
  "analyze phase records the durable diff SHA-256 on its own bead"

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
AB_CITY=""; AB_META_LOG=""; AB_PHASE_META_LOG=""; AB_ROOT="root-empty"
AB_PHASE_BEAD="analyze-empty"; AB_ELIGIBLE="no"; AB_REASON="empty diff, nothing to review"
run_analyze_block 'resolve-diff.sh' "" "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on an empty diff"
assert_contains "$AB_OUT" "empty diff" "step 1 reports the empty diff"
assert_eq "empty" "$(meta_val gc.review.target_kind)" "empty diff -> gc.review.target_kind = empty"
[ -f "$AB_INPUTS/diff" ] && [ ! -s "$AB_INPUTS/diff" ] && ok "durable diff is an empty file" \
  || fail "durable diff is an empty file"
run_analyze_block 'gc.review.eligible' "" "$repo"
assert_eq "0" "$AB_RC" "empty-diff eligibility verdict persists successfully"
assert_eq "no" "$(meta_val gc.review.eligible)" "empty diff remains ineligible"
rm -rf "$repo"

# --- scenario C: a path target -> whole-repo audit ---------------------------
repo="$(new_git_repo)"
AB_CITY=""; AB_META_LOG=""; AB_PHASE_META_LOG=""; AB_ROOT="root-path"
AB_PHASE_BEAD="analyze-path"; AB_ELIGIBLE="yes"; AB_REASON="eligible: whole-repo audit"
run_analyze_block 'resolve-diff.sh' "." "$repo"
assert_eq "0" "$AB_RC" "analyze step 1 exits 0 on a path target (whole-repo audit)"
assert_eq "path" "$(meta_val gc.review.target_kind)" "path target -> gc.review.target_kind = path"
assert_contains "$(cat "$AB_INPUTS/diff" 2>/dev/null)" "whole-repo audit" "durable diff marks the whole-repo audit"
run_analyze_block 'gc.review.eligible' "." "$repo"
assert_eq "yes" "$(meta_val gc.review.eligible)" "whole-repo path audit remains eligible"
rm -rf "$repo"

# --- scenario D: changed-head retry with an existing findings container -------
repo="$(new_git_repo)"
( cd "$repo"; git checkout -q -b feature )
( cd "$repo"; printf 'package app\nfunc A() {}\n' > app.go; git add app.go; git commit -q -m "add A" )
AB_CITY=""; AB_META_LOG=""; AB_PHASE_META_LOG=""; AB_ROOT="root-retry"
AB_FINDINGS="$AB_ROOT.findings"; AB_CANDIDATES_FILE="$(mktemp)"
printf '[{"id":"prior-finding","title":"existing finding"}]\n' > "$AB_CANDIDATES_FILE"
AB_PHASE_BEAD="analyze-attempt-1"; AB_ELIGIBLE="yes"; AB_REASON="eligible: changed source"
run_analyze_block 'resolve-diff.sh' "main..HEAD" "$repo"
first_head="$(git -C "$repo" rev-parse HEAD)"
first_diff_sha="$(LC_ALL=C shasum -a 256 "$AB_INPUTS/diff" | awk '{print $1}')"
assert_eq "$first_head" "$(phase_meta_val analyze-attempt-1 input_head_sha)" \
  "first analyze attempt records its own source head"
assert_eq "$first_diff_sha" "$(phase_meta_val analyze-attempt-1 diff_sha256)" \
  "first analyze attempt records its own diff hash"

( cd "$repo"; printf 'package app\nfunc A() {}\nfunc B() {}\n' > app.go; git add app.go; git commit -q -m "add B" )
AB_PHASE_BEAD="analyze-attempt-2"
run_analyze_block 'resolve-diff.sh' "main..HEAD" "$repo"
second_head="$(git -C "$repo" rev-parse HEAD)"
second_diff_sha="$(LC_ALL=C shasum -a 256 "$AB_INPUTS/diff" | awk '{print $1}')"
[ "$first_head" != "$second_head" ] && ok "retry has a changed source head" \
  || fail "retry has a changed source head"
[ "$first_diff_sha" != "$second_diff_sha" ] && ok "retry has changed diff content" \
  || fail "retry has changed diff content"
assert_eq "$second_head" "$(phase_meta_val analyze-attempt-2 input_head_sha)" \
  "retry records the changed source head on its own phase bead"
assert_eq "$second_diff_sha" "$(phase_meta_val analyze-attempt-2 diff_sha256)" \
  "retry records its changed diff hash on its own phase bead"
assert_eq "$(git -C "$repo" rev-parse main)" "$(phase_meta_val analyze-attempt-2 base_sha)" \
  "retry records its base SHA on its own phase bead"

analyze_desc="$(formula_py desc '{target}.analyze')"
assert_contains "$analyze_desc" '`empty` → INELIGIBLE' "empty diffs remain ineligible by rule"
assert_contains "$analyze_desc" "the diff is trivial" "trivial diffs remain ineligible by rule"
assert_contains "$analyze_desc" "Every other nontrivial changed-source attempt is ELIGIBLE" \
  "analysis keeps changed-source retries eligible"
assert_contains "$analyze_desc" "An analyze-only stamp is not proof" \
  "analysis does not treat an earlier analyze stamp as completed review evidence"
assert_not_contains "$analyze_desc" "this exact change has already been reviewed by this formula" \
  "findings-container existence is not an ineligibility rule"

existing="$(cd "$repo" && GC_BEAD_ID="$AB_PHASE_BEAD" BD_ROOT="$AB_ROOT" \
  BD_FINDINGS="$AB_FINDINGS" BD_CANDIDATES_FILE="$AB_CANDIDATES_FILE" \
  PATH="$SUITE_DIR/bin:$PATH" bd show "$AB_FINDINGS")"
existing_rc=$?
assert_eq "0" "$existing_rc" "retry fixture has an existing findings container"

AB_ELIGIBLE="yes"; AB_REASON="eligible: changed-head retry requires a fresh review"
run_analyze_block 'gc.review.eligible' "main..HEAD" "$repo"
assert_eq "0" "$AB_RC" "changed-head retry eligibility verdict persists successfully"
assert_eq "yes" "$(meta_val gc.review.eligible)" \
  "changed-head retry remains eligible with an existing findings container"

LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""
LB_ROOT="$AB_ROOT"; LB_ELIGIBLE="$(meta_val gc.review.eligible)"; LB_TARGET_KIND="range"
LB_REASON="eligible: changed-head retry requires a fresh review"
LB_FINDINGS="$AB_FINDINGS"; LB_CANDIDATES_FILE="$AB_CANDIDATES_FILE"
lane_sandbox
cp -f "$AB_INPUTS/diff" "$LB_INPUTS_DIR/diff"
cp -f "$AB_INPUTS/files" "$LB_INPUTS_DIR/files"
cp -f "$AB_INPUTS/summary.md" "$LB_INPUTS_DIR/summary.md"
existing_lane="$(lane_env bd show "$LB_FINDINGS")"
existing_lane_rc=$?
assert_eq "0" "$existing_lane_rc" "quality lane sees the existing findings container"
run_lane_block quality REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "quality lane starts on the changed-head retry"
assert_contains "$LB_OUT" "[quality] kind=range" "eligible retry reaches the lens review path"
rm -rf "$repo"

# --- scenario E: a non-empty but trivial diff remains ineligible --------------
repo="$(new_git_repo)"
( cd "$repo"; printf 'package app\nfunc A() {}\n' > app.go; git add app.go; git commit -q -m "add app" )
( cd "$repo"; git checkout -q -b feature )
( cd "$repo"; printf 'package app\n// documentation comment\nfunc A() {}\n' > app.go; git add app.go; git commit -q -m "comment only" )
AB_CITY=""; AB_META_LOG=""; AB_PHASE_META_LOG=""; AB_ROOT="root-trivial"
AB_FINDINGS=""; AB_CANDIDATES_FILE=""; AB_PHASE_BEAD="analyze-trivial"
AB_ELIGIBLE="no"; AB_REASON="trivial comment-only diff"
run_analyze_block 'resolve-diff.sh' "main..HEAD" "$repo"
assert_file_nonempty "$AB_INPUTS/diff" "trivial scenario has a non-empty diff"
run_analyze_block 'gc.review.eligible' "main..HEAD" "$repo"
assert_eq "0" "$AB_RC" "trivial-diff eligibility verdict persists successfully"
assert_eq "no" "$(meta_val gc.review.eligible)" "trivial comment-only diff remains ineligible"
rm -rf "$repo"
