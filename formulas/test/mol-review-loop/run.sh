#!/usr/bin/env bash
# Deterministic test suite for the mol-review-loop formula + its shared
# verdict-glue check (formulas/lib/review-verdict.sh).
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02 03      run only the matching test files
#
# Exits non-zero if any assertion fails. The suite locks down the formula
# structure (test_01), the reviewer-agnostic verdict glue + exit-code contract
# and the optional fire-and-forget notify (test_02), and — when `gc` is on PATH
# — that the formula compiles to the expected ralph graph (test_03).
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../mol-review-loop.toml}"
export VERDICT_SH="${VERDICT_SH:-$SUITE_DIR/../../lib/review-verdict.sh}"

for f in "$FORMULA" "$VERDICT_SH"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: not found: $f" >&2
    exit 2
  fi
done

export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mrl-test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
for tool in python3 jq bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# mol-review-loop test suite"
echo "  formula:  $FORMULA"
echo "  verdict:  $VERDICT_SH"
command -v gc >/dev/null 2>&1 && echo "  gc: present (compile check enabled)" \
                              || echo "  gc: MISSING (compile check will be skipped)"

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
