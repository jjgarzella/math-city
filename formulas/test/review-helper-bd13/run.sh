#!/usr/bin/env bash
# Real bd integration checks in a disposable embedded store. The wrapper only
# injects faults; all successful persistence/enumeration uses the installed CLI.
set -euo pipefail
CITY_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BD_TEST_REAL="$(command -v bd)"
export BD_TEST_REAL
for task_var in ${!BEADS_@} ${!BD_@} ${!GC_@}; do
  [ "$task_var" = BD_TEST_REAL ] || unset "$task_var"
done
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
TASK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-helper-bd13.XXXXXX")"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir -p "$TASK_TMP/bin" "$TASK_TMP/inputs"
cat > "$TASK_TMP/bin/bd" <<'WRAPPER'
#!/usr/bin/env bash
set -eu
case "${BD_TEST_FAULT:-}" in
  container) [[ "$*" == create*--id=* ]] && exit 71 ;;
  candidate) [[ "$*" == create*--ephemeral* ]] && exit 71 ;;
  candidate-read) [[ "$*" == "show $REVIEW_FINDINGS."* ]] && exit 71 ;;
  candidate-body) [[ "$*" == "show $REVIEW_FINDINGS."* ]] && { "$BD_TEST_REAL" "$@" | jq '.[0].description="lost body"'; exit 0; } ;;
  parent) [[ "$*" == update*--parent=* ]] && exit 71 ;;
  label) [[ "$*" == 'label add '* ]] && exit 71 ;;
  label-noop) [[ "$*" == 'label add '* ]] && exit 0 ;;
  priority) [[ "$*" == update*--priority=* ]] && exit 71 ;;
  promote) [[ "$*" == 'promote '* ]] && exit 71 ;;
  metadata) [[ "$*" == update*--set-metadata* ]] && exit 71 ;;
  container-close) [[ "$*" == 'close '* ]] && exit 71 ;;
  terminal) [[ "$*" == update*--status=closed* ]] && exit 71 ;;
  enumerate) [[ "$*" == "dep list $REVIEW_FINDINGS "* ]] && exit 71 ;;
  root-read) [[ "$*" == "dep list $REVIEW_ROOT "* ]] && exit 71 ;;
  malformed) [[ "$*" == "dep list $REVIEW_FINDINGS "* ]] && { echo '{"error":"read failed"}'; exit 0; } ;;
