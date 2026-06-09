#!/usr/bin/env bash
# Deterministic test suite for the mol-polecat-implement formula — the native
# graph.v2 polecat IMPLEMENT lifecycle (gascity gcs-f4j.6 / gcs-6r2): feature
# branch + idempotent resume, then a NON-MERGING terminal that pushes and
# triggers the review->fix loop, then drains.
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02         run only the matching test files
#
# Exits non-zero if any assertion fails. The suite locks down the formula
# structure + the implement<->review seam (test_01) and — when `gc` is on PATH —
# that the formula compiles to the expected single-session graph (test_02).
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../mol-polecat-implement.toml}"

if [ ! -f "$FORMULA" ]; then
  echo "FATAL: not found: $FORMULA" >&2
  exit 2
fi

for tool in python3 bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# mol-polecat-implement test suite"
echo "  formula:  $FORMULA"
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
