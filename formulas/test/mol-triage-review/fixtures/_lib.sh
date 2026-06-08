# Helpers for fixture build.sh scripts. Each build.sh sources this, plants its
# change in a throwaway git repo, and leaves REPO (the worktree) + TARGET (the
# value to hand the formula's `target` var) set in the caller's shell.
#
# Used two ways:
#   - test_04 sources a build.sh, runs step-0 against $REPO/$TARGET, asserts.
#   - the .6 dogfood sources a build.sh and runs the real formula on $REPO with
#     `target=$TARGET` to watch the semantic outcome named in expected.env.

fx_init() { # fx_init [base-branch]  -> fresh repo in $REPO with a seed commit
  local base="${1:-main}"
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q -b "$base"
  git -C "$REPO" config user.email fixture@test.local
  git -C "$REPO" config user.name fixture
  printf 'package app\n' > "$REPO/app.go"
  git -C "$REPO" add app.go
  git -C "$REPO" commit -q -m seed
}

fx_commit() { # fx_commit <message>  -> stage everything under $REPO and commit
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "$1"
}
