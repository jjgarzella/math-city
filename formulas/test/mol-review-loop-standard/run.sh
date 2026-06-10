#!/usr/bin/env bash
# Deterministic test suite for the mol-review-loop-standard formula (the codex-free
# standard-reviewer review->fix loop variant, gcs-f4j.8.5) + its shared apply-fixes
# transport (formulas/lib/review-apply-fixes.sh).
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02         run only the matching test files
#
# Exits non-zero if any assertion fails. test_01 pins the loop's structure + the
# compose.expand of the canonical reviewer fragment + the var contract (no-drift)
# from the TOML directly (no gc needed); test_02 runs the real apply-fixes lib
# against canned bead JSON (stub bd/gc, no Dolt) to pin the verdict->severity->fix
# mapping + the blocked terminate-to-human escalation; test_03 compiles the loop
# through the live gc binary and asserts the eight reviewer passes materialize
# inside the ralph iteration body ahead of apply-fixes. What the model actually
# finds + fixes on a real diff is the dogfood's job; this suite locks the wiring.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../mol-review-loop-standard.toml}"
export FRAGMENT="${FRAGMENT:-$SUITE_DIR/../../expansion-standard-reviewer.toml}"
export VERDICT_SH="${VERDICT_SH:-$SUITE_DIR/../../lib/review-verdict.sh}"
export APPLY_FIXES_SH="${APPLY_FIXES_SH:-$SUITE_DIR/../../lib/review-apply-fixes.sh}"

for f in "$FORMULA" "$FRAGMENT" "$VERDICT_SH" "$APPLY_FIXES_SH"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: not found: $f" >&2
    exit 2
  fi
done

export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/mrls-test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
for tool in python3 jq bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# mol-review-loop-standard test suite"
echo "  formula:     $FORMULA"
echo "  fragment:    $FRAGMENT"
echo "  apply-fixes: $APPLY_FIXES_SH"
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
