# Compile/expand check — the loop must compile to the expected ralph graph with
# the canonical reviewer fragment materialized inside the iteration body. This is
# the one test that needs the live `gc` binary; it is SKIPPED (not failed) when gc
# is absent, since test_01 pins the structure from the TOML directly. `gc formula
# show mol-review-loop-standard` materializes the compose.expand exactly as
# `gc sling` would, so it exercises the full var-propagation path: the {target}
# placeholder -> the review-pipeline slot, and the loop vars -> the fragment's
# single-brace vars (default and overridden). NOTE: workflow {{vars}} (e.g.
# {{severity_threshold}} in apply-fixes) render at SLING time, not at `formula
# show`, so they are intentionally not asserted-substituted here.

section "03 compile/expand (gc formula show — ralph body + compose.expand)"

if [ "${HAVE_GC:-0}" != "1" ]; then
  echo "  skip gc not on PATH — compile/expand check skipped"
  return 0 2>/dev/null || true
fi

SHOW="$(gc_show)"; rc=$?
assert_eq "0" "$rc" "gc formula show mol-review-loop-standard exits 0 (compiles + expands)"

ITER="mol-review-loop-standard.review-loop.iteration.1"
PIPE="$ITER.review-pipeline"

# --- the eight reviewer passes materialize INSIDE the ralph iteration body ----
assert_contains "$SHOW" "$PIPE.analyze" "{target}.analyze -> review-pipeline.analyze inside the iteration body"
for lens in quality security performance architecture testing docs; do
  assert_contains "$SHOW" "$PIPE.$lens" "{target}.$lens -> review-pipeline.$lens"
done
assert_contains "$SHOW" "$PIPE.synthesis" "{target}.synthesis -> review-pipeline.synthesis"
assert_contains "$SHOW" "$ITER.apply-fixes" "apply-fixes runs in the iteration body after the reviewer"
assert_contains "$SHOW" "mol-review-loop-standard.review-loop:" "review-loop ralph control bead present"
assert_contains "$SHOW" "workflow-finalize" "clean graph.v2 terminal (workflow-finalize) appended"

# --- DAG wiring survives expansion: lenses gate on analyze, synthesis on all six
#     lenses, apply-fixes on synthesis. The tree render carries deps as
#     `<id>: <title> [needs: a, b, ...]`. -------------------------------------
WIRING="$(printf '%s\n' "$SHOW" | python3 -c '
import sys,re
PIPE="mol-review-loop-standard.review-loop.iteration.1.review-pipeline."
ITER="mol-review-loop-standard.review-loop.iteration.1."
needs={}
for line in sys.stdin:
    m=re.search(r"(\S+):.*\[needs: ([^\]]*)\]", line)
    if m:
        needs[m.group(1)]={n.strip() for n in m.group(2).split(",") if n.strip()}
lenses=["quality","security","performance","architecture","testing","docs"]
lens_on_analyze=all(PIPE+"analyze-scope-check" in needs.get(PIPE+l,set()) for l in lenses)
synth_on_all=needs.get(PIPE+"synthesis",set())>={PIPE+l+"-scope-check" for l in lenses}
fix_on_synth=(PIPE+"synthesis-scope-check") in needs.get(ITER+"apply-fixes",set())
print("LENSES_NEED_ANALYZE="+("yes" if lens_on_analyze else "no"))
print("SYNTH_NEEDS_ALL_SIX="+("yes" if synth_on_all else "no"))
print("FIX_NEEDS_SYNTH="+("yes" if fix_on_synth else "no"))
')"
assert_contains "$WIRING" "LENSES_NEED_ANALYZE=yes" "each lens needs the analyze pass"
assert_contains "$WIRING" "SYNTH_NEEDS_ALL_SIX=yes" "synthesis needs all six lenses"
assert_contains "$WIRING" "FIX_NEEDS_SYNTH=yes"     "apply-fixes needs synthesis (review -> fix ordering)"

# --- DEFAULT var propagation: no leftover fragment braces; the resolver sees the
#     default target ("") + base_branch (main); each lens opt_model tiers; the
#     synthesis severity_threshold is the default minor -------------------------
PROP="$(gc_show_json | python3 -c '
import json,sys,re
d=json.load(sys.stdin)
steps=d["steps"]
analyze="".join(s.get("description","") for s in steps if s.get("id","").endswith(".analyze"))
synth="".join(s.get("description","") for s in steps if s.get("id","").endswith(".synthesis"))
print("ANALYZE_SINGLE="+str(len(re.findall(r"\{(review_target|base_branch|aux_model|severity_threshold)\}", analyze))))
print("RESOLVER_DEFAULT=" + ("yes" if "\"\" \"main\"" in analyze else "no"))
print("SYNTH_THRESHOLD_MINOR=" + ("yes" if "severity_threshold = minor" in synth else "no"))
tier={"quality":"sonnet","security":"opus","performance":"sonnet","architecture":"opus","testing":"haiku","docs":"haiku","synthesis":"opus"}
ok=True
for s in steps:
    sid=s.get("id","")
    for lens,want in tier.items():
        if sid.endswith(".review-pipeline."+lens):
            md=s.get("metadata") or {}
            if md.get("opt_model","")!=want or "{" in md.get("opt_model",""): ok=False
            if md.get("gc.run_target","")!="gasvillage.polecat": ok=False
print("LANES_OK=" + ("yes" if ok else "no"))
')"
assert_contains "$PROP" "ANALYZE_SINGLE=0"        "no unsubstituted single-brace fragment vars in analyze"
assert_contains "$PROP" "RESOLVER_DEFAULT=yes"    "default target/base_branch reach the resolver (\"\" \"main\")"
assert_contains "$PROP" "SYNTH_THRESHOLD_MINOR=yes" "default severity_threshold (minor) reaches synthesis"
assert_contains "$PROP" "LANES_OK=yes"            "each lens opt_model + run_target propagated (tiered, no literal brace)"

# --- OVERRIDDEN var propagation: --var flows through compose.expand -----------
OVR="$(gc_show_json --var target='#123' --var base_branch=develop --var severity_threshold=major --var synthesis_model=sonnet | python3 -c '
import json,sys
d=json.load(sys.stdin)
steps=d["steps"]
analyze="".join(s.get("description","") for s in steps if s.get("id","").endswith(".analyze"))
synth="".join(s.get("description","") for s in steps if s.get("id","").endswith(".synthesis"))
print("RESOLVER_OVR=" + ("yes" if "\"#123\" \"develop\"" in analyze else "no"))
print("SYNTH_THRESHOLD_MAJOR=" + ("yes" if "severity_threshold = major" in synth else "no"))
sm=[ (s.get("metadata") or {}).get("opt_model","") for s in steps if s.get("id","").endswith(".synthesis")]
print("SYNTH_MODEL=" + (sm[0] if sm else ""))
')"
assert_contains "$OVR" "RESOLVER_OVR=yes"          "--var target/base_branch propagate to the resolver (#123 develop)"
assert_contains "$OVR" "SYNTH_THRESHOLD_MAJOR=yes" "--var severity_threshold=major propagates into the synthesis threshold"
assert_contains "$OVR" "SYNTH_MODEL=sonnet"        "--var synthesis_model overrides the synthesis lane opt_model"
