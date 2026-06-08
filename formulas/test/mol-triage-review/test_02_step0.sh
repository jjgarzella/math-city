# Step 0 — target -> diff resolution. Step 0 calls the SHARED vendor-neutral
# resolver (../../lib/resolve-diff.sh — the single source of truth the quorum
# reviewer lanes call too), so this suite tests THAT SCRIPT directly (run_step0)
# against throwaway git repos. It is pure transport ("no judgment; run it
# verbatim"), so it is fully deterministic.
#
# Covers acceptance [2] (empty diff -> clean stop) deterministically, and the
# deterministic precondition behind acceptance [3] (a local/no-PR target
# resolves to kind=branch|range, never pr — which is what makes angle (d)
# self-skip downstream). Also pins the path-rejection and PR/range/branch
# classification the resolver promises, its two-channel output contract, and
# the formula's wiring to it (so the two never drift).

section "02 step-0 diff resolution"

commit() { # commit <repo> <file> <content> <msg>
  ( cd "$1"; printf '%s\n' "$3" > "$2"; git add "$2"; git commit -q -m "$4" )
}

# --- empty diff -> hard stop, exit 0, nothing to review (acceptance [2]) ------
repo="$(new_git_repo)"
run_step0 "$repo" ""; out="$STEP0_OUT"          # "" -> main..HEAD, HEAD==main -> empty
assert_eq "0" "$STEP0_RC" "empty diff exits 0 (clean, nothing to review)"
assert_contains "$out" "EMPTY diff" "empty diff reports 'EMPTY diff; nothing to review'"
assert_not_contains "$out" "Resolved target kind=" "empty diff does not proceed into the pipeline"
rm -rf "$repo"

# --- path / whole-tree targets are rejected (exit 2) -------------------------
repo="$(new_git_repo)"
for p in "." "./pkg" "/etc/passwd" ".." "../sibling"; do
  run_step0 "$repo" "$p"; out="$STEP0_OUT"
  assert_eq "2" "$STEP0_RC" "path target '$p' rejected with exit 2"
  assert_contains "$out" "looks like a path" "path target '$p' explains the rejection"
done
# a real file that exists but is not a ref also rejected via the bare-ref guard
run_step0 "$repo" "seed.txt"; out="$STEP0_OUT"
assert_eq "2" "$STEP0_RC" "existing file 'seed.txt' rejected (not a PR/branch/range)"
assert_contains "$out" "is a filesystem path" "existing-file rejection is explicit"
rm -rf "$repo"

# --- commit-range target -> kind=range, real git diff (no gh) ----------------
repo="$(new_git_repo)"
commit "$repo" app.go "package app // v2" "change app"
run_step0 "$repo" "HEAD~1..HEAD"; out="$STEP0_OUT"
assert_eq "0" "$STEP0_RC" "range target resolves (exit 0)"
assert_contains "$out" "kind=range" "range target -> TARGET_KIND=range"
assert_contains "$out" "app.go" "range target lists the touched file"
assert_not_contains "$out" "gh stub" "range path never invokes gh (local, no PR)"
rm -rf "$repo"

# --- bare branch target -> kind=branch, 3-dot diff vs base (no gh) -----------
repo="$(new_git_repo)"
( cd "$repo"; git checkout -q -b feature; )
commit "$repo" feature.go "package feature" "add feature"
( cd "$repo"; git checkout -q main )
run_step0 "$repo" "feature"; out="$STEP0_OUT"
assert_eq "0" "$STEP0_RC" "branch target resolves (exit 0)"
assert_contains "$out" "kind=branch" "bare branch -> TARGET_KIND=branch"
assert_contains "$out" "feature.go" "branch target lists the branch-introduced file"
assert_not_contains "$out" "gh stub" "branch path never invokes gh (local, no PR)"
rm -rf "$repo"

# --- PR targets -> kind=pr, via gh (number, #number, URL) --------------------
repo="$(new_git_repo)"
for t in "42" "#42" "https://github.com/o/r/pull/7"; do
  run_step0 "$repo" "$t"; out="$STEP0_OUT"
  assert_eq "0" "$STEP0_RC" "PR target '$t' resolves (exit 0)"
  assert_contains "$out" "kind=pr" "PR target '$t' -> TARGET_KIND=pr"
  assert_contains "$out" "widget.go" "PR target '$t' carries the gh diff"
done
rm -rf "$repo"

# --- the shared resolver exists, is executable, and is valid bash ------------
section "02b shared resolver — component"
[ -f "$RESOLVER" ] && ok "resolve-diff.sh present at $RESOLVER" \
  || fail "resolve-diff.sh present" "missing at $RESOLVER"
[ -x "$RESOLVER" ] && ok "resolve-diff.sh is executable" \
  || fail "resolve-diff.sh is executable"
bash -n "$RESOLVER" 2>/dev/null && ok "resolve-diff.sh parses (bash -n)" \
  || fail "resolve-diff.sh parses (bash -n)"

# --- two-channel output contract: machine result on stdout, narration on stderr
# A real diff: stdout carries the eval-able TARGET_KIND/DIFF_FILE/FILES_FILE and
# the named files actually exist; the diff is non-empty. An empty diff: stdout
# is empty (that emptiness is the clean-stop signal a script caller branches on).
repo="$(new_git_repo)"
commit "$repo" app.go "package app // v2" "change app"
run_step0 "$repo" "HEAD~1..HEAD"
assert_contains "$STEP0_STDOUT" "TARGET_KIND=range" "stdout carries machine TARGET_KIND"
assert_contains "$STEP0_STDOUT" "DIFF_FILE=" "stdout carries machine DIFF_FILE"
assert_contains "$STEP0_STDOUT" "FILES_FILE=" "stdout carries machine FILES_FILE"
# the assignments are eval-able and point at real, non-empty artifacts
( eval "$STEP0_STDOUT"
  [ -s "$DIFF_FILE" ] && [ -f "$FILES_FILE" ] ) \
  && ok "stdout evals to real DIFF_FILE (non-empty) + FILES_FILE" \
  || fail "stdout evals to real DIFF_FILE (non-empty) + FILES_FILE"
rm -rf "$repo"

repo="$(new_git_repo)"
run_step0 "$repo" ""                              # main..HEAD, HEAD==main -> empty
assert_eq "" "$STEP0_STDOUT" "empty diff emits NO machine result on stdout (clean-stop signal)"
rm -rf "$repo"

# --- the formula wires step 0 to the shared resolver (no drift) --------------
# The behavioral tests above exercise the script directly; this pins that the
# formula actually delegates to it and passes both vars, so the two cannot drift.
DESC0="$(formula_py step-desc)"
assert_contains "$DESC0" "formulas/lib/resolve-diff.sh" "step 0 calls the shared resolver path"
assert_contains "$DESC0" "GC_CITY" "step 0 locates the resolver via \$GC_CITY (branch-independent)"
assert_contains "$DESC0" '"{{target}}" "{{base_branch}}"' "step 0 passes target + base_branch to the resolver"
assert_not_contains "$DESC0" 'git diff "${BASE}...${TARGET}"' "step 0 no longer inlines the resolver (extracted, DRY)"
