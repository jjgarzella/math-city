#!/usr/bin/env bash
# Deterministic test suite for the expansion-triage-reviewer fragment — the
# canonical, provider-independent Tier-1 triage reviewer (gcs-f4j.10.1).
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02 03      run only the matching test files
#
# Exits non-zero if any assertion fails. test_01 locks the fragment structure +
# var contract + expansion-syntax + the five real-bugs lenses' + synthesis'
# wiring; test_02 runs the analyze bash end-to-end against a stub bd/gc + the real
# resolver and asserts diff resolution, the path-target REJECTION (triage reviews
# changes), rule-file discovery, and the recorded metadata; test_03 runs the five
# lens blocks (eligibility gate / category-labelled filing / repo-dependent
# self-skip) against the shared lib + stubs; test_04 pins the synthesis pass'
# verbatim Anthropic rubric + threshold gate + verdict wiring; test_05 expands the
# fragment through the live gc binary (analyze + five lenses + synthesis + per-lane
# opt_model tiering).
#
# The shared, reviewer-agnostic libs (resolve-diff.sh, review-lane.sh,
# review-synthesis.sh) this fragment REUSES are tested directly by the
# expansion-standard-reviewer suite; this suite does not re-test them — it pins the
# triage-specific contract layered on top.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../expansion-triage-reviewer.toml}"
export RESOLVER="${RESOLVER:-$SUITE_DIR/../../lib/resolve-diff.sh}"
# Anthropic source for the verbatim false-positive list + confidence rubric (the
# verbatim checks SKIP, not fail, when it is absent — keeps the suite CI-portable).
export ANTHROPIC_SRC="${ANTHROPIC_SRC:-$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md}"

for f in "$FORMULA" "$RESOLVER"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: not found: $f" >&2
    exit 2
  fi
done

# Confine every temp artifact (throwaway repos, sandbox cities, stub logs) to one
# run-scoped dir, removed on exit.
export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/etr-test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
for tool in python3 git jq bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# expansion-triage-reviewer test suite"
echo "  fragment: $FORMULA"
echo "  resolver: $RESOLVER"
[ -r "$ANTHROPIC_SRC" ] && echo "  anthropic source: present" || echo "  anthropic source: MISSING (verbatim checks skipped)"
command -v gc >/dev/null 2>&1 && echo "  gc: present (expansion compile check enabled)" \
                              || echo "  gc: MISSING (expansion compile check will be skipped)"

select_tests() {
  if [ "$#" -eq 0 ]; then
    ls "$SUITE_DIR"/test_*.sh | sort
    return
  fi
  for pat in "$@"; do
    ls "$SUITE_DIR"/test_*"$pat"*.sh 2>/dev/null
  done | sort -u
}

ran=0
while IFS= read -r tf; do
  [ -z "$tf" ] && continue
  ran=$((ran + 1))
  # shellcheck source=/dev/null
  . "$tf"
done < <(select_tests "$@")

echo
echo "# summary: $PASS passed, $FAIL failed ($ran test files)"
if [ "$ran" -eq 0 ]; then
  echo "FATAL: no test files selected" >&2
  exit 2
fi
[ "$FAIL" -eq 0 ]
