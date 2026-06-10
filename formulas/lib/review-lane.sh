#!/usr/bin/env bash
# Shared lane helper for the canonical standard (8-pass) reviewer
# (expansion-standard-reviewer, gascity gcs-f4j.8). Single source of truth for the
# transport every one of the six review lenses repeats — loading the analyze
# pass's DURABLE inputs, filing a candidate finding as a category-labelled wisp,
# and closing the lane bead. Lives under formulas/lib/ (ignored by formula
# discovery, which only matches .toml) next to the shared diff resolver
# (resolve-diff.sh) and the reviewer-agnostic verdict glue (review-verdict.sh).
#
# WHY a lib and not inlined per lane: the six lenses (quality / security /
# performance / architecture / testing / docs) are SEPARATELY-DISPATCHED beads,
# each its own polecat session, so each repeats the same read-inputs / gate /
# file-wisp / close transport. Inlining would duplicate it six times; this is the
# DRY single source of truth. Each lane stays fully self-contained: it sources
# THIS file via $GC_CITY (branch-independent, exactly like resolve-diff.sh) and
# communicates only through beads + the durable input files — never another
# lane's session memory.
#
# This is pure transport — ZERO judgment lives here (the lens reasoning is the
# agent's). Source it, then:
#
#   . "$GC_CITY/formulas/lib/review-lane.sh"
#   review_lane_load_inputs                          # sets REVIEW_* + heartbeats
#   [ "$REVIEW_ELIGIBLE" = "no" ] && { review_lane_close "<lens>: skipped — ineligible ($REVIEW_ELIGIBILITY_REASON)"; exit 0; }
#   # ... the agent reviews $REVIEW_DIFF / $REVIEW_SUMMARY through its lens ...
#   review_lane_file_finding <category> <confidence 0-100> <priority 0-4> "<title>" "$BODY_FILE"
#   review_lane_close "<lens>: filed <N> candidate finding(s) (category:<lens>)"
#
# Env (provided by the runtime): GC_BEAD_ID (this lane's bead), GC_CITY (city
# root). bd, gc, and jq are on PATH.
#
# Globals set by review_lane_load_inputs (all exported):
#   REVIEW_ROOT                molecule root bead id (the durable inputs hang off it)
#   REVIEW_INPUTS_DIR          $GC_CITY/.gc/review-inputs/<ROOT>
#   REVIEW_TARGET_KIND         pr | branch | range | path | empty
#   REVIEW_ELIGIBLE            yes | no (the analyze pass's eligibility verdict)
#   REVIEW_ELIGIBILITY_REASON  one-line reason behind that verdict
#   REVIEW_DIFF                $REVIEW_INPUTS_DIR/diff       (unified diff; whole-repo marker for a path target)
#   REVIEW_FILES               $REVIEW_INPUTS_DIR/files      (touched-file list)
#   REVIEW_SUMMARY             $REVIEW_INPUTS_DIR/summary.md (the shared change summary)
#   REVIEW_FINDINGS            <ROOT>.findings               (the per-run findings container id)

