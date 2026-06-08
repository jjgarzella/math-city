# Formula integrity — deterministic structural + textual assertions over the
# mol-review-loop TOML. Locks down the reviewer-agnostic loop shape the epic
# (gcs-f4j.3) specifies: ralph [steps.check] over [review-pipeline -> apply-fixes],
# pooled apply-fixes, the verdict-glue check wiring, the cap, and the absence of
# any abort_scope / on_complete construct.

section "01 formula integrity"

# --- parses with the expected top-level shape --------------------------------
assert_eq "mol-review-loop" "$(formula_py formula-name)" "formula name is mol-review-loop"
assert_eq "graph.v2"        "$(formula_py contract)"     "graph.v2 contract"

# --- vars: exactly the three tunables, all referenced ------------------------
defined="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "base_branch notify_target target " "$defined" "defines exactly base_branch, notify_target, target"

undefined=""
while IFS= read -r ref; do
  formula_py defined-vars | grep -qx "$ref" || undefined="$undefined $ref"
done < <(formula_py template-refs)
assert_eq "" "$undefined" "no template ref points at an undefined var"

assert_eq "main" "$(formula_py var-default base_branch)"  "base_branch default = main"
assert_eq ""     "$(formula_py var-default target)"       "target default = empty (base_branch..HEAD)"
assert_eq ""     "$(formula_py var-default notify_target)" "notify_target default = empty (notify disabled)"

# --- top-level steps: workspace-setup -> review-loop -------------------------
steps="$(formula_py step-ids | tr '\n' ' ')"
assert_eq "workspace-setup review-loop " "$steps" "two top-level steps: workspace-setup, review-loop"

# --- review-loop is a ralph [steps.check] with the cap + exec verdict check --
assert_eq "3"                    "$(formula_py ralph-max review-loop)"           "iteration cap max_attempts = 3"
assert_eq "exec"                 "$(formula_py ralph-check review-loop mode)"    "check mode = exec"
assert_eq ".gc-review-verdict.sh" "$(formula_py ralph-check review-loop path)"   "check path = .gc-review-verdict.sh (work_dir-relative)"
assert_eq "120s"                 "$(formula_py ralph-check review-loop timeout)" "check timeout = 120s"

# --- body children: [review-pipeline -> apply-fixes] -------------------------
children="$(formula_py child-ids review-loop | tr '\n' ' ')"
assert_eq "review-pipeline apply-fixes " "$children" "body children: review-pipeline then apply-fixes"

# --- apply-fixes is pool-dispatched to the polecat ---------------------------
assert_eq "gasvillage.polecat" "$(formula_py meta apply-fixes gc.run_target)" \
  "apply-fixes gc.run_target = gasvillage.polecat (pool-dispatched, fresh ctx/iteration)"

# --- review-pipeline is the placeholder reviewer slot ------------------------
PIPE_DESC="$(formula_py desc review-pipeline)"
assert_contains "$PIPE_DESC" "PLACEHOLDER" "review-pipeline is documented as the placeholder reviewer slot"
assert_contains "$PIPE_DESC" "compose.expand" "review-pipeline notes the quorum variant replaces it via compose.expand"

# The BASE loop wires NO [compose] — the quorum variant (gcs-f4j.5) adds it.
assert_eq "no" "$(formula_py has-compose)" "base loop declares no [compose] block (quorum variant adds it)"

# --- apply-fixes: fix-mode interface + verdict glue --------------------------
FIX_DESC="$(formula_py desc apply-fixes)"
assert_contains "$FIX_DESC" "gcs-6r2"            "apply-fixes attributes the fix-mode interface to gcs-6r2"
assert_contains "$FIX_DESC" "review.verdict"     "apply-fixes sets review.verdict (the loop's glue)"
assert_contains "$FIX_DESC" "VERDICT=done"       "apply-fixes verdict glue defaults base loop to done (no findings)"
# The verdict vocabulary matches what the shared check maps to exit 0/1.
assert_contains "$FIX_DESC" "iterate" "apply-fixes documents the iterate verdict"

# --- NO abort_scope / on_complete construct ----------------------------------
# The loop terminates via the cap + verdict only. The words may appear in prose
# (it documents "NO abort_scope"); what must be absent is any TOML directive.
if grep -nE '^[[:space:]]*(on_complete|on_fail)[[:space:]]*=' "$FORMULA" >/dev/null 2>&1; then
  fail "no on_complete/on_fail directive" "found a termination directive in $FORMULA"
else
  ok "no on_complete/on_fail directive (loop terminates via cap + verdict only)"
fi
if grep -nE '^\[\[?(steps\.)?on_complete' "$FORMULA" >/dev/null 2>&1; then
  fail "no [steps.on_complete] table" "found an on_complete table in $FORMULA"
else
  ok "no [steps.on_complete] table"
fi
assert_eq "" "$(formula_py meta apply-fixes gc.on_fail)"     "apply-fixes sets no gc.on_fail (no abort_scope override)"
assert_eq "" "$(formula_py meta review-pipeline gc.on_fail)" "review-pipeline sets no gc.on_fail"

# --- no-drift: workspace-setup installs exactly the file the check reads ------
SETUP_BLOCK="$(formula_py block workspace-setup '.gc-review-verdict.sh')"
assert_contains "$SETUP_BLOCK" 'formulas/lib/review-verdict.sh' \
  "workspace-setup installs the shared lib (single source of truth)"
assert_contains "$SETUP_BLOCK" 'GC_CITY' \
  "workspace-setup references the lib via \$GC_CITY (branch-independent)"
assert_contains "$SETUP_BLOCK" 'cp -f "$VERDICT_SRC" "$WORK_DIR/.gc-review-verdict.sh"' \
  "workspace-setup copies the lib to the work_dir-relative check path the ralph step reads"
assert_contains "$SETUP_BLOCK" 'gc.review_loop.notify' \
  "workspace-setup records the optional notify target on the root"
assert_contains "$SETUP_BLOCK" 'work_dir=' \
  "workspace-setup records work_dir on the root (the ralph control inherits it)"
