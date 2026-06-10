#!/usr/bin/env bash
# Deterministic test suite for the mol-triage-review-independent host formula —
# the standalone, directly-slingable host for the canonical provider-independent
# triage reviewer fragment (expansion-triage-reviewer, gcs-f4j.10.1).
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02         run only the matching test files
#
# Exits non-zero if any assertion fails. test_01 pins the host's structure + var
# contract + the compose.expand mapping (with the no-drift cross-check against the
# fragment) from the TOML directly (no gc needed); test_02 compiles the host
# through the live gc binary and asserts the fragment EXPANDS into it — the seven
# passes, the clean workflow-finalize terminal, and full compose.expand
# var-propagation (default + overridden). What the model actually finds on a real
# diff is the dogfood's job (see README.md); this suite locks the wiring around it.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../mol-triage-review-independent.toml}"
export FRAGMENT="${FRAGMENT:-$SUITE_DIR/../../expansion-triage-reviewer.toml}"

for f in "$FORMULA" "$FRAGMENT"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: not found: $f" >&2
    exit 2
  fi
done

for tool in python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# mol-triage-review-independent test suite"
echo "  host:     $FORMULA"
echo "  fragment: $FRAGMENT"
command -v gc >/dev/null 2>&1 && echo "  gc: present (compile/expand check enabled)" \
                              || echo "  gc: MISSING (compile/expand check will be skipped)"

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
