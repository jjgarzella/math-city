# apply-fixes lib — the verdict->severity->fix machinery (gcs-f4j.8.5). Runs the
# real formulas/lib/review-apply-fixes.sh against canned bead JSON (stub bd/gc,
# no Dolt). The fix-vs-surface REASONING is the agent's and is not deterministic;
# the transport that frames it IS — and that is what this pins: the synthesis
# verdict -> done/iterate mapping, the durable-findings enumeration, the
# verdict-write glue, and the blocked terminate-to-human escalation.

section "02 apply-fixes lib (verdict->severity->fix transport)"

[ -f "$APPLY_FIXES_SH" ] && ok "shared apply-fixes lib present at formulas/lib/review-apply-fixes.sh" \
  || fail "shared apply-fixes lib present" "missing $APPLY_FIXES_SH"

# --- A. the synthesis verdict -> review.verdict map (pure, no bd) ------------
# pass->done; pass_with_findings->iterate iff fixes applied else done;
# fail->iterate (blocker fixed, re-review); blocked->done (caller escalates);
# unknown->iterate (conservative re-review, never a silent stop).
MV="$(. "$APPLY_FIXES_SH"; for sv in pass pass_with_findings fail blocked weird; do
  printf '%s/yes=%s %s/no=%s\n' "$sv" "$(review_apply_fixes_map_verdict "$sv" yes)" \
                                 "$sv" "$(review_apply_fixes_map_verdict "$sv" no)"
done)"
assert_contains "$MV" "pass/yes=done"               "map: pass -> done (applied)"
assert_contains "$MV" "pass/no=done"                "map: pass -> done (not applied)"
assert_contains "$MV" "pass_with_findings/yes=iterate" "map: pass_with_findings + applied -> iterate (re-review)"
assert_contains "$MV" "pass_with_findings/no=done"  "map: pass_with_findings + nothing applied -> done (converge)"
assert_contains "$MV" "fail/yes=iterate"            "map: fail + applied -> iterate (blocker fixed, re-review)"
assert_contains "$MV" "fail/no=iterate"             "map: fail -> iterate (loop re-tries; agent escalates an unfixable blocker)"
assert_contains "$MV" "blocked/yes=done"            "map: blocked -> done (terminate; caller escalates)"
assert_contains "$MV" "blocked/no=done"             "map: blocked -> done"
assert_contains "$MV" "weird/yes=iterate"           "map: unknown verdict -> iterate (conservative, never a silent stop)"

# --- B. the severity -> rank map (pure, no bd) -------------------------------
RANKS="$(. "$APPLY_FIXES_SH"; for s in blocker major minor nit other; do
  printf '%s=%s ' "$s" "$(review_apply_fixes__rank_for "$s")"; done)"
assert_contains "$RANKS" "blocker=0" "rank map: blocker -> 0 (must-fix first)"
assert_contains "$RANKS" "major=1"   "rank map: major -> 1"
assert_contains "$RANKS" "minor=2"   "rank map: minor -> 2"
assert_contains "$RANKS" "nit=3"     "rank map: nit -> 3"
assert_contains "$RANKS" "other=2"   "rank map: unknown severity -> 2 (minor)"

# --- C. the input/output contract is documented in the lib -------------------
LIBTXT="$(cat "$APPLY_FIXES_SH")"
assert_contains "$LIBTXT" "gc.review.synthesis_verdict"   "contract: reads the synthesis verdict off the root"
assert_contains "$LIBTXT" "pass_with_findings"            "contract: the pass/pass_with_findings/fail/blocked input vocabulary"
assert_contains "$LIBTXT" "severity:<blocker|major|minor|nit>" "contract: durable severity-tagged findings"
assert_contains "$LIBTXT" "ZERO judgment"                 "contract: pure transport, zero judgment (ZFC)"
assert_contains "$LIBTXT" "terminate-to-human"            "contract: blocked -> terminate-to-human"

# --- D. review_apply_fixes_load resolves the run -----------------------------
AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; AFX_FINDINGS_FILE=""
AFX_ROOT="root-load"; AFX_VERDICT="fail"; AFX_PROMOTED="2"; AFX_BURNED="1"
AFX_WORKDIR="/tmp/feature-wt"; FIX_THRESHOLD="major"; AFX_FINDINGS_JSON='[]'
afx_sandbox
afx_run '
  review_apply_fixes_load >/dev/null
  echo "ROOT=$REVIEW_ROOT"
  echo "VERDICT=$REVIEW_SYNTHESIS_VERDICT"
  echo "PROMOTED=$REVIEW_SYNTHESIS_PROMOTED"
  echo "BURNED=$REVIEW_SYNTHESIS_BURNED"
  echo "WORKDIR=$REVIEW_WORK_DIR"
  echo "THRESH=$REVIEW_FIX_THRESHOLD"
  echo "FINDINGS=$REVIEW_FINDINGS"
'
loaded="$AFX_OUT"
assert_eq "0" "$AFX_RC" "load exits 0"
assert_contains "$loaded" "ROOT=root-load"            "load resolves the molecule root from gc.root_bead_id"
assert_contains "$loaded" "VERDICT=fail"              "load reads gc.review.synthesis_verdict off the root"
assert_contains "$loaded" "PROMOTED=2"                "load reads the synthesis_promoted count"
assert_contains "$loaded" "BURNED=1"                  "load reads the synthesis_burned (surfaced sub-threshold) count"
assert_contains "$loaded" "WORKDIR=/tmp/feature-wt"   "load reads work_dir (the branch under review) off the root"
assert_contains "$loaded" "THRESH=major"              "load picks up FIX_THRESHOLD from the env (the loop's severity_threshold)"
assert_contains "$loaded" "FINDINGS=root-load.findings" "load derives the findings container id from the root"

