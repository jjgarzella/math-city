#!/usr/bin/env bash
# Shared synthesis transport for the bead-native reviewers (the standard 8-pass
# reviewer's synthesis pass, gascity gcs-f4j.8.3; reused by the quorum variant
# gcs-f4j.5). Single source of truth for the verdict -> severity -> promote
# machinery: load the run's findings container + durable inputs, enumerate the
# candidate wisps the lanes filed, promote a survivor to a DURABLE
# severity-tagged finding bead, burn a duplicate/sub-threshold reject, and record
# the synthesis verdict + counts on the molecule root. Lives under formulas/lib/
# (ignored by formula discovery, which only matches .toml) next to the shared
# diff resolver (resolve-diff.sh), the lane helper (review-lane.sh), and the
# loop verdict glue (review-verdict.sh).
#
# This is pure transport — ZERO judgment lives here. The dedup-merge clustering
# (which candidates describe the SAME underlying issue) and the severity
# assignment are the synthesis agent's reasoning; this file only moves beads.
# Source it via $GC_CITY (branch-independent, exactly like the sibling libs):
#
#   . "$GC_CITY/formulas/lib/review-synthesis.sh"
#   review_synthesis_load                                    # sets REVIEW_* + heartbeats
#   review_synthesis_candidates                              # TSV: wisp \t category \t confidence \t title
#   review_synthesis_promote <wisp> <severity> "<reason>"    # -> durable finding bead
#   review_synthesis_burn    <wisp> "<reason>"               # duplicate or sub-threshold
#   review_synthesis_record_verdict <verdict> <considered> <promoted> <merged> <burned> "<note>"
#
# THE FINDING / VERDICT CONTRACT (defined here, gcs-f4j.8.3 — the same durable
# output plumbing the triage and quorum reviewers use, so apply-fixes stays
# reviewer-agnostic):
#
#   Finding bead — a durable child of <ROOT>.findings (promoted from a lane wisp):
#     label    severity:<blocker|major|minor|nit>   machine-readable final severity
#     label    category:<lens>                       preserved from the originating lane(s)
#     priority blocker=0  major=1  minor=2  nit=3     so `bd ready` ranks must-fix first
#     body     the lane wisp body (file:line, evidence) — left intact by promote
#
#   Synthesis verdict — metadata gc.review.synthesis_verdict on the molecule ROOT:
#     pass                 no finding survived at or above the severity threshold
#     pass_with_findings   findings survived, none a blocker
#     fail                 at least one blocker survived
#     blocked              synthesis could not run (ineligible / missing inputs)
#   plus gc.review.synthesis_{considered,promoted,merged,burned} counts.
#
# apply-fixes (and the human gate) consume the durable findings + this verdict;
# the loop's own done/iterate review.verdict (review-verdict.sh) is a SEPARATE
# signal written later by apply-fixes, not by synthesis.
#
# Env (provided by the runtime): GC_BEAD_ID (this synthesis bead), GC_CITY (city
# root). bd, gc, and jq are on PATH.

