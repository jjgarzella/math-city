# Formula integrity — deterministic structural + textual assertions over the
# mol-polecat-implement TOML. Locks down the lifecycle shape gcs-6r2/gcs-f4j.6
# specifies: a single-session feature-branch lifecycle whose NON-MERGING terminal
# pushes + triggers the reviewer-agnostic review loop + drains, and which records
# branch + work_dir on the work bead (the seam mol-review-loop resumes).

section "01 formula integrity"

RAW="$(cat "$FORMULA")"

# --- top-level shape ---------------------------------------------------------
assert_eq "mol-polecat-implement" "$(formula_py formula-name)" "formula name is mol-polecat-implement"
assert_eq "graph.v2"              "$(formula_py contract)"     "graph.v2 contract"

# --- vars: the tunables, all referenced --------------------------------------
defined="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "base_branch build_command lint_command review_formula setup_command test_command typecheck_command " \
  "$defined" "defines base_branch, review_formula, and the five rig formula_var commands"

undefined=""
while IFS= read -r ref; do
  formula_py defined-vars | grep -qx "$ref" || undefined="$undefined $ref"
done < <(formula_py template-refs)
assert_eq "" "$undefined" "no template ref points at an undefined var"

assert_eq "main"           "$(formula_py var-default base_branch)"    "base_branch default = main"
assert_eq "mol-review-loop" "$(formula_py var-default review_formula)" "review_formula default = mol-review-loop"
for v in setup_command typecheck_command lint_command build_command test_command; do
  assert_eq "" "$(formula_py var-default "$v")" "$v default = empty (rig formula_vars or skip)"
done

# --- steps: the linear lifecycle in order ------------------------------------
steps="$(formula_py step-ids | tr '\n' ' ')"
assert_eq "load-context workspace-setup preflight-tests implement self-review trigger-review " \
  "$steps" "six lifecycle steps in order"

# --- single session: every step is continuation-pinned to one polecat --------
for s in load-context workspace-setup preflight-tests implement self-review trigger-review; do
  assert_eq "main"    "$(formula_py meta "$s" gc.continuation_group)" "$s: gc.continuation_group = main"
  assert_eq "require" "$(formula_py meta "$s" gc.session_affinity)"   "$s: gc.session_affinity = require"
  # The lifecycle runs IN the slung polecat — never pool-dispatched per step.
  assert_eq ""        "$(formula_py meta "$s" gc.run_target)"         "$s: no gc.run_target (not pool-dispatched)"
done

# --- workspace-setup: idempotent resume + records the seam on the work bead --
WS="$(formula_py desc workspace-setup)"
assert_contains "$WS" 'BRANCH=$(meta branch)'  "workspace-setup resumes an existing recorded branch (idempotent)"
assert_contains "$WS" 'git worktree add'        "workspace-setup creates an isolated worktree when none is recorded"
assert_contains "$WS" 'checkout -B "$BRANCH" "origin/{{base_branch}}"' \
  "workspace-setup creates a fresh branch from the freshly-fetched origin tip"
assert_contains "$WS" 'bd update "$ROOT" --set-metadata work_dir=' \
  "workspace-setup records work_dir on the work bead (the seam mol-review-loop resumes)"
assert_contains "$WS" 'bd update "$ROOT" --set-metadata branch=' \
  "workspace-setup records branch on the work bead (resume + recovery)"
assert_contains "$WS" 'rejection_reason' \
  "workspace-setup honors fix-mode rejection_reason resume (rebase + clear)"

# --- post-setup steps re-enter the worktree (cwd does not persist) -----------
for s in preflight-tests implement self-review trigger-review; do
  assert_contains "$(formula_py desc "$s")" 'cd "$WORK_DIR"' "$s: re-enters the worktree before touching the tree"
done

# --- preflight + self-review run the rig CI commands -------------------------
for s in preflight-tests self-review; do
  D="$(formula_py desc "$s")"
  assert_contains "$D" '{{typecheck_command}}' "$s: runs typecheck_command"
  assert_contains "$D" '{{lint_command}}'      "$s: runs lint_command"
  assert_contains "$D" '{{test_command}}'      "$s: runs test_command"
done

# --- trigger-review: the NON-MERGING terminal --------------------------------
TR="$(formula_py desc trigger-review)"
assert_contains "$TR" 'git push'                       "trigger-review pushes the feature branch"
assert_contains "$TR" 'gc sling'                       "trigger-review slings the review loop"
assert_contains "$TR" '--on "{{review_formula}}"'      "trigger-review triggers the configurable review_formula (reviewer-agnostic)"
assert_contains "$TR" '--var "base_branch={{base_branch}}"' "trigger-review passes base_branch through to the review loop"
assert_contains "$TR" 'gasvillage.polecat'             "trigger-review routes the review loop to the polecat pool"
assert_contains "$TR" 'gc runtime drain-ack'           "trigger-review drains (fire-and-forget; releases the max=1 slot)"
assert_contains "$TR" 'do NOT close ROOT'              "trigger-review documents leaving the work bead open for the human gate"

# --- non-merging: the lifecycle never merges, never closes the work bead -----
# Closes ONLY step beads ($GC_BEAD_ID); ROOT (the work bead) stays open for review.
assert_not_contains "$RAW" 'bd close'                  "lifecycle never bd-closes a bead (human is the gate)"
assert_not_contains "$RAW" 'status=closed "$ROOT"'     "lifecycle never closes the work bead ROOT"
# This is the trigger-review variant, NOT the submit-to-refinery one.
assert_not_contains "$RAW" 'refinery'                  "non-merging variant: no refinery submission"
