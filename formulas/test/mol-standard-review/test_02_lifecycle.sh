# Host lifecycle — compile/expand through the live `gc` binary. This is the one
# test that needs gc; it is SKIPPED (not failed) when gc is absent, since test_01
# pins the host structure from the TOML. `gc formula show mol-standard-review`
# materializes the compose.expand exactly as `gc sling` would, so it exercises
# the full var-propagation path: the {target} placeholder -> this host's step id,
# and the host vars -> the fragment's single-brace vars (default and overridden).

section "02 host lifecycle (gc formula show — compose.expand materializes)"

if [ "${HAVE_GC:-0}" != "1" ]; then
  echo "  skip gc not on PATH — compile/expand check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc_show)"; rc=$?
assert_eq "0" "$rc" "gc formula show mol-standard-review exits 0 (the host compiles + expands)"

# --- {target} placeholder -> the host's step id (review-pipeline); the eight
#     fragment passes materialize under it -------------------------------------
assert_contains "$SHOW" "mol-standard-review.review-pipeline.analyze" \
  "{target}.analyze -> review-pipeline.analyze (placeholder substituted)"
for lens in quality security performance architecture testing docs; do
  assert_contains "$SHOW" "mol-standard-review.review-pipeline.$lens" \
    "{target}.$lens -> review-pipeline.$lens"
done
assert_contains "$SHOW" "mol-standard-review.review-pipeline.synthesis" \
  "{target}.synthesis -> review-pipeline.synthesis"
assert_contains "$SHOW" "workflow-finalize" "clean graph.v2 terminal (workflow-finalize) appended"

# --- the DAG wiring survives expansion: lenses gate on analyze, synthesis on
#     all six lenses, finalize on synthesis. The tree render carries the deps as
#     `<id>: <title> [needs: a, b, ...]`; parse that (the --json step view omits
#     needs). ---------------------------------------------------------------------
WIRING="$(printf '%s\n' "$SHOW" | python3 -c '
import sys,re
P="mol-standard-review.review-pipeline."
F="mol-standard-review."
needs={}
for line in sys.stdin:
    m=re.search(r"(\S+):.*\[needs: ([^\]]*)\]", line)
    if m:
        needs[m.group(1)]={n.strip() for n in m.group(2).split(",") if n.strip()}
lenses=["quality","security","performance","architecture","testing","docs"]
lens_on_analyze=all(P+"analyze" in needs.get(P+l,set()) for l in lenses)
synth_on_all=needs.get(P+"synthesis",set())=={P+l for l in lenses}
final_on_synth=(P+"synthesis") in needs.get(F+"workflow-finalize",set())
print("LENSES_NEED_ANALYZE="+("yes" if lens_on_analyze else "no"))
print("SYNTH_NEEDS_ALL_SIX="+("yes" if synth_on_all else "no"))
print("FINALIZE_NEEDS_SYNTH="+("yes" if final_on_synth else "no"))
')"
assert_contains "$WIRING" "LENSES_NEED_ANALYZE=yes" "each lens needs the analyze pass"
assert_contains "$WIRING" "SYNTH_NEEDS_ALL_SIX=yes" "synthesis needs all six lenses"
assert_contains "$WIRING" "FINALIZE_NEEDS_SYNTH=yes" "workflow-finalize needs synthesis"

# --- DEFAULT var propagation: no leftover braces, the resolver sees the
#     default target ("") + base_branch (main), and each lens opt_model
#     substitutes to its tiered model -------------------------------------------
PROP="$(gc_show_json | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
steps=d["steps"]
analyze="".join(s.get("description","") for s in steps if s.get("id","").endswith(".analyze"))
print("DOUBLE="+str(len(re.findall(r"\{\{\s*\w+\s*\}\}", analyze))))
print("SINGLE="+str(len(re.findall(r"\{(review_target|base_branch|aux_model|severity_threshold)\}", analyze))))
print("RESOLVER_DEFAULT=" + ("yes" if "\"\" \"main\"" in analyze else "no"))
tier={"quality":"sonnet","security":"opus","performance":"sonnet","architecture":"opus","testing":"haiku","docs":"haiku","synthesis":"opus"}
ok=True
for s in steps:
    sid=s.get("id","")
    for lens,want in tier.items():
        if sid.endswith("."+lens):
            md=s.get("metadata") or {}
            if md.get("opt_model","")!=want or "{" in md.get("opt_model",""): ok=False
            if md.get("gc.run_target","")!="gasvillage.polecat": ok=False
print("LANES_OK=" + ("yes" if ok else "no"))
')"
assert_contains "$PROP" "DOUBLE=0" "no leftover {{double-brace}} in the expanded analyze pass"
assert_contains "$PROP" "SINGLE=0" "no unsubstituted single-brace fragment vars in analyze"
assert_contains "$PROP" "RESOLVER_DEFAULT=yes" "default target/base_branch reach the resolver (\"\" \"main\")"
assert_contains "$PROP" "LANES_OK=yes" "each lens opt_model + run_target propagated (tiered, no literal brace)"

# --- OVERRIDDEN var propagation: --var flows through compose.expand into the
#     fragment (the host's whole point — tune the reviewer from one surface) ----
OVR="$(gc_show_json --var target='#123' --var base_branch=develop --var security_model=sonnet | python3 -c '
import json,sys
d=json.load(sys.stdin)
steps=d["steps"]
analyze="".join(s.get("description","") for s in steps if s.get("id","").endswith(".analyze"))
print("RESOLVER_OVR=" + ("yes" if "\"#123\" \"develop\"" in analyze else "no"))
sec=[ (s.get("metadata") or {}).get("opt_model","") for s in steps if s.get("id","").endswith(".security")]
print("SECURITY_MODEL=" + (sec[0] if sec else ""))
')"
assert_contains "$OVR" "RESOLVER_OVR=yes" "--var target/base_branch propagate to the resolver (#123 develop)"
assert_contains "$OVR" "SECURITY_MODEL=sonnet" "--var security_model overrides the security lens opt_model"
