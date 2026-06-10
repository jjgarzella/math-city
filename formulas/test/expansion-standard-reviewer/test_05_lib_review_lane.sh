# Review-lane lib + lane transport — the shared formulas/lib/review-lane.sh is
# the single source of truth for the six lenses' repeated transport (load durable
# inputs → gate on eligibility → file a category-labelled wisp → close). The lens
# REASONING is the agent's and is not deterministic; the transport that frames it
# IS, and that is what this pins — directly (the lib functions) and end-to-end
# (running a lane's verbatim eligibility-gate block against a real durable-input
# store + the stub bd).
#
# bd is stubbed (bin/bd): it returns the analyze pass's gc.review.* handles for
# `bd show <root>`, and records every `bd create` / `bd update` so we can assert
# what a lane wrote. No live Dolt, no live controller.

section "05 review-lane lib + lane transport"

[ -f "$LANE_LIB" ] && ok "shared lane lib present at formulas/lib/review-lane.sh" \
  || fail "shared lane lib present" "missing $LANE_LIB"

# --- A. lib: review_lane_load_inputs resolves the durable inputs --------------
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-load"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
LB_REASON="eligible: non-trivial change"
lane_sandbox
loaded="$(lane_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-lane.sh"
  review_lane_load_inputs >/dev/null
  echo "ROOT=$REVIEW_ROOT"
  echo "KIND=$REVIEW_TARGET_KIND"
  echo "ELIGIBLE=$REVIEW_ELIGIBLE"
  echo "REASON=$REVIEW_ELIGIBILITY_REASON"
  echo "FINDINGS=$REVIEW_FINDINGS"
  [ "$REVIEW_DIFF" = "$REVIEW_INPUTS_DIR/diff" ] && echo "DIFF_PATH_OK=yes"
  [ -f "$REVIEW_DIFF" ] && echo "DIFF_EXISTS=yes"
  [ -f "$REVIEW_SUMMARY" ] && echo "SUMMARY_EXISTS=yes"
')"
assert_contains "$loaded" "ROOT=$LB_ROOT"                "load_inputs resolves the molecule root from gc.root_bead_id"
assert_contains "$loaded" "KIND=range"                   "load_inputs reads gc.review.target_kind"
assert_contains "$loaded" "ELIGIBLE=yes"                 "load_inputs reads gc.review.eligible"
assert_contains "$loaded" "REASON=eligible: non-trivial change" "load_inputs reads gc.review.eligibility_reason"
assert_contains "$loaded" "FINDINGS=$LB_ROOT.findings"   "load_inputs derives the findings container id (<root>.findings)"
assert_contains "$loaded" "DIFF_PATH_OK=yes"             "load_inputs points REVIEW_DIFF at the durable diff"
assert_contains "$loaded" "DIFF_EXISTS=yes"              "the durable diff is readable"
assert_contains "$loaded" "SUMMARY_EXISTS=yes"           "the durable summary is readable"

# --- B. lib: review_lane_file_finding files a category-labelled wisp ----------
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-file"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
filed="$(lane_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-lane.sh"
  review_lane_load_inputs >/dev/null
  BODY=$(mktemp)
  printf "%s\n\n%s\n" "app.go:10 — swallowed error" "Evidence: + _ = doThing()" > "$BODY"
  review_lane_file_finding quality 80 2 "swallowed error in Added()" "$BODY"
  review_lane_close "quality: filed 1 candidate finding (category:quality)"
')"
# The findings container is created once under the root (idempotent, ephemeral=no).
container_line="$(grep 'ephemeral=no' "$LB_CREATE_LOG" | head -1)"
assert_contains "$container_line" "id=$LB_ROOT.findings" "file_finding creates the findings container <root>.findings"
assert_contains "$container_line" "parent=$LB_ROOT"      "the findings container is parented to the molecule root"
# The candidate is an ephemeral wisp: category label + Confidence self-rating first line.
wisp_line="$(grep 'ephemeral=yes' "$LB_CREATE_LOG" | head -1)"
assert_contains "$wisp_line" "labels=category:quality"   "the candidate wisp carries a category:<lens> label"
assert_contains "$wisp_line" "body1=Confidence: 80/100"  "the wisp's first body line is the Confidence self-rating"
assert_contains "$wisp_line" "ephemeral=yes"             "the candidate is filed as an ephemeral wisp"
# review_lane_close closes the lane bead pass.
assert_contains "$(cat "$LB_UPDATE_LOG")" "status=closed" "review_lane_close closes the lane bead (status=closed)"

# --- C. lane (eligible): step 1 loads + does NOT close (review happens next) ---
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-q-elig"; LB_ELIGIBLE="yes"; LB_TARGET_KIND="range"
lane_sandbox
run_lane_block quality REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "quality lane step 1 exits 0 on an eligible change"
assert_contains "$LB_OUT" "[quality] kind=range" "eligible: step 1 reports the target kind + durable inputs"
update_log_has "status=closed" && fail "eligible: step 1 does not close (review + filing come next)" \
  || ok "eligible: step 1 does not close (review + filing come next)"
[ -s "$LB_CREATE_LOG" ] && fail "eligible: step 1 files no findings on its own" \
  || ok "eligible: step 1 files no findings on its own"

# --- D. lane (ineligible): step 1 self-skips to a clean pass, files nothing ----
LB_CITY=""; LB_CREATE_LOG=""; LB_UPDATE_LOG=""; LB_META_LOG=""; LB_BEAD_ID=""
LB_ROOT="root-q-inelig"; LB_ELIGIBLE="no"; LB_TARGET_KIND="empty"
LB_REASON="empty diff, nothing to review"
lane_sandbox
run_lane_block quality REVIEW_ELIGIBLE
assert_eq "0" "$LB_RC" "quality lane step 1 exits 0 on an ineligible change (clean no-op)"
update_log_has "status=closed" && ok "ineligible: step 1 closes the lane pass" \
  || fail "ineligible: step 1 closes the lane pass"
update_log_has "ineligible" && ok "ineligible: the close note records the skip reason" \
  || fail "ineligible: the close note records the skip reason"
[ -s "$LB_CREATE_LOG" ] && fail "ineligible: no findings filed" \
  || ok "ineligible: no findings filed"
