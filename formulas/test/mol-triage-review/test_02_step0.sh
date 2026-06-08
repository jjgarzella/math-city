# Step 0 — target -> diff resolution. This block is pure transport ("no
# judgment; run it verbatim"), so it is fully deterministic and tested by
# running the extracted block against throwaway git repos.
#
# Covers acceptance [2] (empty diff -> clean stop) deterministically, and the
# deterministic precondition behind acceptance [3] (a local/no-PR target
# resolves to kind=branch|range, never pr — which is what makes angle (d)
# self-skip downstream). Also pins the path-rejection and PR/range/branch
# classification the formula promises.

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
