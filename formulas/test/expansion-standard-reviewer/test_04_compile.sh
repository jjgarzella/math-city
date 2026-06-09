# Compile/expansion check — the fragment must actually EXPAND (not merely parse
# as TOML). This is the one test that needs the live `gc` binary; it is SKIPPED
# (not failed) when gc is absent, since test_01 pins the structure from the TOML
# directly. `gc formula show` materializes the expansion with a synthetic target
# (`main`), so it exercises the same {target}-placeholder + single-brace-var
# substitution the hosts trigger via compose.expand.

section "04 compile (gc formula show — expansion materializes)"

if ! command -v gc >/dev/null 2>&1; then
  echo "  skip gc not on PATH — compile check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc formula show expansion-standard-reviewer 2>&1)"; rc=$?
assert_eq "0" "$rc" "gc formula show expansion-standard-reviewer exits 0 (expands)"

# {target} placeholder -> the synthetic target id 'main'; vars substitute single-brace.
assert_contains "$SHOW" "expansion-standard-reviewer.main.analyze" "compiled: {target}.analyze -> main.analyze"
assert_contains "$SHOW" "workflow-finalize" "compiled: clean terminal (workflow-finalize)"

# A JSON render must show NO leftover {{double}} braces and NO unsubstituted
# single-brace vars in the analyze step (the failure mode the syntax bug caused).
RENDER="$(gc formula show expansion-standard-reviewer --json 2>/dev/null \
  | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
desc="".join(s.get("description","") for s in d["steps"] if s.get("id","").endswith(".analyze"))
bad_double=re.findall(r"\{\{\s*\w+\s*\}\}", desc)
bad_single=re.findall(r"\{(review_target|base_branch|review_model|aux_model|severity_threshold)\}", desc)
print("DOUBLE="+str(len(bad_double)))
print("SINGLE="+str(len(bad_single)))
print("RESOLVER_ARGS_OK=" + ("yes" if "\"\" \"main\"" in desc else "no"))
')"
assert_contains "$RENDER" "DOUBLE=0" "no leftover {{double-brace}} after expansion"
assert_contains "$RENDER" "SINGLE=0" "no unsubstituted single-brace vars after expansion"
assert_contains "$RENDER" "RESOLVER_ARGS_OK=yes" "resolver called with substituted vars (default \"\" \"main\")"
