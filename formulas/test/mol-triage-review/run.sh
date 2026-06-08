#!/usr/bin/env bash
# Deterministic test suite for the mol-triage-review formula.
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02 04      run only the matching test files
#
# Exits non-zero if any assertion fails. See README.md for what is (and is not)
# covered deterministically — the model-dependent outcomes are the .6 dogfood's
# job; this suite locks down the transport and the fixture corpus around them.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../mol-triage-review.toml}"
export ANTHROPIC_SRC="${ANTHROPIC_SRC:-$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/code-review/commands/code-review.md}"

if [ ! -f "$FORMULA" ]; then
  echo "FATAL: formula not found at $FORMULA" >&2
  exit 2
fi

# Confine every temp artifact (throwaway git repos, bd-stub logs, the step-0
# block's own mktemp diff files) to one run-scoped dir, removed on exit. Keeps
# the suite leak-free and repeatable.
export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mtr-test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
for tool in python3 git jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# mol-triage-review test suite"
echo "  formula: $FORMULA"
[ -r "$ANTHROPIC_SRC" ] && echo "  anthropic source: present" || echo "  anthropic source: MISSING (verbatim checks will fail)"

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
