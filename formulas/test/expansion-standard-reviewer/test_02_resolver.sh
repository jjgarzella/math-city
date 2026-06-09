# The analyze step delegates target->diff resolution to the SHARED, vendor-neutral
# resolver (../../lib/resolve-diff.sh — the single source of truth the triage
# reviewer calls too). This suite pins (a) the resolver contract the analyze step
# relies on, exercised directly against throwaway repos, and (b) that the formula
# actually wires to the shared resolver and passes both vars, so the two cannot
# drift. (The exhaustive resolver matrix lives in the triage suite; here we pin
# only the classifications the analyze branches key on: range/branch/pr/empty/path.)

section "02 shared resolver — contract the analyze step depends on"

commit() { # commit <repo> <file> <content> <msg>
  ( cd "$1"; printf '%s\n' "$3" > "$2"; git add "$2"; git commit -q -m "$4" )
}

# present, executable, valid bash
[ -f "$RESOLVER" ] && ok "resolve-diff.sh present at $RESOLVER" || fail "resolve-diff.sh present" "missing"
[ -x "$RESOLVER" ] && ok "resolve-diff.sh is executable" || fail "resolve-diff.sh is executable"
bash -n "$RESOLVER" 2>/dev/null && ok "resolve-diff.sh parses (bash -n)" || fail "resolve-diff.sh parses"

# empty diff -> exit 0, empty machine stdout (the analyze 'empty' branch keys on this)
repo="$(new_git_repo)"
run_step0 "$repo" ""
assert_eq "0" "$STEP0_RC" "empty diff exits 0 (clean)"
assert_eq "" "$STEP0_STDOUT" "empty diff emits NO machine result (analyze -> TARGET_KIND=empty)"
rm -rf "$repo"

# path / whole-tree -> exit 2 (the analyze 'path' whole-repo-audit branch keys on this)
repo="$(new_git_repo)"
for p in "." "./pkg" "/etc/passwd"; do
  run_step0 "$repo" "$p"
  assert_eq "2" "$STEP0_RC" "path target '$p' -> exit 2 (analyze -> whole-repo audit)"
done
rm -rf "$repo"

# range -> kind=range with a real git diff, eval-able machine stdout
repo="$(new_git_repo)"
commit "$repo" app.go "package app // v2" "change app"
run_step0 "$repo" "HEAD~1..HEAD"
assert_eq "0" "$STEP0_RC" "range target resolves (exit 0)"
assert_contains "$STEP0_STDOUT" "TARGET_KIND=range" "range -> TARGET_KIND=range on stdout"
assert_contains "$STEP0_STDOUT" "DIFF_FILE=" "range stdout carries DIFF_FILE"
( eval "$STEP0_STDOUT"; [ -s "$DIFF_FILE" ] && [ -f "$FILES_FILE" ] ) \
  && ok "range stdout evals to a real non-empty DIFF_FILE + FILES_FILE" \
  || fail "range stdout evals to real artifacts"
rm -rf "$repo"

# bare branch -> kind=branch (no gh)
repo="$(new_git_repo)"
( cd "$repo"; git checkout -q -b feature )
commit "$repo" feature.go "package feature" "add feature"
( cd "$repo"; git checkout -q main )
run_step0 "$repo" "feature"
assert_eq "0" "$STEP0_RC" "branch target resolves (exit 0)"
assert_contains "$STEP0_STDOUT" "TARGET_KIND=branch" "bare branch -> TARGET_KIND=branch"
rm -rf "$repo"

# PR -> kind=pr via the gh stub
repo="$(new_git_repo)"
run_step0 "$repo" "42"
assert_eq "0" "$STEP0_RC" "PR target resolves via gh stub (exit 0)"
assert_contains "$STEP0_STDOUT" "TARGET_KIND=pr" "PR target -> TARGET_KIND=pr"
rm -rf "$repo"

# --- no-drift: the analyze step wires to the shared resolver + passes both vars
section "02b analyze -> resolver wiring (no drift)"
RAW="$(formula_py desc '{target}.analyze')"
assert_contains "$RAW" 'formulas/lib/resolve-diff.sh' "analyze calls the shared resolver path"
assert_contains "$RAW" 'GC_CITY' "analyze locates the resolver via \$GC_CITY (branch-independent)"
assert_contains "$RAW" '"{review_target}" "{base_branch}"' "analyze passes review_target + base_branch to the resolver"
assert_not_contains "$RAW" 'git diff "${BASE}...${TARGET}"' "analyze does not inline the resolver git logic (DRY)"
# the analyze step keys its branches on the resolver's exit codes + empty stdout
assert_contains "$RAW" 'RC" -eq 2' "analyze handles resolver exit 2 (path -> whole-repo audit)"
assert_contains "$RAW" 'RC" -eq 3' "analyze handles resolver exit 3 (PR fetch failed)"
assert_contains "$RAW" '-z "$RESOLVED"' "analyze handles empty machine stdout (empty diff)"
