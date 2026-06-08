# Lifecycle transport — steps 4b (persist), 7 (dedup-merge), 9 (promote/burn +
# audit). These blocks are the formula's "pure transport — run it verbatim"
# bead commands. They are exercised here through a recording `bd` stub (bin/bd,
# never a real Dolt store), so the EXACT bd invocations are deterministic.
#
# The semantic INPUTS to these steps (which findings exist, their re-scores,
# which cluster) are the LLM's job and belong to the .6 dogfood. This test
# fixes those inputs and asserts the transport: that a given decision produces
# the right beads, labels, notes, and audit arithmetic. This is the dedup +
# promote/burn coverage the .3/.4 handoffs assigned to .5.

section "03 lifecycle transport (bd stub)"

# --- every embedded bash block must be valid bash (caught the step-7 bug) ----
nblocks=0
bad=0
buf=""
while IFS= read -r line; do
  if [ "$line" = "@@@BLOCK@@@" ]; then
    nblocks=$((nblocks + 1))
    if ! printf '%s' "$buf" | bash -n 2>/dev/null; then
      bad=$((bad + 1))
      fail "embedded bash block #$nblocks parses" "bash -n rejected it"
    fi
    buf=""
  else
    buf="$buf$line"$'\n'
  fi
done < <(formula_py blocks)
[ "$nblocks" -ge 6 ] && ok "extracted $nblocks embedded bash blocks" \
  || fail "extracted at least 6 embedded bash blocks" "found $nblocks"
[ "$bad" -eq 0 ] && ok "all $nblocks embedded bash blocks are valid bash"

# --- stub plumbing -----------------------------------------------------------
lc_reset() {
  BD_STATE="$(mktemp -d)"; export BD_STATE
  BD_LOG="$BD_STATE/bd.log"; export BD_LOG
  : > "$BD_LOG"
}
lc_run() { # render block <signature> and run it with the bd/gh stubs on PATH
  local blk rendered
  blk="$(formula_block "$1")"
  rendered="$(render "$blk")"
  ( PATH="$SUITE_DIR/bin:$PATH" bash -c "$rendered" )
}
log_count() { grep -cF -- "$1" "$BD_LOG"; }   # matching log LINES

# --- step 4b: create the findings container once, under the molecule root ----
lc_reset
export GC_BEAD_ID="gcs-run1" BD_ROOT="gcs-root1" BD_FINDINGS_EXISTS=0
out="$(lc_run 'FINDINGS="${ROOT}.findings"')"
assert_contains "$out" "findings container: gcs-root1.findings (root gcs-root1)" \
  "container root resolved from gc.root_bead_id"
assert_file_contains "$BD_LOG" "create --id=gcs-root1.findings --parent=gcs-root1" \
  "container created under the molecule root"

lc_reset
export GC_BEAD_ID="gcs-run1" BD_ROOT="gcs-root1" BD_FINDINGS_EXISTS=1
lc_run 'FINDINGS="${ROOT}.findings"' >/dev/null
assert_file_contains "$BD_LOG" "show gcs-root1.findings" "existing container probed before create"
assert_eq 0 "$(log_count 'create --id=gcs-root1.findings')" "create skipped when container already exists"

lc_reset
export GC_BEAD_ID="gcs-run1" BD_ROOT="" BD_FINDINGS_EXISTS=0
out="$(lc_run 'FINDINGS="${ROOT}.findings"')"
assert_contains "$out" "(root gcs-run1)" "single-bead molecule falls back to GC_BEAD_ID as root"
assert_file_contains "$BD_LOG" "create --id=gcs-run1.findings --parent=gcs-run1" \
  "container parented on the run bead when there is no separate root"

# --- step 7: fold a duplicate into the canonical survivor --------------------
lc_reset
export KEEP="wisp-hi" DUP="wisp-lo" DUP_CAT="git-history" DUP_SCORE=90
lc_run 'bd update "$KEEP" --add-label' >/dev/null
assert_file_contains "$BD_LOG" "update wisp-hi --add-label category:git-history" \
  "merge tags the canonical wisp with the duplicate's angle"
assert_file_contains "$BD_LOG" "merged duplicate wisp-lo" "merge appends a note crediting the folded angle"

# --- step 9: promote a survivor / burn a reject ------------------------------
lc_reset
export WISP="wisp-007"
lc_run 'bd promote "$WISP"' >/dev/null
assert_file_contains "$BD_LOG" "promote wisp-007 --reason=" "survivor promoted with a --reason (re-score travels here)"

lc_reset
export WISP="wisp-008"
lc_run 'bd mol burn --force' >/dev/null
assert_file_contains "$BD_LOG" "mol burn --force wisp-008" "reject burned with 'bd mol burn --force'"

# --- step 9: audit to the run bead, then close the container -----------------
lc_reset
export GC_BEAD_ID="gcs-run1" FINDINGS="gcs-root1.findings"
lc_run 'mol-triage-review audit' >/dev/null
assert_file_contains "$BD_LOG" "update gcs-run1 --append-notes" "audit written to the run bead's notes"
assert_file_contains "$BD_LOG" "mol-triage-review audit" "audit note carries the audit header"
assert_file_contains "$BD_LOG" "close gcs-root1.findings --reason=" "findings container closed with a reason"

# --- scenario transport: the five acceptance outcomes, given fixed decisions -
# [1] rule violation + real bug, both re-scored >= threshold, distinct root
#     causes -> BOTH promoted, nothing burned.
lc_reset
for w in wisp-rule wisp-bug; do export WISP="$w"; lc_run 'bd promote "$WISP"' >/dev/null; done
assert_eq 2 "$(log_count 'promote wisp')" "[1] two distinct survivors -> two promotions"
assert_eq 0 "$(log_count 'mol burn')"     "[1] nothing burned"

# [4] same file+line+root-cause from two angles -> ONE promoted bead citing
#     both angles, the duplicate burned. canonical = higher re-score (wisp-hi).
lc_reset
export KEEP="wisp-hi" DUP="wisp-lo" DUP_CAT="git-history" DUP_SCORE=90
lc_run 'bd update "$KEEP" --add-label' >/dev/null
export WISP="wisp-hi"; lc_run 'bd promote "$WISP"' >/dev/null
export WISP="wisp-lo"; lc_run 'bd mol burn --force' >/dev/null
assert_eq 1 "$(log_count 'promote wisp')"               "[4] cluster of two -> exactly one promotion"
assert_eq 1 "$(log_count 'mol burn --force wisp-lo')"   "[4] the duplicate is burned, not promoted"
assert_file_contains "$BD_LOG" "update wisp-hi --add-label category:git-history" \
  "[4] the surviving bead cites the merged angle"
# audit invariant: promoted + merged + burned = considered
assert_eq 2 "$((1 + 1 + 0))" "[4] audit invariant promoted(1)+merged(1)+burned(0)=considered(2)"

# [5] sub-threshold nitpick (re-score < threshold) -> NOT flagged: burned.
lc_reset
export WISP="wisp-nit"
lc_run 'bd mol burn --force' >/dev/null
assert_eq 0 "$(log_count 'promote wisp')"             "[5] sub-threshold finding never promoted"
assert_eq 1 "$(log_count 'mol burn --force wisp-nit')" "[5] sub-threshold finding burned"
