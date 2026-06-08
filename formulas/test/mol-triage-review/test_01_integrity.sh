# Formula integrity + verbatim-fidelity to the Anthropic code-review command.
# Deterministic: pure structural + textual assertions over the TOML.
#
# Covers the cross-cutting acceptance that every scenario depends on: the
# formula parses, its six vars resolve 1:1, and the Anthropic CORE (0-100
# rubric + false-positive list) is reproduced char-for-char rather than
# paraphrased — the regression guard the .2 build order asked .5 to own.

section "01 formula integrity"

# --- parses with the expected top-level shape --------------------------------
assert_eq "mol-triage-review" "$(formula_py formula-name)" "formula name is mol-triage-review"
assert_eq "1" "$(formula_py step-count)" "single review step (one bead, one session)"

# --- six vars, resolving 1:1 with template refs ------------------------------
defined="$(formula_py defined-vars | tr '\n' ' ')"
assert_eq "aux_model base_branch review_model score_model target threshold " "$defined" \
  "defines exactly the six tunable vars"

# every {{ref}} resolves to a defined var, and every defined var is referenced
undefined=""
while IFS= read -r ref; do
  formula_py defined-vars | grep -qx "$ref" || undefined="$undefined $ref"
done < <(formula_py template-refs)
assert_eq "" "$undefined" "no template ref points at an undefined var"

unused=""
refs="$(formula_py template-refs | tr '\n' ' ')"
while IFS= read -r v; do
  case " $refs " in *" $v "*) : ;; *) unused="$unused $v" ;; esac
done < <(formula_py defined-vars)
assert_eq "" "$unused" "every defined var is referenced at least once"

# --- var defaults reproduce Anthropic's model tiers + threshold --------------
assert_eq "main"   "$(formula_py var-default base_branch)"  "base_branch default = main"
assert_eq "sonnet" "$(formula_py var-default review_model)" "review_model default = sonnet (5 angles)"
assert_eq "haiku"  "$(formula_py var-default score_model)"  "score_model default = haiku (scorer)"
assert_eq "haiku"  "$(formula_py var-default aux_model)"    "aux_model default = haiku (aux steps)"
assert_eq "80"     "$(formula_py var-default threshold)"    "threshold default = 80 (Anthropic)"

DESC="$(formula_py step-desc)"

# --- VERBATIM: Anthropic 0/25/50/75/100 confidence rubric --------------------
# Pull the canonical rubric lines straight from upstream; each must appear, text
# for text, in the formula. If upstream changes the test tracks it; if the
# formula paraphrases, the test fails.
if [ -r "$ANTHROPIC_SRC" ]; then
  rubric_n=0
  while IFS= read -r line; do
    rubric_n=$((rubric_n + 1))
    assert_contains "$DESC" "$line" "rubric verbatim: ${line%%.*}."
  done < <(grep -E '^   [a-e]\. [0-9]+: ' "$ANTHROPIC_SRC" | sed -E 's/^   [a-e]\. //')
  assert_eq "5" "$rubric_n" "found all five rubric tiers in upstream"

  # --- VERBATIM: Anthropic false-positive list -------------------------------
  fp_n=0
  while IFS= read -r line; do
    fp_n=$((fp_n + 1))
    assert_contains "$DESC" "$line" "FP-list verbatim: ${line:0:48}…"
  done < <(awk '/^Examples of false positives/{f=1;next} /^Notes:/{f=0} f&&/^- /{sub(/^- /,"");print}' "$ANTHROPIC_SRC")
  assert_eq "8" "$fp_n" "found all eight false-positive bullets in upstream"
else
  fail "Anthropic source readable at $ANTHROPIC_SRC" "cannot verify verbatim fidelity"
fi

# --- the five review angles + their category labels --------------------------
for cat in rule-adherence bug-scan git-history prior-prs in-code-invariants; do
  assert_contains "$DESC" "category:<angle>" "step 4b documents category:<angle> labels"
  assert_contains "$DESC" "$cat" "angle category '$cat' present"
done

# --- the vendor-neutral / diff glosses on the verbatim text ------------------
assert_contains "$DESC" "AGENTS.md, CLAUDE.md, .cursorrules" "rule files are vendor-neutral"
assert_contains "$DESC" "the diff under review" "‘pull request’ glossed to the diff"

# --- scope discipline: flag only written-rule violations + real bugs ---------
assert_contains "$DESC" "violations of a WRITTEN project rule" "scope discipline: written-rule violations"
assert_contains "$DESC" "real bugs in the changed lines" "scope discipline: real bugs"
