#!/usr/bin/env bash
# resolve-diff.sh — shared, vendor-neutral target->diff resolver for the
# code-review formulas. The single source of truth for "what is the change under
# review": it turns a target (PR | branch | commit-range | base..HEAD) into a
# unified diff plus a list of touched files, IN THE CURRENT WORKING DIRECTORY
# (the checked-out worktree).
#
# Used by BOTH reviewers (DRY): mol-triage-review's step 0 and the Tier-2 quorum
# reviewer lanes each call this in their own checked-out worktree to resolve
# their own diff — robust cross-session, with no shared state between reviewer
# sessions. Pure transport: NO judgment, fully deterministic.
#
# Usage:   resolve-diff.sh <target> [base_branch]
#   <target>       PR (number | #number | PR URL) | branch name | commit range |
#                  base..HEAD. Empty -> <base_branch>..HEAD (the changes on this
#                  branch). A path / whole-tree target is rejected: these
#                  reviewers review CHANGES, not a tree.
#   [base_branch]  base the change is measured against. Default: main. Used for
#                  the default target and as the merge-base for a bare branch.
#
# Output contract — two channels, so an agent and a script can both consume it:
#   stderr  human narration: the resolved kind, the touched files, the temp-file
#           paths, and any rejection / empty-diff explanation.
#   stdout  machine-readable result, emitted ONLY for a non-empty resolved diff —
#           three shell assignments a caller can `eval` (or source):
#               TARGET_KIND=pr|branch|range
#               DIFF_FILE=<path to the unified diff>
#               FILES_FILE=<path to the newline-separated touched-file list>
#           On an empty diff stdout is empty: that emptiness IS the clean-stop
#           signal (there is nothing to review).
#
# Exit codes:
#   0  resolved (stdout carries the result) OR empty diff (stdout empty, nothing
#      to review — a clean stop);
#   2  the target is a path / not a PR|branch|range (nothing was resolved);
#   3  a PR diff could not be fetched (gh failed).
set -uo pipefail

TARGET="${1-}"
BASE="${2:-main}"

# Default: the changes on the current branch vs the base branch.
if [ -z "$TARGET" ]; then
  TARGET="${BASE}..HEAD"
fi

# Reject path / whole-tree targets. These reviewers review CHANGES, not a tree;
# whole-workspace review is a different job.
case "$TARGET" in
  "." | ".." | "./"* | "../"* | "/"*)
    echo "ERROR: '$TARGET' looks like a path. resolve-diff reviews a DIFF" >&2
    echo "       (PR | branch | commit-range | base_ref..HEAD), not a path or" >&2
    echo "       the whole workspace. Aborting." >&2
    exit 2 ;;
esac

DIFF_FILE="$(mktemp)"
FILES_FILE="$(mktemp)"

if printf '%s' "$TARGET" | grep -Eq '^#?[0-9]+$' \
   || printf '%s' "$TARGET" | grep -Eq '^https?://.*/pull/[0-9]+/?$'; then
  # --- PR: a number, #number, or a PR URL -> gh pr diff ---
  PR="${TARGET#\#}"
  TARGET_KIND="pr"
  # Per-invocation temp for gh's stderr so concurrent reviewer lanes never
  # collide on a shared path.
  GH_ERR="$(mktemp)"
  if ! gh pr diff "$PR" > "$DIFF_FILE" 2> "$GH_ERR"; then
    echo "ERROR: 'gh pr diff $PR' failed:" >&2; cat "$GH_ERR" >&2
    exit 3
  fi
  gh pr diff "$PR" --name-only > "$FILES_FILE"
elif printf '%s' "$TARGET" | grep -q '\.\.'; then
  # --- commit-range or base_ref..HEAD -> git diff <range> (verbatim) ---
  TARGET_KIND="range"
  git diff "$TARGET" > "$DIFF_FILE"
  git diff --name-only "$TARGET" > "$FILES_FILE"
else
  # --- bare branch / ref name -> diff from the merge-base with BASE ---
  # Three-dot mirrors `gh pr diff`: only the changes the branch introduced,
  # ignoring changes that landed on BASE after the branch diverged.
  if [ -e "$TARGET" ]; then
    echo "ERROR: '$TARGET' is a filesystem path, not a PR/branch/range. Aborting." >&2
    exit 2
  fi
  TARGET_KIND="branch"
  git diff "${BASE}...${TARGET}" > "$DIFF_FILE"
  git diff --name-only "${BASE}...${TARGET}" > "$FILES_FILE"
fi

# Empty diff is a hard stop — there is nothing to review. Clean (exit 0) and
# stdout stays empty so a caller can tell "nothing to review" from "resolved".
if [ ! -s "$DIFF_FILE" ]; then
  echo "Resolved target ($TARGET_KIND) '$TARGET' produced an EMPTY diff; nothing to review." >&2
  exit 0
fi

# Human narration -> stderr.
{
  echo "Resolved target kind=$TARGET_KIND target='$TARGET'"
  echo "Touched files:"; cat "$FILES_FILE"
  echo "Unified diff is in: $DIFF_FILE  (touched files: $FILES_FILE)"
} >&2

# Machine result -> stdout (eval / source-able by the caller).
printf 'TARGET_KIND=%s\nDIFF_FILE=%s\nFILES_FILE=%s\n' "$TARGET_KIND" "$DIFF_FILE" "$FILES_FILE"
