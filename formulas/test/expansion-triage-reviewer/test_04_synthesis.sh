# Synthesis pass — pin triage's HIGH-PRECISION gate layered on the shared
# review-synthesis.sh: it re-scores each candidate against Anthropic's VERBATIM
# 0-100 rubric, BURNS anything below the threshold, dedup-merges, assigns severity,
# and records a verdict via the shared lib (so apply-fixes stays reviewer-agnostic).
# The dedup + severity REASONING is the agent's; the transport + the verbatim
# rubric + the lib wiring are what this pins — structurally, with one runnable
# end-to-end check of the ineligible clean-pass path, plus verbatim-against-source
# checks of the rubric + false-positive list (skipped when ANTHROPIC_SRC absent).

section "04 synthesis — confidence rubric + threshold gate + shared-lib wiring"

SYNTH_DESC="$(formula_py desc '{target}.synthesis')"

# --- the synthesis pass drives the SHARED reviewer-agnostic lib ---------------
for fn in review_synthesis_load review_synthesis_candidates review_synthesis_promote \
          review_synthesis_burn review_synthesis_record_verdict; do
  assert_contains "$SYNTH_DESC" "$fn" "synthesis uses the shared lib function $fn"
done
assert_contains "$SYNTH_DESC" 'formulas/lib/review-synthesis.sh' "synthesis sources the shared review-synthesis.sh via \$GC_CITY"

# --- triage's precision gate: re-score vs the threshold var, burn below ---------
assert_contains "$SYNTH_DESC" 'threshold `{threshold}`' "synthesis gates on the {threshold} var"
assert_contains "$SYNTH_DESC" "BURNED" "sub-threshold candidates are burned (the precision gate)"

# --- the VERBATIM Anthropic 0-100 confidence rubric is present -----------------
for line in \
  "0: Not confident at all." \
  "25: Somewhat confident." \
  "50: Moderately confident." \
  "75: Highly confident." \
  "100: Absolutely certain."; do
  assert_contains "$SYNTH_DESC" "$line" "rubric carries the verbatim '${line}' rung"
done

# --- the verdict semantics (shared synthesis contract) ------------------------
assert_contains "$SYNTH_DESC" "pass_with_findings" "verdict vocabulary includes pass_with_findings"
assert_contains "$SYNTH_DESC" "at least one **blocker** survived" "fail verdict = a blocker survived"

# --- runnable: the ineligible path records a clean pass via the shared lib -----
script="$(formula_py block '{target}.synthesis' 'review_synthesis_candidates')" \
  && {
    SY_CITY=""; SY_META_LOG=""; SY_ROOT="root-synth-inelig"; SY_ELIGIBLE="no"
    synth_sandbox
    out="$(synth_env bash -c "$script" 2>&1)"; rc=$?
    assert_eq "0" "$rc" "synthesis step 1 exits 0 on an ineligible change"
    assert_eq "pass" "$(synth_meta_val gc.review.synthesis_verdict)" \
      "ineligible synthesis records gc.review.synthesis_verdict=pass via the shared lib"
  } || fail "could not render the synthesis step-1 block"

# --- verbatim-against-source: the rubric + FP list match Anthropic's command ----
if [ -r "$ANTHROPIC_SRC" ]; then
  # A signature rubric rung and a signature FP line must appear verbatim in the
  # Anthropic code-review command source — proof they were copied, not paraphrased.
  grep -qF -- "Highly confident. The agent double checked the issue" "$ANTHROPIC_SRC" \
    && ok "rubric rung is verbatim from the Anthropic source" \
    || fail "rubric rung is verbatim from the Anthropic source"
  grep -qF -- "Pedantic nitpicks that a senior engineer wouldn't call out" "$ANTHROPIC_SRC" \
    && ok "false-positive line is verbatim from the Anthropic source" \
    || fail "false-positive line is verbatim from the Anthropic source"
  # And the fragment's copies match those same source strings.
  assert_contains "$SYNTH_DESC" "Highly confident. The agent double checked the issue" \
    "the fragment's rubric matches the Anthropic source string"
else
  echo "  skip ANTHROPIC_SRC absent — verbatim-against-source checks skipped"
fi
