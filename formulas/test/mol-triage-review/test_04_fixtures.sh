# Fixture corpus — the five acceptance scenarios as planted diffs with
# expected-outcome manifests. What is DETERMINISTIC is asserted here:
#   - each fixture builds a real git repo and step 0 routes it as expected
#     (empty vs non-empty, kind=pr|branch|range);
#   - the corpus is internally consistent (the planted rule/bug are present, the
#     dedup findings genuinely collide, the nitpick reasons map to the verbatim
#     FP list).
# The remaining, model-dependent outcome (does scoring promote/drop/merge as the
# manifest says) is the .6 dogfood's job — each expected.env names that outcome.

section "04 fixture corpus"

FIX="$SUITE_DIR/fixtures"
DESC="$(formula_py step-desc)"
SCENARIOS="empty-diff trivial-diff no-pr-context rule-and-bug dedup-two-angles nitpick-fp"

for fx in $SCENARIOS; do
  d="$FIX/$fx"
  if [ ! -f "$d/build.sh" ] || [ ! -f "$d/expected.env" ]; then
    fail "$fx: has build.sh + expected.env"
    continue
  fi

  unset EXPECTED_KIND EXPECTED_EMPTY EXPECTED_OUTCOME NOTES
  # shellcheck disable=SC1090
  . "$d/expected.env"
  [ -n "${EXPECTED_OUTCOME:-}" ] && ok "$fx: expected.env names an outcome ($EXPECTED_OUTCOME)" \
    || fail "$fx: expected.env names an outcome"

  REPO=""; TARGET="__unset__"
  # shellcheck disable=SC1090
  . "$d/build.sh"
  if [ -z "$REPO" ] || [ ! -d "$REPO" ] || [ "$TARGET" = "__unset__" ]; then
    fail "$fx: build.sh sets REPO + TARGET"
    continue
  fi

  run_step0 "$REPO" "$TARGET"; out="$STEP0_OUT"
  if [ "${EXPECTED_EMPTY:-no}" = "yes" ]; then
    assert_eq 0 "$STEP0_RC" "$fx: empty target stops clean (exit 0)"
    assert_contains "$out" "EMPTY diff" "$fx: step 0 reports the empty diff"
  else
    assert_eq 0 "$STEP0_RC" "$fx: step 0 resolves (exit 0)"
    assert_contains "$out" "kind=$EXPECTED_KIND" "$fx: resolves to kind=$EXPECTED_KIND"
  fi

  # --- per-scenario corpus-consistency checks ---
  case "$fx" in
    rule-and-bug)
      assert_file_contains "$REPO/AGENTS.md" "doc comment" "$fx: written rule present in AGENTS.md"
      assert_file_contains "$REPO/AGENTS.md" "os.Exit" "$fx: second written rule present"
      assert_file_contains "$REPO/app.go" "xs[0]" "$fx: the planted real bug is in the change"
      ;;
    dedup-two-angles)
      tsv="$d/findings.tsv"
      if [ -f "$tsv" ]; then
        # two data rows (skip header) that share file + root_cause across two angles
        rows="$(awk 'NR>1 && NF' "$tsv")"
        n="$(printf '%s\n' "$rows" | grep -c .)"
        assert_eq 2 "$n" "$fx: findings.tsv lists exactly two colliding findings"
        files="$(printf '%s\n' "$rows" | cut -f1 | sort -u | grep -c .)"
        causes="$(printf '%s\n' "$rows" | cut -f3 | sort -u | grep -c .)"
        angles="$(printf '%s\n' "$rows" | cut -f4 | sort -u | grep -c .)"
        assert_eq 1 "$files"  "$fx: both findings are in the same file"
        assert_eq 1 "$causes" "$fx: both findings share one root cause (mergeable)"
        assert_eq 2 "$angles" "$fx: the collision spans two distinct angles"
      else
        fail "$fx: findings.tsv present"
      fi
      ;;
    nitpick-fp)
      map="$d/fp_map.tsv"
      if [ -f "$map" ]; then
        while IFS=$'\t' read -r issue bullet; do
          [ "$issue" = "issue" ] && continue   # header
          [ -z "$issue" ] && continue
          assert_contains "$DESC" "$bullet" "$fx: '$issue' is grounded in the verbatim FP list"
        done < "$map"
      else
        fail "$fx: fp_map.tsv present"
      fi
      ;;
  esac

  rm -rf "$REPO"
done
