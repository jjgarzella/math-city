# Fragment integrity — pure structural assertions over the TOML (no gc needed).
#
# Pins the canonical triage fragment's whole contract: it is an `expansion` of
# graph.v2; its steps are analyze -> FIVE real-bugs lenses -> synthesis; the lens
# set is triage's NARROW real-bugs angles (NOT the standard reviewer's six breadth
# lenses); each lens is separately dispatched (own run_target) with its OWN
# per-lane opt_model var; the DAG wires every lens to analyze and synthesis to all
# five lenses; and the var contract + single-brace expansion syntax + the
# confidence threshold default are all locked.

section "01 fragment integrity"

# --- top-level shape ---------------------------------------------------------
assert_eq "expansion-triage-reviewer" "$(formula_py formula-name)" "formula name is expansion-triage-reviewer"
assert_eq "graph.v2" "$(formula_py contract)" "contract is graph.v2"
assert_eq "expansion" "$(formula_py ftype)" "type is expansion (compose.expand fragment, not a standalone workflow)"

# --- the seven templates: analyze -> five real-bugs lenses -> synthesis -------
ids="$(formula_py template-ids | tr '\n' ' ')"
assert_eq "{target}.analyze {target}.rule-adherence {target}.bug-scan {target}.git-history {target}.prior-prs {target}.in-code-invariants {target}.synthesis " \
  "$ids" "templates are analyze + the five real-bugs lenses + synthesis, in order"

LENSES="rule-adherence bug-scan git-history prior-prs in-code-invariants"

# --- triage's lens set is the NARROW real-bugs angles, NOT the standard six ---
# The whole point of gcs-f4j.10.1: narrow to triage's differentiator, do NOT clone
# the standard reviewer's breadth lenses.
for std in quality security performance architecture testing docs; do
  assert_not_contains "$ids" "{target}.$std" "lens set excludes the standard breadth lens '$std'"
done

# --- every lens + analyze + synthesis dispatches to the polecat pool ----------
for t in analyze $LENSES synthesis; do
  assert_eq "gasvillage.polecat" "$(formula_py meta "{target}.$t" gc.run_target)" \
    "{target}.$t carries gc.run_target=gasvillage.polecat (separately dispatched)"
done

# --- per-lane opt_model: each step rides its OWN model var (the right-sizing /
#     provider-robustness seam). analyze=aux_model, synthesis=synthesis_model -----
assert_eq "{aux_model}"                "$(formula_py meta '{target}.analyze' opt_model)"             "analyze opt_model <- {aux_model}"
assert_eq "{rule_adherence_model}"     "$(formula_py meta '{target}.rule-adherence' opt_model)"      "rule-adherence opt_model <- {rule_adherence_model}"
assert_eq "{bug_scan_model}"           "$(formula_py meta '{target}.bug-scan' opt_model)"            "bug-scan opt_model <- {bug_scan_model}"
assert_eq "{git_history_model}"        "$(formula_py meta '{target}.git-history' opt_model)"         "git-history opt_model <- {git_history_model}"
assert_eq "{prior_prs_model}"          "$(formula_py meta '{target}.prior-prs' opt_model)"           "prior-prs opt_model <- {prior_prs_model}"
assert_eq "{in_code_invariants_model}" "$(formula_py meta '{target}.in-code-invariants' opt_model)"  "in-code-invariants opt_model <- {in_code_invariants_model}"
assert_eq "{synthesis_model}"          "$(formula_py meta '{target}.synthesis' opt_model)"           "synthesis opt_model <- {synthesis_model}"

# --- the DAG: every lens needs analyze; synthesis needs all five lenses --------
for lens in $LENSES; do
  assert_eq "{target}.analyze" "$(formula_py needs "{target}.$lens")" \
    "$lens needs {target}.analyze (reads its durable inputs)"
done
synth_needs="$(formula_py needs '{target}.synthesis' | tr '\n' ' ')"
for lens in $LENSES; do
  assert_contains "$synth_needs" "{target}.$lens" "synthesis needs {target}.$lens (sees every candidate)"
done

# --- var contract: exactly the ten declared, single-brace expansion syntax -----
vars="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "aux_model base_branch bug_scan_model git_history_model in_code_invariants_model prior_prs_model review_target rule_adherence_model synthesis_model threshold " \
  "$vars" "the fragment declares exactly its ten vars"
assert_contains "$vars" "review_target" "review target var is review_target (not the reserved {target})"
assert_eq "0" "$(formula_py double-braces)" "expansion templates use SINGLE braces (no {{double}} refs)"

# --- defaults: triage's cheap-first model tiering + the precision threshold -----
assert_eq ""       "$(formula_py var-default review_target)"            "review_target default is empty (=> base_branch..HEAD)"
assert_eq "main"   "$(formula_py var-default base_branch)"             "base_branch default is main"
assert_eq "haiku"  "$(formula_py var-default aux_model)"               "aux_model default haiku (cheap)"
assert_eq "haiku"  "$(formula_py var-default rule_adherence_model)"    "rule-adherence default haiku (mechanical angle)"
assert_eq "sonnet" "$(formula_py var-default bug_scan_model)"          "bug-scan default sonnet (core judgment angle)"
assert_eq "sonnet" "$(formula_py var-default git_history_model)"       "git-history default sonnet (judgment angle)"
assert_eq "haiku"  "$(formula_py var-default prior_prs_model)"         "prior-prs default haiku (mechanical angle)"
assert_eq "sonnet" "$(formula_py var-default in_code_invariants_model)" "in-code-invariants default sonnet (judgment angle)"
assert_eq "sonnet" "$(formula_py var-default synthesis_model)"         "synthesis default sonnet (precision pass)"
assert_eq "80"     "$(formula_py var-default threshold)"               "confidence threshold default 80 (Anthropic's)"

# --- no opus by default: triage is the cheap, always-on tier -------------------
for v in aux_model rule_adherence_model bug_scan_model git_history_model prior_prs_model in_code_invariants_model synthesis_model; do
  assert_not_contains "$(formula_py var-default "$v")" "opus" "$v default is not the deep (opus) tier"
done

# --- every declared var is actually referenced somewhere in the templates ------
refs="$(formula_py var-refs | tr '\n' ' ')"
for v in review_target base_branch aux_model rule_adherence_model bug_scan_model git_history_model prior_prs_model in_code_invariants_model synthesis_model threshold; do
  assert_contains "$refs" "$v" "declared var $v is referenced in the templates (no dead var)"
done
