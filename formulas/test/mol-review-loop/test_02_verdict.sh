# Verdict-glue behavior — runs the shared review-verdict.sh against canned bead
# JSON (bin/bd, bin/gc stubs; no real Dolt) to pin the reviewer-agnostic
# exit-code contract and the optional fire-and-forget notify.
#
#   exit 0 = converged (done/approved/pass) | exit 1 = iterate | exit 2 = undetermined

section "02 verdict glue + notify"

# verdict_case <attempt> <list_verdicts> <notify> <maxatt> <nudge_fail>
# Exports every knob each call so scenarios never leak into one another.
verdict_case() {
  export GC_BEAD_ID="subj" BD_ROOT="root"
  export GC_ITERATION="$1" BD_ATTEMPT="$1"
  export BD_LIST_VERDICTS="$2"
  export BD_NOTIFY="$3" BD_MAXATT="$4" GC_NUDGE_FAIL="$5"
  run_verdict
}

TS1="2026-01-01T00:00:00Z"
TS2="2026-06-01T00:00:00Z"

# --- exit 0: converged verdicts ----------------------------------------------
for v in done approved pass; do
  verdict_case 1 "$v,$TS1" "" "" 0
  assert_eq "0" "$V_RC" "verdict '$v' -> exit 0 (converged/stop)"
done
assert_contains "$V_OUT" "converged" "converged verdict prints 'converged' on stdout"

# --- exit 1: iterate verdicts ------------------------------------------------
for v in iterate fail retry; do
  verdict_case 1 "$v,$TS1" "" "" 0
  assert_eq "1" "$V_RC" "verdict '$v' -> exit 1 (iterate)"
done

# --- exit 1: unknown verdict treated as iterate ------------------------------
verdict_case 1 "maybe,$TS1" "" "" 0
assert_eq "1" "$V_RC" "unknown verdict -> exit 1 (iterate)"
assert_contains "$V_ERR" "unknown review.verdict" "unknown verdict warns on stderr"

# --- exit 2: no verdict visible (fail-closed) --------------------------------
verdict_case 1 "" "" "" 0
assert_eq "2" "$V_RC" "no review.verdict -> exit 2 (undetermined, fail-closed)"
assert_contains "$V_ERR" "no review.verdict" "undetermined reports the missing verdict on stderr"

# --- exit 2: missing GC_BEAD_ID ----------------------------------------------
( unset GC_BEAD_ID; run_verdict; exit "$V_RC" ); rc=$?
assert_eq "2" "$rc" "missing GC_BEAD_ID -> exit 2"

# --- newest verdict wins across reads ----------------------------------------
verdict_case 1 "iterate,$TS1;done,$TS2" "" "" 0
assert_eq "0" "$V_RC" "newest verdict wins (older=iterate, newest=done -> exit 0)"
verdict_case 1 "done,$TS1;iterate,$TS2" "" "" 0
assert_eq "1" "$V_RC" "newest verdict wins (older=done, newest=iterate -> exit 1)"

# --- attempt scoping: a verdict from a DIFFERENT attempt is ignored ----------
# The apply-fixes bead is filed under BD_ATTEMPT; ask the check for a different
# attempt and it finds nothing -> undetermined.
export GC_BEAD_ID="subj" BD_ROOT="root" GC_ITERATION="2" BD_ATTEMPT="1"
export BD_LIST_VERDICTS="done,$TS1" BD_NOTIFY="" BD_MAXATT="" GC_NUDGE_FAIL=0
run_verdict
assert_eq "2" "$V_RC" "verdict from a different attempt is not matched (attempt-scoped) -> exit 2"

# --- optional fire-and-forget notify -----------------------------------------
# converged + notify target set -> fires a 'converged' nudge, still exit 0.
verdict_case 1 "done,$TS1" "mayor/sess" "3" 0
assert_eq "0" "$V_RC" "converged with notify target -> still exit 0"
assert_contains "$V_NUDGE" "converged" "converged fires a 'converged' fire-and-forget nudge"

# iterate at the cap (attempt == max_attempts) -> fires a 'capped' nudge, exit 1.
verdict_case 3 "iterate,$TS1" "mayor/sess" "3" 0
assert_eq "1" "$V_RC" "iterate at the cap -> exit 1"
assert_contains "$V_NUDGE" "capped" "iterate at the cap fires a 'capped' fire-and-forget nudge"

# iterate mid-loop (attempt < max_attempts) -> NO notify, exit 1.
verdict_case 1 "iterate,$TS1" "mayor/sess" "3" 0
assert_eq "1" "$V_RC" "iterate mid-loop -> exit 1"
assert_eq "" "$V_NUDGE" "iterate mid-loop fires NO notify (not yet terminal)"

# notify disabled (no target) -> never nudges, even on converge.
verdict_case 1 "done,$TS1" "" "3" 0
assert_eq "" "$V_NUDGE" "no notify target -> no nudge (notify disabled by default)"

# fire-and-forget: a failing nudge must NOT change the converged exit code.
verdict_case 1 "done,$TS1" "mayor/sess" "3" 1
assert_eq "0" "$V_RC" "a FAILING notify is swallowed — converged still exits 0 (fire-and-forget)"