esac
exec "$BD_TEST_REAL" "$@"
WRAPPER
cat > "$TASK_TMP/bin/gc" <<'EOF_GC'
#!/usr/bin/env bash
# Heartbeats stay inside this test; never contact the city runtime.
exit 0
EOF_GC
chmod +x "$TASK_TMP/bin/"*
export PATH="$TASK_TMP/bin:$PATH"
cd "$TASK_TMP"
bd init --prefix rv --skip-hooks --skip-agents --non-interactive > "$TASK_TMP/init.log" 2>&1
. "$CITY_SOURCE/formulas/lib/review-lane.sh"
. "$CITY_SOURCE/formulas/lib/review-synthesis.sh"
. "$CITY_SOURCE/formulas/lib/review-apply-fixes.sh"
export GC_CITY="$CITY_SOURCE" REVIEW_ROOT=rv-review REVIEW_FINDINGS=rv-review.findings REVIEW_INPUTS_DIR="$TASK_TMP/inputs"
export GC_BEAD_ID
bd create --id "$REVIEW_ROOT" --title 'test review root' --silent >/dev/null
GC_BEAD_ID="$(bd create --parent "$REVIEW_ROOT" --title 'test lane' --silent)"
bd update "$GC_BEAD_ID" --set-metadata "gc.root_bead_id=$REVIEW_ROOT" >/dev/null
bd update "$REVIEW_ROOT" --set-metadata "gc.review.inputs_dir=$REVIEW_INPUTS_DIR" --set-metadata gc.review.eligible=yes >/dev/null
printf 'file.go:42\nEvidence: a lost write\n' > "$TASK_TMP/body"
PASS=0
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$PASS" "$1"; }
assert_json() {
  local title="$1" id="$2" expression="$3" value
  value="$(bd show "$id" --json)"
  printf '%s\n' "$value" | jq -e ".[0] | $expression" >/dev/null || { echo "FAIL: $title" >&2; exit 1; }
  ok "$title"
}
expect_failure() {
  local title="$1"; shift
  if "$@" > "$TASK_TMP/fault.out" 2> "$TASK_TMP/fault.err"; then
    echo "FAIL: $title unexpectedly succeeded" >&2
    exit 1
  fi
  ok "$title"
}
review_lane_load_inputs >/dev/null
# No lazy container is a genuine clean run; failed root reads are not.
[ -z "$(review_synthesis_candidates)" ] || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'absent lazy container gives no candidates'
[ -z "$(review_apply_fixes_findings)" ] || exit 1
ok 'absent lazy container gives no durable findings'
export BD_TEST_FAULT=root-read
expect_failure 'synthesis root read failure propagates' review_synthesis_candidates
expect_failure 'apply-fixes root read failure propagates' review_apply_fixes_findings
export BD_TEST_FAULT=container
expect_failure 'container create failure propagates' review_lane__ensure_container
export BD_TEST_FAULT=parent
expect_failure 'container parent write failure propagates' review_lane__ensure_container
unset BD_TEST_FAULT
review_lane__ensure_container
review_lane__ensure_container
assert_json 'container parent attached; repeat ensure is idempotent' "$REVIEW_FINDINGS" '.parent == "rv-review"'
[ "$(bd dep list "$REVIEW_ROOT" --direction up --type parent-child --json | jq '[.[] | select(.id=="rv-review.findings")] | length')" = 1 ] || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'one findings container after retry'
bd create --id rv-other --title 'different review root' --silent >/dev/null
bd update "$REVIEW_FINDINGS" --parent rv-other >/dev/null
expect_failure 'ensure refuses a container belonging to another review' review_lane__ensure_container
assert_json 'ensure preserves conflicting parent provenance' "$REVIEW_FINDINGS" '.parent=="rv-other"'
bd update "$REVIEW_FINDINGS" --parent "$REVIEW_ROOT" >/dev/null
# Failure in $(...) cannot be forgotten by the next call or a new shell.
export BD_TEST_FAULT=candidate
ignored="$(review_lane_file_finding quality 90 2 'lost candidate' "$TASK_TMP/body")" || true
unset BD_TEST_FAULT
expect_failure 'failed candidate inside command substitution prevents filed success' review_lane_close 'quality: filed 1 candidate'
expect_failure 'failure marker survives a new shell and blocks clean success' bash -c '. "$GC_CITY/formulas/lib/review-lane.sh"; review_lane_close "quality: clean"'
assert_json 'failed lane remains open without pass metadata' "$GC_BEAD_ID" '.status=="open" and .metadata["gc.outcome"]!= "pass"'
# The test reconciles the injected failure before attempting a real finding.
rm "$(review_lane__write_marker)"
for fault in candidate-read candidate-body; do
  export BD_TEST_FAULT="$fault"
  expect_failure "candidate $fault readback fails closed" review_lane_file_finding quality 90 2 "fault $fault" "$TASK_TMP/body"
  unset BD_TEST_FAULT
  expect_failure "candidate $fault blocks lane success" review_lane_close 'quality: clean'
  # Reconcile the test's persisted faulty candidate before clearing its marker.
  fault_id="$(sed -n 's/^Candidate: //p' "$(review_lane__write_marker)")"
  bd close "$fault_id" >/dev/null
  rm "$(review_lane__write_marker)"
done
candidate="$(review_lane_file_finding quality 90 2 'persisted candidate' "$TASK_TMP/body")"
assert_json 'candidate parent, category, confidence and ephemeral state persist' "$candidate" '.parent=="rv-review.findings" and .ephemeral==true and (.labels|index("category:quality")!=null) and (.description|startswith("Confidence: 90/100"))'
review_lane_close 'quality: filed 1 candidate' >/dev/null
# Use a fresh lane to verify terminal persistence failures propagate too.
success_lane="$GC_BEAD_ID"
GC_BEAD_ID="$(bd create --parent "$REVIEW_ROOT" --title 'faulty terminal lane' --silent)"
export BD_TEST_FAULT=terminal
expect_failure 'lane terminal write failure propagates' review_lane_close 'quality: clean'
unset BD_TEST_FAULT
assert_json 'terminal write failure leaves lane open' "$GC_BEAD_ID" '.status=="open"'
GC_BEAD_ID="$success_lane"
assert_json 'successful lane closes with pass metadata' "$GC_BEAD_ID" '.status=="closed" and .metadata["gc.outcome"]=="pass"'
durable="$(bd create --parent "$REVIEW_FINDINGS" --title 'durable survivor' --labels category:security,severity:major --priority 1 --description 'Confidence: 85/100' --silent)"
pending="$(bd create --parent "$REVIEW_FINDINGS" --ephemeral --title 'partially labelled wisp' --labels category:docs,severity:minor --description 'Confidence: 70/100' --silent)"
closed="$(bd create --parent "$REVIEW_FINDINGS" --ephemeral --title 'closed candidate' --silent)"
bd close "$closed" >/dev/null
bd create --parent "$REVIEW_ROOT" --title 'unrelated child' --labels severity:blocker --silent >/dev/null
candidates="$(review_synthesis_candidates)"
[ "$(printf '%s\n' "$candidates" | wc -l)" -eq 3 ] || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'synthesis enumerates durable and ephemeral open children only'
printf '%s\n' "$candidates" | awk -F '\t' -v id="$candidate" '$1==id && $2=="quality" && $3==90 {found=1} END {exit !found}' || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'enumeration preserves category and confidence'
findings="$(review_apply_fixes_findings)"
[ "$(printf '%s\n' "$findings" | cut -f1)" = "$durable" ] || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'apply-fixes excludes ephemeral findings even when severity-labelled'
for fault in enumerate malformed; do
  export BD_TEST_FAULT="$fault"
  expect_failure "synthesis $fault fails closed" review_synthesis_candidates
  expect_failure "apply-fixes $fault fails closed" review_apply_fixes_findings
