# Review-synthesis lib + synthesis transport (gcs-f4j.8.3) — the shared
# formulas/lib/review-synthesis.sh is the single source of truth for the
# verdict -> severity -> promote machinery the synthesis pass repeats (load the
# run -> enumerate the lane wisps -> dedup/severity -> promote survivors / burn
# rejects -> record the verdict). The dedup + severity REASONING is the agent's
# and is not deterministic; the transport that frames it IS, and that is what this
# pins — proving synthesis turns a realistic set of lane candidates (including a
# cross-lens duplicate and a sub-threshold nit) into deduped, severity-tagged
# DURABLE findings + a verdict.
#
# bd is stubbed (bin/bd): it returns the candidate wisps as the findings
# container's .children, and records every promote / label add / mol burn /
# update so the assertions can check what synthesis wrote. No live Dolt.

section "06 review-synthesis lib + synthesis transport"

[ -f "$SYNTH_LIB" ] && ok "shared synthesis lib present at formulas/lib/review-synthesis.sh" \
  || fail "shared synthesis lib present" "missing $SYNTH_LIB"

# --- A. the severity -> priority map (pure, no bd) ---------------------------
pmap="$(. "$SYNTH_LIB"; for s in blocker major minor nit other; do \
  printf '%s=%s ' "$s" "$(review_synthesis__priority_for "$s")"; done)"
assert_contains "$pmap" "blocker=0" "priority map: blocker -> 0 (ranked first by bd ready)"
assert_contains "$pmap" "major=1"   "priority map: major -> 1"
assert_contains "$pmap" "minor=2"   "priority map: minor -> 2"
assert_contains "$pmap" "nit=3"     "priority map: nit -> 3"
assert_contains "$pmap" "other=2"   "priority map: unknown severity -> 2 (minor)"

# --- B. the finding / verdict contract is documented in the lib --------------
LIBTXT="$(cat "$SYNTH_LIB")"
assert_contains "$LIBTXT" "severity:<blocker|major|minor|nit>" "contract: severity label on the durable finding bead"
assert_contains "$LIBTXT" "category:<lens>"                    "contract: category label preserved from the lane(s)"
assert_contains "$LIBTXT" "pass_with_findings"                 "contract: the pass/pass_with_findings/fail/blocked verdict"
assert_contains "$LIBTXT" "gc.review.synthesis_verdict"        "contract: verdict recorded on the molecule root"

# The realistic candidate set the lanes filed: a security + quality DUPLICATE on
# the same file:line/root-cause, a distinct perf finding, a docs gap, and a
# testing nit. Confidence first lines mirror review_lane_file_finding's wisps.
CANDS='[
 {"id":"w-sec","title":"unchecked promote failure","status":"open","labels":["category:security"],"description":"Confidence: 90/100\n\nreview-synthesis.sh:160 — a real finding could be silently dropped if bd promote fails"},
 {"id":"w-qual","title":"swallowed promote error","status":"open","labels":["category:quality"],"description":"Confidence: 70/100\n\nreview-synthesis.sh:160 — same swallowed promote failure (duplicate of the security finding)"},
 {"id":"w-perf","title":"candidates re-lists all beads","status":"open","labels":["category:performance"],"description":"Confidence: 60/100\n\nreview-synthesis.sh:120 — bd list runs on every call"},
 {"id":"w-docs","title":"missing usage example","status":"open","labels":["category:docs"],"description":"Confidence: 40/100\n\nreview-synthesis.sh:1 — header lacks a usage example"},
 {"id":"w-test","title":"prefer printf over echo","status":"open","labels":["category:testing"],"description":"Confidence: 30/100\n\nreview-synthesis.sh:200 — a stylistic nit"}
]'

# --- C. review_synthesis_load resolves the run --------------------------------
SY_CITY=""; SY_UPDATE_LOG=""; SY_META_LOG=""; SY_PROMOTE_LOG=""; SY_CANDIDATES_FILE=""
SY_ROOT="root-synth-load"; SY_ELIGIBLE="yes"; SY_TARGET_KIND="range"; SY_CANDIDATES_JSON='[]'
synth_sandbox
loaded="$(synth_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-synthesis.sh"
  review_synthesis_load >/dev/null
  echo "ROOT=$REVIEW_ROOT"
  echo "FINDINGS=$REVIEW_FINDINGS"
  echo "ELIGIBLE=$REVIEW_ELIGIBLE"
  [ -f "$REVIEW_DIFF" ] && echo "DIFF_OK=yes"
