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

# --- vars: exactly the five-tunable contract, with the documented defaults ----
defined="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "aux_model base_branch review_model review_target severity_threshold " "$defined" \
  "defines exactly aux_model, base_branch, review_model, review_target, severity_threshold"

assert_eq ""       "$(formula_py var-default review_target)"      "review_target default = empty (base_branch..HEAD)"
assert_eq "main"   "$(formula_py var-default base_branch)"        "base_branch default = main"
assert_eq "sonnet" "$(formula_py var-default review_model)"       "review_model default = sonnet"
assert_eq "haiku"  "$(formula_py var-default aux_model)"          "aux_model default = haiku"
assert_eq "minor"  "$(formula_py var-default severity_threshold)" "severity_threshold default = minor"

# --- expansion syntax: single-brace var refs, no {{double}} drift ------------
# Expansion templates substitute {name}, not {{name}}; a stray {{var}} would
# render as a literal {value} and silently break. Pin zero double-brace refs and
# that every defined var IS referenced single-brace somewhere in the template.
assert_eq "0" "$(formula_py double-braces)" "no {{double-brace}} var refs (expansion uses single brace)"
refs="$(formula_py var-refs | tr '\n' ' ')"
assert_eq "aux_model base_branch review_model review_target severity_threshold " "$refs" \
  "every defined var is referenced single-brace (no dangling var)"

# The review-target var is review_target, NOT target — {target} is the reserved
# expansion placeholder. Guard the rename so a future edit cannot reintroduce a
# `target` var that would be shadowed by the placeholder.
assert_eq "" "$(formula_py var-default target 2>/dev/null)" "no var literally named 'target' (reserved placeholder)"

# --- exactly one template today: the analyze pass ----------------------------
tids="$(formula_py template-ids | tr '\n' ' ')"
assert_eq "{target}.analyze " "$tids" "one template: {target}.analyze (lenses + synthesis land in .2/.3)"

# The step id uses the {target} expansion placeholder so the host's placeholder
# step id prefixes it (review-pipeline.analyze in the loop, etc).
assert_contains "$(formula_py template-ids)" "{target}." "analyze id carries the {target} expansion placeholder"

# --- analyze is a single pool-dispatched lane --------------------------------
assert_eq "gasvillage.polecat" "$(formula_py meta '{target}.analyze' gc.run_target)" \
  "analyze gc.run_target = gasvillage.polecat (single run_target)"

# --- analyze prompt: the three jobs it owns ----------------------------------
DESC="$(formula_py desc '{target}.analyze')"
assert_contains "$DESC" "ANALYZE pass"      "analyze documents itself as the analyze pass"
assert_contains "$DESC" "DURABLE"           "analyze persists DURABLE artifacts (not session memory)"
assert_contains "$DESC" "eligibility"       "analyze runs an eligibility gate"
assert_contains "$DESC" "change summary"    "analyze produces a change summary"
assert_contains "$DESC" "self-contained"    "analyze frames lanes as self-contained beads"
