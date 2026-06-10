# Host integrity — pure structural assertions over the TOML (no gc needed).
#
# A thin host's whole contract is (a) ONE placeholder step, (b) the compose.expand
# that targets it with the canonical fragment, and (c) the var block that
# propagates the fragment's full var contract — mapping the host's `target` onto
# the fragment's `review_target` and every other var 1:1. This test pins all three,
# plus a NO-DRIFT cross-check: if the fragment gains or renames a var, the host must
# propagate it or this fails.

section "01 host integrity"

# --- top-level shape ---------------------------------------------------------
assert_eq "mol-triage-review-independent" "$(formula_py formula-name)" "formula name is mol-triage-review-independent"
assert_eq "graph.v2" "$(formula_py contract)" "contract is graph.v2"
assert_eq "1" "$(formula_py step-count)" "exactly one placeholder step (thin host)"
assert_eq "review-pipeline" "$(formula_py step-ids)" "placeholder step id is review-pipeline"
assert_eq "gasvillage.polecat" "$(formula_py step-meta review-pipeline gc.run_target)" \
  "placeholder carries gc.run_target=gasvillage.polecat"

# --- exactly one compose.expand, targeting the placeholder with the fragment --
assert_eq "1" "$(formula_py expand-count)" "exactly one compose.expand rule"
assert_eq "review-pipeline" "$(formula_py expand-target)" "expand targets the placeholder step"
assert_eq "expansion-triage-reviewer" "$(formula_py expand-with)" \
  "expand pulls in the canonical triage reviewer fragment"

# --- NO-DRIFT: the expand vars keys reproduce the fragment's var contract,
#     with the host's `target` mapping onto the fragment's `review_target` -----
frag_vars="$(fragment_vars | tr '\n' ' ')"
expand_keys="$(formula_py expand-var-keys | tr '\n' ' ')"
assert_eq "$frag_vars" "$expand_keys" \
  "compose.expand maps EVERY fragment var (and only those) — no drift"
assert_contains "$expand_keys" "review_target" "fragment's review_target is propagated"
assert_not_contains "$expand_keys" " target " "the bare name 'target' is reserved (not a fragment var)"

# --- the host re-declares the same contract, renamed: target replaces
#     review_target, every other var 1:1 ----------------------------------------
host_vars="$(formula_py defined-vars | tr '\n' ' ')"
expected_host="$(fragment_vars | sed 's/^review_target$/target/' | sort | tr '\n' ' ')"
assert_eq "$expected_host" "$host_vars" \
  "host declares the fragment's contract with review_target renamed to target"

# --- every expand var VALUE is a single-brace ref to a DEFINED host var -------
assert_eq "0" "$(formula_py double-braces-in-vars)" \
  "override vars are single-brace (compile-time), never {{double}}"

undefined=""
referenced=""
while IFS= read -r key; do
  val="$(formula_py expand-var "$key")"
  ref="${val#\{}"; ref="${ref%\}}"
  case "$val" in
    "{$ref}") : ;;
    *) fail "expand var $key value is a bare single-brace ref" "got [$val]" ; continue ;;
  esac
  if formula_py defined-vars | grep -qx "$ref"; then
    ok "$key <- {$ref} (defined host var)"
  else
    undefined="$undefined $ref"
  fi
  referenced="$referenced $ref"
done < <(formula_py expand-var-keys)
assert_eq "" "$undefined" "no expand var maps from an undefined host var"

# the rename seam: review_target must map from the host's target var
assert_eq "{target}" "$(formula_py expand-var review_target)" "review_target <- {target} (the rename seam)"

# --- every defined host var is actually propagated (no dead var) -------------
unused=""
while IFS= read -r v; do
  case " $referenced " in *" $v "*) : ;; *) unused="$unused $v" ;; esac
done < <(formula_py defined-vars)
assert_eq "" "$unused" "every declared host var is propagated into the fragment"

# --- defaults mirror the fragment's defaults (un-tuned sling == fragment) -----
while IFS= read -r line; do
  fname="${line%%=*}"; fdef="${line#*=}"
  hname="$fname"; [ "$fname" = "review_target" ] && hname="target"
  assert_eq "$fdef" "$(formula_py var-default "$hname")" "default $hname mirrors fragment $fname (=$fdef)"
done < <(fragment_var_defaults)