')"
assert_contains "$loaded" "ROOT=root-synth-load"            "load resolves the molecule root from gc.root_bead_id"
assert_contains "$loaded" "FINDINGS=root-synth-load.findings" "load derives the findings container id (<root>.findings)"
assert_contains "$loaded" "ELIGIBLE=yes"                    "load reads the analyze eligibility verdict"
assert_contains "$loaded" "DIFF_OK=yes"                     "load points REVIEW_DIFF at the durable diff"

# --- D. review_synthesis_candidates enumerates the lane wisps -----------------
SY_CITY=""; SY_UPDATE_LOG=""; SY_META_LOG=""; SY_PROMOTE_LOG=""; SY_CANDIDATES_FILE=""
SY_ROOT="root-synth-cand"; SY_ELIGIBLE="yes"; SY_TARGET_KIND="range"; SY_CANDIDATES_JSON="$CANDS"
synth_sandbox
cands="$(synth_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-synthesis.sh"
  review_synthesis_load >/dev/null
  review_synthesis_candidates
')"
n="$(printf '%s\n' "$cands" | grep -c .)"
assert_eq "5" "$n" "candidates enumerates all five lane wisps"
seccat="$(printf '%s\n' "$cands" | awk -F'\t' '$1=="w-sec"{print $2}')"
secconf="$(printf '%s\n' "$cands" | awk -F'\t' '$1=="w-sec"{print $3}')"
assert_eq "security" "$seccat"  "candidates reads the originating lens from the category: label"
assert_eq "90" "$secconf"       "candidates parses the Confidence self-rating from the wisp body"

# --- E. promote survivors + burn rejects + record the verdict -----------------
# Synthesis decision over the candidate set: merge w-qual into the security
# survivor w-sec (same file:line/root-cause), severity w-sec=blocker, w-perf=major,
# w-docs=minor; burn the duplicate (w-qual) and the sub-threshold nit (w-test).
# Result: 5 considered = 3 promoted + 1 merged + 1 burned; verdict fail (a blocker).
SY_CITY=""; SY_UPDATE_LOG=""; SY_META_LOG=""; SY_PROMOTE_LOG=""; SY_CANDIDATES_FILE=""
SY_ROOT="root-synth-emit"; SY_ELIGIBLE="yes"; SY_TARGET_KIND="range"; SY_CANDIDATES_JSON="$CANDS"
synth_sandbox
emit="$(synth_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-synthesis.sh"
  review_synthesis_load >/dev/null
  review_synthesis_promote w-sec  blocker "a real finding could be silently dropped"
  review_synthesis_promote w-perf major   "bd list runs on every call"
  review_synthesis_promote w-docs minor   "doc gap on the public header"
  review_synthesis_burn    w-qual "duplicate of w-sec (same file:line/root-cause)"
  review_synthesis_burn    w-test "below the minor threshold (nit)"
  review_synthesis_record_verdict fail 5 3 1 1 "1 blocker (security), 1 major (perf), 1 minor (docs)"
' 2>&1)"

# Promotions: each survivor is stamped severity:<level>, re-prioritized, promoted.
grep -Eq "label[[:space:]]+severity:blocker[[:space:]]+w-sec"  "$SY_PROMOTE_LOG" \
  && ok "promote stamps severity:blocker on the security survivor" || fail "promote stamps severity:blocker on w-sec" "$emit"
grep -Eq "label[[:space:]]+severity:major[[:space:]]+w-perf"   "$SY_PROMOTE_LOG" \
  && ok "promote stamps severity:major on the perf survivor"     || fail "promote stamps severity:major on w-perf"
grep -Eq "label[[:space:]]+severity:minor[[:space:]]+w-docs"   "$SY_PROMOTE_LOG" \
  && ok "promote stamps severity:minor on the docs survivor"     || fail "promote stamps severity:minor on w-docs"