# Strip any non-JSON prefix lines (bd can emit "warning: ..." diagnostics on
# stdout before the payload) so jq parses the real JSON.
review_lane__json_payload() { awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'; }

# Read one metadata key off a bead's JSON (array- or object-shaped), empty if absent.
review_lane__meta() {
  bd show "$1" --json 2>/dev/null | review_lane__json_payload \
    | jq -r --arg k "$2" 'if type=="array" then .[0] else . end | .metadata[$k] // empty'
}

# review_lane_load_inputs — resolve the molecule root, read the analyze pass's
# durable-input handles off it, and expose them as REVIEW_* globals. Heartbeats
# this lane bead. Fails loudly (exit 2) if the durable input store is missing —
# that means the analyze contract was not satisfied, and a silent empty review
# would be worse than a hard stop.
review_lane_load_inputs() {
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  : "${GC_CITY:?GC_CITY must be set by the runtime}"
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true

  # Molecule ROOT — the durable inputs + findings container hang off it. A
  # single-bead molecule is its own root.
  REVIEW_ROOT="$(review_lane__meta "$GC_BEAD_ID" 'gc.root_bead_id')"
  [ -z "$REVIEW_ROOT" ] && REVIEW_ROOT="$GC_BEAD_ID"

  # Read the analyze pass's recorded handles off the root, retrying briefly so a
  # slow Dolt write right after analyze closed cannot read back empty.
  local i=0
  REVIEW_INPUTS_DIR=""
  while [ "$i" -lt 5 ]; do
    REVIEW_INPUTS_DIR="$(review_lane__meta "$REVIEW_ROOT" 'gc.review.inputs_dir')"
    [ -n "$REVIEW_INPUTS_DIR" ] && break
    i=$((i + 1))
    sleep 0.2
  done
  if [ -z "$REVIEW_INPUTS_DIR" ]; then
    echo "ERROR: no gc.review.inputs_dir on root $REVIEW_ROOT — the analyze pass must run before any lane." >&2
    return 2
  fi

  REVIEW_TARGET_KIND="$(review_lane__meta "$REVIEW_ROOT" 'gc.review.target_kind')"
  REVIEW_ELIGIBLE="$(review_lane__meta "$REVIEW_ROOT" 'gc.review.eligible')"
  REVIEW_ELIGIBILITY_REASON="$(review_lane__meta "$REVIEW_ROOT" 'gc.review.eligibility_reason')"
  REVIEW_DIFF="$REVIEW_INPUTS_DIR/diff"
  REVIEW_FILES="$REVIEW_INPUTS_DIR/files"
  REVIEW_SUMMARY="$REVIEW_INPUTS_DIR/summary.md"
  REVIEW_FINDINGS="${REVIEW_ROOT}.findings"

  export REVIEW_ROOT REVIEW_INPUTS_DIR REVIEW_TARGET_KIND REVIEW_ELIGIBLE \
    REVIEW_ELIGIBILITY_REASON REVIEW_DIFF REVIEW_FILES REVIEW_SUMMARY REVIEW_FINDINGS
  echo "[review-lane] root=$REVIEW_ROOT kind=$REVIEW_TARGET_KIND eligible=$REVIEW_ELIGIBLE inputs=$REVIEW_INPUTS_DIR"
}

# review_lane__ensure_container — create the per-run findings container ONCE under
# the molecule root. Idempotent: the fixed --id makes a repeat create a harmless
# no-op, so parallel lanes converge on the same container (NDI).
review_lane__ensure_container() {
  : "${REVIEW_FINDINGS:?call review_lane_load_inputs first}"
  bd show "$REVIEW_FINDINGS" >/dev/null 2>&1 || \
    bd create --id="$REVIEW_FINDINGS" --parent="$REVIEW_ROOT" \
      --title="Findings — standard code review (${REVIEW_ROOT})" \
      --description="Container for candidate findings from this standard (8-pass) review run. Each of the six lenses files its candidates here as ephemeral, category-labelled wisps; the synthesis pass dedup-merges them, assigns severity, and promotes the survivors to durable finding beads." \
      >/dev/null 2>&1 || true
}

# review_lane_file_finding <category> <confidence 0-100> <priority 0-4> <title> <body_file>
# File one candidate finding as an ephemeral wisp under the findings container.
# The wisp's first body line is the `Confidence: X/100` self-rating (the synthesis
# pass parses it and re-scores) and it carries a `category:<category>` label so its
# originating lens stays traceable — the same wisp convention as the triage
# reviewer's step 4b. Echoes the new wisp id.
review_lane_file_finding() {
  local category="$1" confidence="$2" priority="$3" title="$4" body_file="$5"
  : "${REVIEW_FINDINGS:?call review_lane_load_inputs first}"
  if [ ! -f "$body_file" ]; then
    echo "ERROR: review_lane_file_finding: body file not found: $body_file" >&2
    return 2
  fi
  review_lane__ensure_container

  # Compose the wisp body with the mandatory self-rating first line, then the
  # caller's finding detail. Centralising it here keeps every lane's wisps on the
  # one format the synthesis pass parses.
  local composed
  composed="$(mktemp)"
  {
    printf 'Confidence: %s/100\n\n' "$confidence"
    cat "$body_file"
  } > "$composed"

  local wisp
  wisp="$(bd create --ephemeral --silent \
    --parent="$REVIEW_FINDINGS" \
    --labels="category:${category}" \
    --priority="$priority" \
    --title="$title" \
    --body-file="$composed")"
  rm -f "$composed"
  printf '%s\n' "$wisp"
}

# review_lane_close <note> — heartbeat, then close this lane bead gc.outcome=pass
# with the given note. The single clean terminal for a lane: a real review, an
# ineligible no-op, and a zero-findings pass all close the same way.
review_lane_close() {
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true
  bd update "$GC_BEAD_ID" --set-metadata gc.outcome=pass --status=closed --notes "$1"
}