done
for fault in label priority promote; do
  export BD_TEST_FAULT="$fault"
  expect_failure "promotion $fault failure propagates" review_synthesis_promote "$candidate" blocker 'test provenance'
  unset BD_TEST_FAULT
  assert_json "$fault failure leaves candidate ephemeral" "$candidate" '.ephemeral==true'
done
# A command can exit successfully without persisting a label: readback catches it.
noop="$(bd create --parent "$REVIEW_FINDINGS" --ephemeral --title 'no-op label test' --labels category:testing --silent)"
export BD_TEST_FAULT=label-noop
expect_failure 'successful label command without persisted label fails readback' review_synthesis_promote "$noop" minor 'no-op write'
unset BD_TEST_FAULT
assert_json 'unpersisted severity prevents durable promotion' "$noop" '.ephemeral==true'
review_synthesis_promote "$candidate" blocker 'real provenance' >/dev/null
review_synthesis_promote "$candidate" blocker 'retry provenance' >/dev/null
assert_json 'promotion/retry preserves parent, body, category and severity with P0' "$candidate" '(.ephemeral//false)==false and .parent=="rv-review.findings" and .priority==0 and (.labels|index("category:quality")!=null and index("severity:blocker")!=null) and (.description|contains("file.go:42"))'
findings="$(review_apply_fixes_findings)"
[ "$(printf '%s\n' "$findings" | head -1 | cut -f1)" = "$candidate" ] || { echo "FAIL: assertion predicate failed" >&2; exit 1; }
ok 'durable findings rank blocker before major'
# Every persistence failure must return nonzero before a success terminal.
GC_BEAD_ID="$(bd create --parent "$REVIEW_ROOT" --title synthesis --silent)"
for fault in metadata container-close terminal; do
  export BD_TEST_FAULT="$fault"
  expect_failure "synthesis $fault failure propagates" review_synthesis_record_verdict fail 3 2 0 0 'test verdict'
  unset BD_TEST_FAULT
  assert_json "synthesis remains open after $fault failure" "$GC_BEAD_ID" '.status=="open"'
done
review_synthesis_record_verdict fail 3 2 0 0 'test verdict' >/dev/null
assert_json 'synthesis records verdict and counts' "$REVIEW_ROOT" '.metadata["gc.review.synthesis_verdict"]=="fail" and (.metadata["gc.review.synthesis_promoted"]|tostring)=="2"'
GC_BEAD_ID="$(bd create --parent "$REVIEW_ROOT" --title apply-fixes --silent)"
for fault in metadata terminal; do
  export BD_TEST_FAULT="$fault"
  expect_failure "apply-fixes $fault failure propagates" review_apply_fixes_set_verdict iterate 'test fix'
  expect_failure "escalation $fault failure propagates" review_apply_fixes_escalate 'test block'
  unset BD_TEST_FAULT
  assert_json "apply-fixes remains open after $fault failure" "$GC_BEAD_ID" '.status=="open"'
done
review_apply_fixes_set_verdict iterate 'test fix' >/dev/null
assert_json 'apply-fixes verdict persists before successful close' "$GC_BEAD_ID" '.status=="closed" and .metadata["review.verdict"]=="iterate"'
printf '# summary: %s passed (installed %s; disposable store)\n' "$PASS" "$(bd --version)"
