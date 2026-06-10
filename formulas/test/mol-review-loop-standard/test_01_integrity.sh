# Formula integrity — pure structural assertions over the TOML (no gc needed).
#
# mol-review-loop-standard is the codex-free standard-reviewer review->fix loop
# variant: the SAME reviewer-agnostic loop shape as mol-review-loop (ralph
# [steps.check] over [review-pipeline -> apply-fixes], reusing the shared
# review-verdict.sh check) with (a) a [[compose.expand]] that materializes the
# canonical expansion-standard-reviewer fragment into the review-pipeline slot,
# and (b) a REAL apply-fixes that maps the reviewer's synthesis verdict via the
# shared review-apply-fixes.sh. This test pins all of that, plus a NO-DRIFT
# cross-check: if the fragment gains or renames a var, the loop must propagate it.

section "01 formula integrity"

# --- top-level shape ---------------------------------------------------------
assert_eq "mol-review-loop-standard" "$(formula_py formula-name)" "formula name is mol-review-loop-standard"
assert_eq "graph.v2" "$(formula_py contract)" "contract is graph.v2"

# --- two top-level steps: workspace-setup -> review-loop ---------------------
steps="$(formula_py step-ids | tr '\n' ' ')"
assert_eq "workspace-setup review-loop " "$steps" "two top-level steps: workspace-setup, review-loop"

# --- review-loop is a ralph [steps.check] with the cap + the SHARED exec check
assert_eq "3"                     "$(formula_py ralph-max review-loop)"           "iteration cap max_attempts = 3"
assert_eq "exec"                  "$(formula_py ralph-check review-loop mode)"    "check mode = exec"
assert_eq ".gc-review-verdict.sh" "$(formula_py ralph-check review-loop path)"    "check path = .gc-review-verdict.sh (the SHARED verdict glue, work_dir-relative)"
assert_eq "120s"                  "$(formula_py ralph-check review-loop timeout)" "check timeout = 120s"

# --- body children: [review-pipeline -> apply-fixes] -------------------------
children="$(formula_py child-ids review-loop | tr '\n' ' ')"
assert_eq "review-pipeline apply-fixes " "$children" "body children: review-pipeline then apply-fixes"
assert_eq "gasvillage.polecat" "$(formula_py meta review-pipeline gc.run_target)" \
  "review-pipeline gc.run_target = gasvillage.polecat"
assert_eq "gasvillage.polecat" "$(formula_py meta apply-fixes gc.run_target)" \
  "apply-fixes gc.run_target = gasvillage.polecat (fresh ctx/iteration)"

# --- review-pipeline is the compose.expand'd reviewer slot -------------------
PIPE_DESC="$(formula_py desc review-pipeline)"
assert_contains "$PIPE_DESC" "PLACEHOLDER"    "review-pipeline is documented as the placeholder reviewer slot"
assert_contains "$PIPE_DESC" "compose.expand" "review-pipeline notes it is replaced via compose.expand"
assert_contains "$PIPE_DESC" "synthesis"      "review-pipeline notes the expanded synthesis output apply-fixes consumes"

# --- vars: fragment contract (target<-review_target rename) + loop knobs ------
host_vars="$(formula_py defined-vars | tr '\n' ' ')"
expected_host="$( { fragment_vars | sed 's/^review_target$/target/'; echo notify_target; } | sort | tr '\n' ' ')"
assert_eq "$expected_host" "$host_vars" \
  "loop declares the fragment contract (review_target->target) plus notify_target"

assert_eq "main"  "$(formula_py var-default base_branch)"       "base_branch default = main"
assert_eq ""      "$(formula_py var-default target)"            "target default = empty (base_branch..HEAD)"
assert_eq "minor" "$(formula_py var-default severity_threshold)" "severity_threshold default = minor (fix blocker/major/minor, surface nit)"
assert_eq ""      "$(formula_py var-default notify_target)"     "notify_target default = empty (notify disabled)"

# every {{template ref}} points at a defined var
undefined=""
while IFS= read -r ref; do
  formula_py defined-vars | grep -qx "$ref" || undefined="$undefined $ref"
done < <(formula_py template-refs)
assert_eq "" "$undefined" "no {{template ref}} points at an undefined var"

# --- compose.expand: one rule, the placeholder, the canonical fragment -------
assert_eq "yes" "$(formula_py has-compose)" "loop declares a [compose] block (unlike the base loop)"
assert_eq "1" "$(formula_py expand-count)" "exactly one compose.expand rule"
assert_eq "review-pipeline" "$(formula_py expand-target)" "expand targets the review-pipeline slot"
assert_eq "expansion-standard-reviewer" "$(formula_py expand-with)" \
  "expand pulls in the canonical reviewer fragment (same as mol-standard-review)"

# --- NO-DRIFT: the expand vars keys reproduce the fragment's full var contract
frag_vars="$(fragment_vars | tr '\n' ' ')"
expand_keys="$(formula_py expand-var-keys | tr '\n' ' ')"
assert_eq "$frag_vars" "$expand_keys" \
  "compose.expand maps EVERY fragment var (and only those) — no drift"
assert_contains "$expand_keys" "review_target" "fragment's review_target is propagated"

