# Compile/expansion check — the fragment must actually EXPAND (not merely parse as
# TOML). This is the one test that needs the live `gc` binary; it is SKIPPED (not
# failed) when gc is absent, since test_01 pins the structure from the TOML
# directly. `gc formula show` materializes the expansion with a synthetic target
# (`main`), exercising the same {target}-placeholder + single-brace-var
# substitution the host triggers via compose.expand — including each lane's
# per-lane opt_model, the mechanism that makes triage provider-robust.

section "05 compile (gc formula show — expansion materializes)"

if ! command -v gc >/dev/null 2>&1; then
  echo "  skip gc not on PATH — compile check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc formula show expansion-triage-reviewer 2>&1)"; rc=$?
assert_eq "0" "$rc" "gc formula show expansion-triage-reviewer exits 0 (expands)"

# {target} placeholder -> the synthetic target id 'main'; the five lenses + analyze
# + synthesis materialize; the clean terminal is appended.
assert_contains "$SHOW" "expansion-triage-reviewer.main.analyze" "compiled: {target}.analyze -> main.analyze"
for lens in rule-adherence bug-scan git-history prior-prs in-code-invariants; do
  assert_contains "$SHOW" "expansion-triage-reviewer.main.$lens" "compiled: {target}.$lens -> main.$lens"
done
assert_contains "$SHOW" "expansion-triage-reviewer.main.synthesis" "compiled: {target}.synthesis -> main.synthesis"
assert_contains "$SHOW" "workflow-finalize" "compiled: clean terminal (workflow-finalize)"

# A JSON render must show NO leftover {{double}} braces and NO unsubstituted
# single-brace vars in the analyze step, that the resolver is called with the
# substituted default args, AND that each lane's opt_model substitutes to its
# tiered model (not the literal {lens_model} brace) — the per-lane model mechanism.
RENDER="$(gc formula show expansion-triage-reviewer --json 2>/dev/null \
  | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
desc="".join(s.get("description","") for s in d["steps"] if s.get("id","").endswith(".analyze"))
bad_double=re.findall(r"\{\{\s*\w+\s*\}\}", desc)
bad_single=re.findall(r"\{(review_target|base_branch|aux_model|threshold)\}", desc)
print("DOUBLE="+str(len(bad_double)))
print("SINGLE="+str(len(bad_single)))
print("RESOLVER_ARGS_OK=" + ("yes" if "\"\" \"main\"" in desc else "no"))
tier={"analyze":"haiku","rule-adherence":"haiku","bug-scan":"sonnet","git-history":"sonnet","prior-prs":"haiku","in-code-invariants":"sonnet","synthesis":"sonnet"}
ok=True
for s in d["steps"]:
    sid=s.get("id","")
    for lens,want in tier.items():
        if sid.endswith("."+lens):
            got=(s.get("metadata") or {}).get("opt_model","")
            if got!=want or "{" in got: ok=False
print("OPT_MODEL_OK=" + ("yes" if ok else "no"))
')"
assert_contains "$RENDER" "DOUBLE=0" "no leftover {{double-brace}} after expansion"
assert_contains "$RENDER" "SINGLE=0" "no unsubstituted single-brace vars after expansion"
assert_contains "$RENDER" "RESOLVER_ARGS_OK=yes" "resolver called with substituted vars (default \"\" \"main\")"
assert_contains "$RENDER" "OPT_MODEL_OK=yes" "each lane opt_model substitutes to its tiered model (no literal brace)"