# --- E. review_apply_fixes_findings enumerates durable findings, ranked ------
# A realistic promoted set: blocker/major/minor/nit (unsorted), plus a CLOSED
# finding and a finding with NO severity label (both must be excluded).
AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; AFX_FINDINGS_FILE=""
AFX_ROOT="root-find"; AFX_VERDICT="fail"; AFX_PROMOTED=""; AFX_BURNED=""; AFX_WORKDIR=""
AFX_FINDINGS_JSON='[
 {"id":"f-min","title":"minor thing","status":"open","labels":["severity:minor","category:docs"]},
 {"id":"f-blk","title":"blocker thing","status":"open","labels":["severity:blocker","category:security"]},
 {"id":"f-nit","title":"nit thing","status":"open","labels":["severity:nit","category:testing"]},
 {"id":"f-maj","title":"major thing","status":"open","labels":["severity:major","category:quality"]},
 {"id":"f-closed","title":"already fixed","status":"closed","labels":["severity:major","category:performance"]},
 {"id":"f-nolabel","title":"no severity","status":"open","labels":["category:architecture"]}
]'
afx_sandbox
afx_run 'review_apply_fixes_load >/dev/null; review_apply_fixes_findings'
TSV="$AFX_OUT"
assert_eq "0" "$AFX_RC" "findings exits 0"
nlines="$(printf '%s\n' "$TSV" | grep -c .)"
assert_eq "4" "$nlines" "findings enumerates the 4 labelled, non-closed durable findings"
first="$(printf '%s\n' "$TSV" | head -n1 | cut -f1)"
assert_eq "f-blk" "$first" "findings ranks the blocker first (must-fix order)"
last="$(printf '%s\n' "$TSV" | grep . | tail -n1 | cut -f1)"
assert_eq "f-nit" "$last" "findings ranks the nit last"
assert_contains "$TSV" "f-blk	blocker	security	blocker thing" "finding row is id\\tseverity\\tcategory\\ttitle"
assert_not_contains "$TSV" "f-closed"  "a CLOSED finding is excluded"
assert_not_contains "$TSV" "f-nolabel" "a finding with no severity label is excluded"
# rank order: blocker before major before minor before nit
order="$(printf '%s\n' "$TSV" | cut -f1 | tr '\n' ' ')"
assert_eq "f-blk f-maj f-min f-nit " "$order" "findings sorted blocker -> major -> minor -> nit"

# --- F. review_apply_fixes_set_verdict writes review.verdict + closes ---------
AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; AFX_FINDINGS_FILE=""
AFX_ROOT="root-setv"; AFX_VERDICT="pass_with_findings"; AFX_PROMOTED=""; AFX_BURNED=""; AFX_WORKDIR=""
AFX_FINDINGS_JSON='[]'
afx_sandbox
afx_run 'review_apply_fixes_load >/dev/null; review_apply_fixes_set_verdict iterate "applied 2 fixes"'
assert_eq "0" "$AFX_RC" "set_verdict iterate exits 0"
meta="$(cat "$AFX_META_LOG")"; upd="$(cat "$AFX_UPDATE_LOG")"
assert_contains "$meta" "apply-fixes-bead	review.verdict=iterate" "set_verdict writes review.verdict=iterate on THIS bead"
assert_contains "$meta" "apply-fixes-bead	gc.outcome=pass"        "set_verdict stamps gc.outcome=pass"
assert_contains "$upd"  "status=closed"                            "set_verdict closes this bead"
# invalid verdict is rejected (transport guard).
AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; AFX_FINDINGS_FILE=""; afx_sandbox
afx_run 'review_apply_fixes_load >/dev/null; review_apply_fixes_set_verdict bogus "x"'
assert_eq "2" "$AFX_RC" "set_verdict rejects an invalid verdict (exit 2)"

# --- G. review_apply_fixes_escalate — blocked -> terminate-to-human ----------
AFX_META_LOG=""; AFX_UPDATE_LOG=""; AFX_NUDGE_LOG=""; AFX_FINDINGS_FILE=""
AFX_ROOT="root-esc"; AFX_VERDICT="blocked"; AFX_PROMOTED=""; AFX_BURNED=""; AFX_WORKDIR=""
AFX_FINDINGS_JSON='[]'
afx_sandbox
afx_run 'review_apply_fixes_load >/dev/null; review_apply_fixes_escalate "ineligible change"'
assert_eq "0" "$AFX_RC" "escalate exits 0 (clean terminal, no abort)"
meta="$(cat "$AFX_META_LOG")"; upd="$(cat "$AFX_UPDATE_LOG")"; nudge="$(cat "$AFX_NUDGE_LOG")"
assert_contains "$meta" "root-esc	gc.review.loop_outcome=blocked-needs-human" "escalate flags blocked-needs-human on the ROOT"
assert_contains "$meta" "root-esc	gc.review.loop_blocked_reason=ineligible change" "escalate records the reason on the ROOT"
assert_contains "$meta" "apply-fixes-bead	review.verdict=done" "escalate sets review.verdict=done (stop, not spin to cap)"
assert_contains "$upd"  "status=closed"  "escalate closes this bead"
assert_contains "$AFX_ERR" "TERMINATE-TO-HUMAN" "escalate announces the terminate-to-human transition (stderr)"
assert_eq "" "$nudge" "escalate does NOT nudge from the lib (the verdict-glue check owns notify)"