# every expand var VALUE is a single-brace ref to a DEFINED loop var (compile-time)
assert_eq "0" "$(formula_py double-braces-in-vars)" \
  "override vars are single-brace (compile-time), never {{double}}"
assert_eq "{target}" "$(formula_py expand-var review_target)" "review_target <- {target} (the rename seam)"

undefined=""
while IFS= read -r key; do
  val="$(formula_py expand-var "$key")"
  ref="${val#\{}"; ref="${ref%\}}"
  case "$val" in
    "{$ref}") : ;;
    *) fail "expand var $key value is a bare single-brace ref" "got [$val]"; continue ;;
  esac
  if formula_py defined-vars | grep -qx "$ref"; then
    ok "$key <- {$ref} (defined loop var)"
  else
    undefined="$undefined $ref"
  fi
done < <(formula_py expand-var-keys)
assert_eq "" "$undefined" "no expand var maps from an undefined loop var"

# severity_threshold is BOTH propagated to the fragment AND a {{template ref}}
# in apply-fixes (the one var that doubles as the apply-fixes fix threshold).
assert_eq "{severity_threshold}" "$(formula_py expand-var severity_threshold)" \
  "severity_threshold propagates into the fragment's synthesis threshold"
formula_py template-refs | grep -qx severity_threshold \
  && ok "severity_threshold is also referenced in a step ({{severity_threshold}} -> apply-fixes fix threshold)" \
  || fail "severity_threshold referenced in a step" "expected {{severity_threshold}} in apply-fixes"

# notify_target is a loop-only knob: referenced in a step, NOT propagated to the fragment.
assert_not_contains " $expand_keys " " notify_target " "notify_target is loop-only (not a fragment var)"
formula_py template-refs | grep -qx notify_target \
  && ok "notify_target is referenced in workspace-setup ({{notify_target}})" \
  || fail "notify_target referenced in a step" "expected {{notify_target}} in workspace-setup"

# --- defaults mirror the fragment's defaults (un-tuned sling == fragment) -----
while IFS= read -r line; do
  fname="${line%%=*}"; fdef="${line#*=}"
  hname="$fname"; [ "$fname" = "review_target" ] && hname="target"
  assert_eq "$fdef" "$(formula_py var-default "$hname")" "default $hname mirrors fragment $fname (=$fdef)"
done < <(fragment_var_defaults)

# --- apply-fixes wires the SHARED verdict->severity->fix machinery ------------
FIX_DESC="$(formula_py desc apply-fixes)"
assert_contains "$FIX_DESC" "formulas/lib/review-apply-fixes.sh" "apply-fixes sources the shared review-apply-fixes.sh lib"
assert_contains "$FIX_DESC" "review_apply_fixes_load"            "apply-fixes loads the run via the lib"
assert_contains "$FIX_DESC" "review_apply_fixes_map_verdict"     "apply-fixes maps the synthesis verdict via the lib"
assert_contains "$FIX_DESC" "review_apply_fixes_set_verdict"     "apply-fixes writes review.verdict via the lib"
assert_contains "$FIX_DESC" "review_apply_fixes_escalate"        "apply-fixes escalates (terminate-to-human) via the lib"
assert_contains "$FIX_DESC" "FIX_THRESHOLD=\"{{severity_threshold}}\"" "apply-fixes hands the loop's severity_threshold to the lib as FIX_THRESHOLD"
assert_contains "$FIX_DESC" "review.verdict"  "apply-fixes documents the loop's review.verdict glue"
assert_contains "$FIX_DESC" "blocked"         "apply-fixes documents the blocked verdict path"
assert_contains "$FIX_DESC" "TERMINATE-TO-HUMAN" "apply-fixes documents blocked -> terminate-to-human"
assert_contains "$FIX_DESC" "ZFC"             "apply-fixes attributes the fix-vs-surface decision to the agent (ZFC)"

# --- no-drift: workspace-setup installs exactly the SHARED check the base loop uses
SETUP_BLOCK="$(formula_py block workspace-setup '.gc-review-verdict.sh')"
assert_contains "$SETUP_BLOCK" 'formulas/lib/review-verdict.sh' \
  "workspace-setup installs the shared verdict-glue lib (single source of truth, reused)"
assert_contains "$SETUP_BLOCK" 'GC_CITY' \
  "workspace-setup references the lib via \$GC_CITY (branch-independent)"
assert_contains "$SETUP_BLOCK" 'cp -f "$VERDICT_SRC" "$WORK_DIR/.gc-review-verdict.sh"' \
  "workspace-setup copies the lib to the work_dir-relative check path"

# --- NO abort_scope / on_complete directive ----------------------------------
if grep -nE '^[[:space:]]*(on_complete|on_fail)[[:space:]]*=' "$FORMULA" >/dev/null 2>&1; then
  fail "no on_complete/on_fail directive" "found a termination directive in $FORMULA"
else
  ok "no on_complete/on_fail directive (loop terminates via cap + verdict only)"
fi
assert_eq "" "$(formula_py meta apply-fixes gc.on_fail)"     "apply-fixes sets no gc.on_fail (no abort_scope override)"
assert_eq "" "$(formula_py meta review-pipeline gc.on_fail)" "review-pipeline sets no gc.on_fail"
