# Fragment integrity — deterministic structural + textual assertions over the
# expansion-standard-reviewer TOML. Locks down the canonical-reviewer-fragment
# shape gcs-f4j.8.1 specifies: a type=expansion graph.v2 fragment with the full
# var contract and a single analyze template that resolves a diff, persists
# durable inputs, and runs an eligibility gate.

section "01 fragment integrity"

# --- top-level: an expansion fragment on the graph.v2 contract ---------------
assert_eq "expansion-standard-reviewer" "$(formula_py formula-name)" "formula name"
assert_eq "graph.v2"  "$(formula_py contract)" "graph.v2 contract"
assert_eq "expansion" "$(formula_py ftype)"    "type = expansion (canonical fragment)"

# --- vars: the full contract (4 shared + 6 per-lane model vars), with defaults -
# The single review_model of the skeleton is superseded by six per-lane model
# vars (gcs-f4j.8.2): each lens is a separate dispatch, so each rides its own
# opt_model, right-sized by tier.
defined="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "architecture_model aux_model base_branch docs_model performance_model quality_model review_target security_model severity_threshold synthesis_model testing_model " "$defined" \
  "defines the shared vars + 6 per-lane model vars + synthesis_model (review_model superseded)"

assert_eq ""       "$(formula_py var-default review_target)"      "review_target default = empty (base_branch..HEAD)"
assert_eq "main"   "$(formula_py var-default base_branch)"        "base_branch default = main"
assert_eq "haiku"  "$(formula_py var-default aux_model)"          "aux_model default = haiku"
assert_eq "minor"  "$(formula_py var-default severity_threshold)" "severity_threshold default = minor"
assert_eq ""       "$(formula_py var-default review_model 2>/dev/null)" "review_model removed (superseded by per-lane vars)"

# Per-lane model defaults are tiered: deep (opus) for the judgment lenses, standard
# (sonnet) for quality/performance, cheap (haiku) for the mechanical lenses.
assert_eq "sonnet" "$(formula_py var-default quality_model)"      "quality_model default = sonnet (standard tier)"
assert_eq "opus"   "$(formula_py var-default security_model)"     "security_model default = opus (deep tier)"
assert_eq "sonnet" "$(formula_py var-default performance_model)"  "performance_model default = sonnet (standard tier)"
assert_eq "opus"   "$(formula_py var-default architecture_model)" "architecture_model default = opus (deep tier)"
assert_eq "haiku"  "$(formula_py var-default testing_model)"      "testing_model default = haiku (cheap tier)"
assert_eq "haiku"  "$(formula_py var-default docs_model)"         "docs_model default = haiku (cheap tier)"
assert_eq "opus"   "$(formula_py var-default synthesis_model)"    "synthesis_model default = opus (deep tier — dedup + severity is judgment)"

# --- expansion syntax: single-brace var refs, no {{double}} drift ------------
# Expansion templates substitute {name}, not {{name}}; a stray {{var}} would
# render as a literal {value} and silently break. Pin zero double-brace refs and
# that every defined var IS referenced single-brace somewhere in the template.
assert_eq "0" "$(formula_py double-braces)" "no {{double-brace}} var refs (expansion uses single brace)"
refs="$(formula_py var-refs | tr '\n' ' ')"
assert_eq "architecture_model aux_model base_branch docs_model performance_model quality_model review_target security_model severity_threshold synthesis_model testing_model " "$refs" \
  "every defined var is referenced single-brace (no dangling var)"

# The review-target var is review_target, NOT target — {target} is the reserved
# expansion placeholder. Guard the rename so a future edit cannot reintroduce a
# `target` var that would be shadowed by the placeholder.
assert_eq "" "$(formula_py var-default target 2>/dev/null)" "no var literally named 'target' (reserved placeholder)"

# --- eight templates: the analyze pass + the six review lenses + synthesis ----
tids="$(formula_py template-ids | tr '\n' ' ')"
assert_eq "{target}.analyze {target}.quality {target}.security {target}.performance {target}.architecture {target}.testing {target}.docs {target}.synthesis " \
  "$tids" "eight templates: analyze + the six lenses + synthesis (gcs-f4j.8.3)"

# Every step id uses the {target} expansion placeholder so the host's placeholder
# step id prefixes it (review-pipeline.analyze in the loop, etc).
for sid in analyze quality security performance architecture testing docs synthesis; do
  assert_contains "$tids" "{target}.$sid " "step {target}.$sid carries the {target} expansion placeholder"
done

# --- analyze is a pool-dispatched lane ---------------------------------------
assert_eq "gasvillage.polecat" "$(formula_py meta '{target}.analyze' gc.run_target)" \
  "analyze gc.run_target = gasvillage.polecat"