grep -Eq "^promote[[:space:]]+id=w-sec"  "$SY_PROMOTE_LOG" && ok "w-sec is promoted to a durable finding bead"  || fail "w-sec promoted"
grep -Eq "^promote[[:space:]]+id=w-perf" "$SY_PROMOTE_LOG" && ok "w-perf is promoted to a durable finding bead" || fail "w-perf promoted"
grep -Eq "^promote[[:space:]]+id=w-docs" "$SY_PROMOTE_LOG" && ok "w-docs is promoted to a durable finding bead" || fail "w-docs promoted"

# Burns: the cross-lens duplicate and the sub-threshold nit are removed.
grep -Eq "^burn[[:space:]]+w-qual" "$SY_PROMOTE_LOG" && ok "the cross-lens duplicate (w-qual) is burned" || fail "w-qual burned"
grep -Eq "^burn[[:space:]]+w-test" "$SY_PROMOTE_LOG" && ok "the sub-threshold nit (w-test) is burned"    || fail "w-test burned"
grep -Eq "^promote[[:space:]]+id=w-qual" "$SY_PROMOTE_LOG" && fail "duplicate w-qual must NOT be promoted" || ok "the duplicate is not promoted (merged, then burned)"

# Severity -> priority re-ranking on the durable finding.
grep -Eq "id=w-sec.*priority=0" "$SY_UPDATE_LOG" && ok "the blocker survivor is re-prioritized to P0 (bd ready ranks it first)" \
  || fail "blocker -> priority 0" "$(cat "$SY_UPDATE_LOG")"

# Verdict + counts recorded on the molecule root.
assert_eq "fail" "$(synth_meta_val gc.review.synthesis_verdict)"   "records verdict=fail (a blocker survived) on the root"
assert_eq "5"    "$(synth_meta_val gc.review.synthesis_considered)" "records considered=5"
assert_eq "3"    "$(synth_meta_val gc.review.synthesis_promoted)"   "records promoted=3"
assert_eq "1"    "$(synth_meta_val gc.review.synthesis_merged)"     "records merged=1"
assert_eq "1"    "$(synth_meta_val gc.review.synthesis_burned)"     "records burned=1"

# The synthesis bead itself closes pass — the single clean terminal.
grep -Eq "id=synthesis-bead.*status=closed" "$SY_UPDATE_LOG" \
  && ok "the synthesis bead closes (status=closed)" || fail "synthesis bead closes" "$(cat "$SY_UPDATE_LOG")"

# --- F. invalid severity is rejected (transport guards its contract) ----------
SY_CITY=""; SY_UPDATE_LOG=""; SY_META_LOG=""; SY_PROMOTE_LOG=""; SY_CANDIDATES_FILE=""
SY_ROOT="root-synth-guard"; SY_ELIGIBLE="yes"; SY_TARGET_KIND="range"; SY_CANDIDATES_JSON="$CANDS"
synth_sandbox
guard_rc="$(synth_env bash -c '
  . "$GC_CITY/formulas/lib/review-synthesis.sh"
  review_synthesis_load >/dev/null
  review_synthesis_promote w-sec critical "not a valid severity" >/dev/null 2>&1
  echo "RC=$?"
')"
assert_contains "$guard_rc" "RC=2" "promote rejects an invalid severity (only blocker|major|minor|nit)"
grep -Eq "^promote[[:space:]]+id=w-sec" "$SY_PROMOTE_LOG" && fail "invalid-severity promote must not reach bd promote" \
  || ok "an invalid-severity candidate is never promoted"

# --- G. a clean (zero-findings) run records pass ------------------------------
SY_CITY=""; SY_UPDATE_LOG=""; SY_META_LOG=""; SY_PROMOTE_LOG=""; SY_CANDIDATES_FILE=""
SY_ROOT="root-synth-clean"; SY_ELIGIBLE="yes"; SY_TARGET_KIND="range"; SY_CANDIDATES_JSON='[]'
synth_sandbox
synth_env bash -c '
  set -uo pipefail
  . "$GC_CITY/formulas/lib/review-synthesis.sh"
  review_synthesis_load >/dev/null
  cands="$(review_synthesis_candidates)"
  [ -z "$cands" ] && review_synthesis_record_verdict pass 0 0 0 0 "no candidate findings from any lane"
' >/dev/null 2>&1
assert_eq "pass" "$(synth_meta_val gc.review.synthesis_verdict)" "zero candidates -> a clean pass verdict"