# Strip any non-JSON prefix (bd can emit "warning: ..." on stdout) so jq parses.
review_synthesis__json_payload() { awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'; }

review_synthesis__meta() {
  bd show "$1" --json 2>/dev/null | review_synthesis__json_payload \
    | jq -r --arg k "$2" 'if type=="array" then .[0] else . end | .metadata[$k] // empty'
}

# review_synthesis_load — resolve the molecule root, read the analyze pass's
# durable-input handles + findings container off it, and expose them as REVIEW_*
# globals. Heartbeats this synthesis bead. A single-bead molecule is its own root,
# so this works identically standalone (own root) and in-loop (loop root, where
# apply-fixes reads the same container).
review_synthesis_load() {
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  : "${GC_CITY:?GC_CITY must be set by the runtime}"
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true

  REVIEW_ROOT="$(review_synthesis__meta "$GC_BEAD_ID" 'gc.root_bead_id')"
  [ -z "$REVIEW_ROOT" ] && REVIEW_ROOT="$GC_BEAD_ID"

  REVIEW_INPUTS_DIR="$(review_synthesis__meta "$REVIEW_ROOT" 'gc.review.inputs_dir')"
  REVIEW_TARGET_KIND="$(review_synthesis__meta "$REVIEW_ROOT" 'gc.review.target_kind')"
  REVIEW_ELIGIBLE="$(review_synthesis__meta "$REVIEW_ROOT" 'gc.review.eligible')"
  REVIEW_DIFF="$REVIEW_INPUTS_DIR/diff"
  REVIEW_SUMMARY="$REVIEW_INPUTS_DIR/summary.md"
  REVIEW_FINDINGS="${REVIEW_ROOT}.findings"

  export REVIEW_ROOT REVIEW_INPUTS_DIR REVIEW_TARGET_KIND REVIEW_ELIGIBLE \
    REVIEW_DIFF REVIEW_SUMMARY REVIEW_FINDINGS
  echo "[review-synthesis] root=$REVIEW_ROOT findings=$REVIEW_FINDINGS eligible=${REVIEW_ELIGIBLE:-?} kind=${REVIEW_TARGET_KIND:-?}"
}

# review_synthesis_candidates — emit one TSV row per OPEN candidate wisp under the
# findings container: <wisp_id>\t<category>\t<confidence>\t<title>. The agent reads
# these (plus each wisp's full body via `bd show <id>`) to cluster + severity-rank.
# Empty output = the six lanes filed nothing, i.e. a clean pass. No container yet
# also means zero candidates (the lanes create it lazily on first finding).
review_synthesis_candidates() {
  : "${REVIEW_FINDINGS:?call review_synthesis_load first}"
  bd show "$REVIEW_FINDINGS" >/dev/null 2>&1 || return 0
  bd show "$REVIEW_FINDINGS" --json 2>/dev/null | review_synthesis__json_payload \
    | jq -r '
        (if type=="array" then .[0] else . end).children // []
        | .[]
        | select((.status // "") != "closed")
        | [ .id,
            ( (.labels // []) | map(select(startswith("category:")))
              | (.[0] // "category:?") | sub("^category:"; "") ),
            ( (.description // "")
              | (try (match("Confidence:[^0-9]*([0-9]+)").captures[0].string) catch "?") ),
            (.title // "") ]
        | @tsv'
}

# review_synthesis__priority_for <severity> — the severity -> bd priority map so
# `bd ready` ranks must-fix findings first. Unknown severity -> 2 (minor).
review_synthesis__priority_for() {
  case "$1" in
    blocker) echo 0 ;;
    major)   echo 1 ;;
    minor)   echo 2 ;;
    nit)     echo 3 ;;
    *)       echo 2 ;;
  esac
}

# review_synthesis_promote <wisp> <severity> <reason> — promote a surviving
# candidate to a durable finding bead: stamp the final severity:<level> label,
# re-rank its priority from that severity, then `bd promote` (which preserves the
# wisp id, its category labels, and its parent container). Echoes the bead id.
review_synthesis_promote() {
  local wisp="$1" severity="$2" reason="$3"
  : "${wisp:?usage: review_synthesis_promote <wisp> <severity> <reason>}"
  case "$severity" in
    blocker|major|minor|nit) : ;;
    *) echo "ERROR: review_synthesis_promote: invalid severity '$severity' (want blocker|major|minor|nit)" >&2; return 2 ;;
  esac
  bd label add "severity:${severity}" "$wisp" >/dev/null 2>&1 || true
  bd update "$wisp" --priority="$(review_synthesis__priority_for "$severity")" >/dev/null 2>&1 || true
  bd promote "$wisp" --reason="severity=${severity}: ${reason}" >/dev/null 2>&1 \
    || { echo "ERROR: review_synthesis_promote: bd promote failed for $wisp" >&2; return 2; }
  printf '%s\n' "$wisp"
}

# review_synthesis_burn <wisp> <reason> — burn a duplicate (folded into its
# canonical survivor) or a sub-threshold candidate. The reason is recorded in the
# run's audit note (passed through to record_verdict by the caller), not on the
# burned wisp, which ceases to exist.
review_synthesis_burn() {
  local wisp="$1" reason="${2:-}"
  : "${wisp:?usage: review_synthesis_burn <wisp> <reason>}"
  bd mol burn --force "$wisp" >/dev/null 2>&1 \
    || { echo "ERROR: review_synthesis_burn: bd mol burn failed for $wisp" >&2; return 2; }
  echo "[review-synthesis] burned $wisp${reason:+ ($reason)}"
}

# review_synthesis_record_verdict <verdict> <considered> <promoted> <merged> <burned> <note>
# Record the synthesis verdict + counts on the molecule ROOT, write the audit note
# to THIS synthesis bead, close the findings container, and close this bead
# gc.outcome=pass. The single clean terminal for the synthesis pass — a real
# review, a zero-findings clean pass, and an ineligible no-op all close the same.
review_synthesis_record_verdict() {
  local verdict="$1" considered="$2" promoted="$3" merged="$4" burned="$5" note="$6"
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  : "${REVIEW_ROOT:?call review_synthesis_load first}"
  case "$verdict" in
    pass|pass_with_findings|fail|blocked) : ;;
    *) echo "ERROR: review_synthesis_record_verdict: invalid verdict '$verdict'" >&2; return 2 ;;
  esac

  bd update "$REVIEW_ROOT" --set-metadata gc.review.synthesis_verdict="$verdict"     >/dev/null 2>&1 || true
  bd update "$REVIEW_ROOT" --set-metadata gc.review.synthesis_considered="$considered" >/dev/null 2>&1 || true
  bd update "$REVIEW_ROOT" --set-metadata gc.review.synthesis_promoted="$promoted"   >/dev/null 2>&1 || true
  bd update "$REVIEW_ROOT" --set-metadata gc.review.synthesis_merged="$merged"       >/dev/null 2>&1 || true
  bd update "$REVIEW_ROOT" --set-metadata gc.review.synthesis_burned="$burned"       >/dev/null 2>&1 || true

  # Close the container if it exists (survivors remain as its durable children).
  bd show "$REVIEW_FINDINGS" >/dev/null 2>&1 \
    && bd close "$REVIEW_FINDINGS" --reason="synthesis complete: verdict=$verdict, promoted=$promoted" >/dev/null 2>&1 || true

  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true
  bd update "$GC_BEAD_ID" --set-metadata gc.outcome=pass --status=closed \
    --notes "synthesis: verdict=$verdict; considered=$considered promoted=$promoted merged=$merged burned=$burned. $note"
  echo "[review-synthesis] verdict=$verdict considered=$considered promoted=$promoted merged=$merged burned=$burned"
}