# --- the six lenses: separate dispatch, depend on analyze, per-lane opt_model -
# Each lens is its OWN step (own session) so per-lane model selection rides its
# opt_model metadata; all six depend on the analyze pass's durable inputs.
lens_model() { # <lens> -> the single-brace var its opt_model references
  case "$1" in
    quality) echo "{quality_model}" ;; security) echo "{security_model}" ;;
    performance) echo "{performance_model}" ;; architecture) echo "{architecture_model}" ;;
    testing) echo "{testing_model}" ;; docs) echo "{docs_model}" ;;
  esac
}
for lens in quality security performance architecture testing docs; do
  assert_eq "gasvillage.polecat" "$(formula_py meta "{target}.$lens" gc.run_target)" \
    "$lens lane gc.run_target = gasvillage.polecat (separate dispatch)"
  assert_eq "{target}.analyze" "$(formula_py needs "{target}.$lens" | tr '\n' ' ' | sed 's/ $//')" \
    "$lens lane needs {target}.analyze"
  assert_eq "$(lens_model "$lens")" "$(formula_py meta "{target}.$lens" opt_model)" \
    "$lens lane opt_model references its per-lane model var"
done

# --- the six lenses: diff-scoped, self-contained, wisp convention ------------
# Each lane must read the durable inputs (not session memory), scope to the
# changed surface, gate on eligibility, and file category-labelled wisps with a
# Confidence self-rating — the breadth the standard reviewer adds over triage.
for lens in quality security performance architecture testing docs; do
  D="$(formula_py desc "{target}.$lens")"
  assert_contains "$D" "review-lane.sh"        "$lens lane sources the shared lane helper"
  assert_contains "$D" "review_lane_load_inputs" "$lens lane loads the durable analyze inputs"
  assert_contains "$D" "REVIEW_ELIGIBLE"       "$lens lane gates on the eligibility verdict"
  assert_contains "$D" "changed surface"       "$lens lane scopes to the changed surface (diff-scoped)"
  assert_contains "$D" "category:$lens"        "$lens lane files category:$lens wisps"
  assert_contains "$D" "Confidence: X/100"     "$lens lane uses the Confidence self-rating wisp convention"
  assert_contains "$D" "clean pass"            "$lens lane self-skips to a clean pass with zero findings"
done

# --- analyze prompt: the three jobs it owns ----------------------------------
DESC="$(formula_py desc '{target}.analyze')"
assert_contains "$DESC" "ANALYZE pass"      "analyze documents itself as the analyze pass"
assert_contains "$DESC" "DURABLE"           "analyze persists DURABLE artifacts (not session memory)"
assert_contains "$DESC" "eligibility"       "analyze runs an eligibility gate"
assert_contains "$DESC" "change summary"    "analyze produces a change summary"
assert_contains "$DESC" "self-contained"    "analyze frames lanes as self-contained beads"

# --- synthesis pass (gcs-f4j.8.3): single dispatch, needs all 6, judgment tier -
# The 8th pass runs once, AFTER every lens, at the deep (opus) tier — it sees
# every candidate, dedup-merges, severity-ranks, and promotes durable findings.
assert_eq "gasvillage.polecat" "$(formula_py meta '{target}.synthesis' gc.run_target)" \
  "synthesis gc.run_target = gasvillage.polecat (single dispatch)"
assert_eq "{synthesis_model}" "$(formula_py meta '{target}.synthesis' opt_model)" \
  "synthesis opt_model references the synthesis_model var"
synth_needs="$(formula_py needs '{target}.synthesis' | tr '\n' ' ')"
for lens in quality security performance architecture testing docs; do
  assert_contains "$synth_needs" "{target}.$lens" "synthesis needs the $lens lane (sees every candidate)"
done

# --- synthesis prompt: dedup + severity + the shared promote/verdict transport -
SDESC="$(formula_py desc '{target}.synthesis')"
assert_contains "$SDESC" "review-synthesis.sh"  "synthesis sources the shared synthesis helper"
assert_contains "$SDESC" "review_synthesis_load" "synthesis loads the run via the shared helper"
assert_contains "$SDESC" "conservative"         "synthesis dedup-merges conservatively (same file/lines/root cause; keep separate when in doubt)"
assert_contains "$SDESC" "the same file"        "synthesis merges only candidates sharing the same file"
assert_contains "$SDESC" "review_synthesis_promote" "synthesis promotes survivors to durable finding beads"
assert_contains "$SDESC" "review_synthesis_record_verdict" "synthesis records the verdict via the shared helper"
assert_contains "$SDESC" "severity_threshold"   "synthesis is severity-gated by the threshold var"
assert_contains "$SDESC" "pass_with_findings"   "synthesis defines the pass/pass_with_findings/fail verdict contract"
