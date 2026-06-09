#!/usr/bin/env bash
# Deterministic test suite for the expansion-standard-reviewer fragment (the
# canonical standard 8-pass reviewer, gcs-f4j.8). THIS file currently builds the
# analyze pass (gcs-f4j.8.1); the suite grows with the lenses (.2) and synthesis
# (.3).
#
#   ./run.sh            run every test_*.sh
#   ./run.sh 02 03      run only the matching test files
#
# Exits non-zero if any assertion fails. test_01 locks the fragment structure +
# var contract + expansion-syntax; test_02 pins the shared resolver contract the
# analyze step depends on and its no-drift wiring; test_03 runs the analyze bash
# end-to-end against a stub bd/gc + a real resolver and asserts the durable
# inputs + recorded metadata.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
export FORMULA="${FORMULA:-$SUITE_DIR/../../expansion-standard-reviewer.toml}"
export RESOLVER="${RESOLVER:-$SUITE_DIR/../../lib/resolve-diff.sh}"

for f in "$FORMULA" "$RESOLVER"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: not found: $f" >&2
    exit 2
  fi
done

# Confine every temp artifact (throwaway repos, sandbox cities, stub logs) to one
# run-scoped dir, removed on exit.
export TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/esr-test.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT
for tool in python3 git jq bash; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: missing required tool: $tool" >&2; exit 2; }
done

# shellcheck source=lib.sh
. "$SUITE_DIR/lib.sh"

echo "# expansion-standard-reviewer test suite"
echo "  fragment: $FORMULA"
echo "  resolver: $RESOLVER"
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
