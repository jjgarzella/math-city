#!/usr/bin/env bash
# Shared apply-fixes transport for the review->fix loop family (gascity
# gcs-f4j.8.5). Single source of truth for the verdict -> severity -> fix
# mapping: read the reviewer's synthesis output (the verdict + the durable
# findings), map the synthesis verdict onto the loop's done/iterate
# review.verdict, write that verdict, and — when synthesis could make no
# progress (blocked) — terminate the loop to a human. Lives under formulas/lib/
# (ignored by formula discovery, which only matches .toml) next to the shared
# diff resolver (resolve-diff.sh), the lane helper (review-lane.sh), the
# synthesis transport (review-synthesis.sh), and the loop verdict-glue check
# (review-verdict.sh).
#
# This is the codex-INDEPENDENT half of the quorum fix machinery (gcs-f4j.5):
# it is built here for the standard single-provider loop variant
# (mol-review-loop-standard) and reused unchanged by the quorum variant when
# codex returns — the quorum only swaps a different reviewer fragment into the
# review-pipeline slot; the synthesis output contract + this mapping are
# reviewer-agnostic.
#
# THIS IS PURE TRANSPORT — ZERO judgment lives here. The per-finding fix-vs-
# surface call, whether a blocker is actually fixable, and whether a fix was
# applied this round are the apply-fixes agent's reasoning (ZFC). This file only
# moves beads: it reads what synthesis recorded, enumerates the durable
# findings, maps a fixed verdict vocabulary, and writes the result. The
# severity threshold is config (a formula var the agent is handed); ranking is
# never suppression.
#
# Source it via $GC_CITY (branch-independent, exactly like the sibling libs):
#
#   . "$GC_CITY/formulas/lib/review-apply-fixes.sh"
#   review_apply_fixes_load                              # sets REVIEW_* + heartbeats
#   review_apply_fixes_findings                          # TSV: id \t severity \t category \t title
#   review_apply_fixes_map_verdict <synth_verdict> <applied yes|no>   # -> done|iterate
#   review_apply_fixes_set_verdict <done|iterate> "<note>"            # write review.verdict + close
#   review_apply_fixes_escalate "<reason>"               # blocked / unfixable -> terminate-to-human
#
# THE INPUT CONTRACT (gcs-f4j.8.3 review-synthesis.sh — the same durable output
# every bead-native reviewer produces, so apply-fixes stays reviewer-agnostic):
#
#   Synthesis verdict — metadata gc.review.synthesis_verdict on the molecule ROOT:
#     pass                 no finding survived at or above the severity threshold
#     pass_with_findings   findings survived, none a blocker (major/minor)
#     fail                 at least one blocker survived (must-fix before merge)
#     blocked              synthesis could not run (ineligible / missing inputs)
#   plus gc.review.synthesis_{considered,promoted,merged,burned} counts. The
#   burned count is the "surfaced but sub-threshold" tally (e.g. nits when the
#   threshold is minor) — apply-fixes reports it; it does not fix it.
#
#   Durable findings — severity-tagged children of <ROOT>.findings (promoted by
#   synthesis): label severity:<blocker|major|minor|nit>, label category:<lens>,
#   priority blocker=0..nit=3. Every surviving child is at or above the
#   synthesis threshold, so apply-fixes fixes the set it is handed.
#
# THE OUTPUT CONTRACT (consumed by review-verdict.sh, the loop's ralph check):
#   review.verdict on THIS apply-fixes bead — done (converge, stop) | iterate
#   (re-review the fixes). The mapping:
#     synthesis pass               -> done     (nothing actionable; converge)
#     synthesis pass_with_findings -> iterate when fixes were applied, else done
#     synthesis fail               -> iterate  (blocker fixed; re-review)
#     synthesis blocked            -> done + escalate (terminate-to-human; the
#                                     loop cannot make progress, so stop rather
#                                     than spin to the cap, and flag a human)
#
# Env (provided by the runtime): GC_BEAD_ID (this apply-fixes bead), GC_CITY
# (city root). The fix threshold the agent applies is handed in via the
# FIX_THRESHOLD env var (the formula renders its severity_threshold var into it);
# it defaults to minor. bd and gc are on PATH.

# Strip any non-JSON prefix (bd can emit "warning: ..." on stdout) so jq parses.
review_apply_fixes__json_payload() { awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'; }

review_apply_fixes__meta() {
  bd show "$1" --json 2>/dev/null | review_apply_fixes__json_payload \
    | jq -r --arg k "$2" 'if type=="array" then .[0] else . end | .metadata[$k] // empty'
}

# review_apply_fixes__rank_for <severity> — the severity -> rank map (same order
# review-synthesis.sh uses for bd priority) so findings sort must-fix first.
# Unknown severity -> 2 (minor).
review_apply_fixes__rank_for() {
  case "$1" in
    blocker) echo 0 ;;
    major)   echo 1 ;;
    minor)   echo 2 ;;
    nit)     echo 3 ;;
    *)       echo 2 ;;
  esac
}

# review_apply_fixes_load — resolve the molecule root, read the synthesis verdict
# + counts synthesis recorded on it, the findings container, the work_dir under
# review (the feature branch apply-fixes resumes), and the fix threshold. Expose
# them as REVIEW_* globals and heartbeat this bead. A single-bead molecule is its
# own root, so this works identically standalone and in-loop (loop root, where
# the expanded reviewer's synthesis wrote the verdict this same root carries).
review_apply_fixes_load() {
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  : "${GC_CITY:?GC_CITY must be set by the runtime}"
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true

  REVIEW_ROOT="$(review_apply_fixes__meta "$GC_BEAD_ID" 'gc.root_bead_id')"
  [ -z "$REVIEW_ROOT" ] && REVIEW_ROOT="$GC_BEAD_ID"

  REVIEW_SYNTHESIS_VERDICT="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_verdict')"
  REVIEW_SYNTHESIS_PROMOTED="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_promoted')"
  REVIEW_SYNTHESIS_BURNED="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_burned')"
  REVIEW_WORK_DIR="$(review_apply_fixes__meta "$REVIEW_ROOT" 'work_dir')"
  [ -z "$REVIEW_WORK_DIR" ] && REVIEW_WORK_DIR="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.work_dir')"
  REVIEW_FINDINGS="${REVIEW_ROOT}.findings"
  REVIEW_FIX_THRESHOLD="${FIX_THRESHOLD:-minor}"

  export REVIEW_ROOT REVIEW_SYNTHESIS_VERDICT REVIEW_SYNTHESIS_PROMOTED \
    REVIEW_SYNTHESIS_BURNED REVIEW_WORK_DIR REVIEW_FINDINGS REVIEW_FIX_THRESHOLD
  echo "[review-apply-fixes] root=$REVIEW_ROOT verdict=${REVIEW_SYNTHESIS_VERDICT:-<none>} promoted=${REVIEW_SYNTHESIS_PROMOTED:-0} burned=${REVIEW_SYNTHESIS_BURNED:-0} fix_threshold=$REVIEW_FIX_THRESHOLD work_dir=${REVIEW_WORK_DIR:-<unset>}"
}

# review_apply_fixes_findings — emit one TSV row per DURABLE finding under the
# findings container: <id>\t<severity>\t<category>\t<title>, ranked must-fix
# first (blocker -> nit). These are the survivors synthesis promoted; the agent
# reads each one's full body via `bd show <id>` for the file:line + evidence, then
# fixes the ones at or above FIX_THRESHOLD and surfaces the rest. Empty output =
# synthesis promoted nothing (a clean pass). No container yet also means zero.
review_apply_fixes_findings() {
  : "${REVIEW_FINDINGS:?call review_apply_fixes_load first}"
  bd show "$REVIEW_FINDINGS" >/dev/null 2>&1 || return 0
  bd show "$REVIEW_FINDINGS" --json 2>/dev/null | review_apply_fixes__json_payload \
    | jq -r '
        (if type=="array" then .[0] else . end).children // []
        | .[]
        | select((.status // "") != "closed")
        | ( (.labels // []) | map(select(startswith("severity:")))
            | (.[0] // "") | sub("^severity:"; "") ) as $sev
        | select($sev != "")
        | { id: .id,
            sev: $sev,
            rank: ( {"blocker":0,"major":1,"minor":2,"nit":3}[$sev] // 2 ),
            cat: ( (.labels // []) | map(select(startswith("category:")))
                   | (.[0] // "category:?") | sub("^category:"; "") ),
            title: (.title // "") }
      ' \
    | jq -rs 'sort_by(.rank, .id) | .[] | [.id, .sev, .cat, .title] | @tsv'
}

# review_apply_fixes_map_verdict <synthesis_verdict> <applied yes|no> — map the
# synthesis verdict onto the loop's review.verdict. Pure lookup; the `applied`
# flag is the agent's report of whether this round changed the branch.
#   pass               -> done    (nothing actionable)
#   pass_with_findings -> iterate when fixes were applied, else done
#   fail               -> iterate (a blocker was surfaced and fixed; re-review)
#   blocked            -> done    (terminate; the caller must also escalate)
#   anything else      -> iterate (conservative: re-review rather than silently stop)
# blocked maps to done so the loop STOPS instead of spinning an unfixable state to
# the cap; review_apply_fixes_escalate is the partner that flags the human.
review_apply_fixes_map_verdict() {
  local sv="$1" applied="${2:-no}"
  case "$sv" in
    pass)               echo done ;;
    pass_with_findings) [ "$applied" = yes ] && echo iterate || echo done ;;
    fail)               echo iterate ;;
    blocked)            echo done ;;
    *)                  echo iterate ;;
  esac
}

# review_apply_fixes_set_verdict <done|iterate> <note> — write review.verdict
# onto THIS apply-fixes bead (the glue the loop's check reads), heartbeat, and
# close the bead gc.outcome=pass. The verdict is set BEFORE the close so it is
# visible when the controller runs review-verdict.sh (the check bead is blocked
# by this body, so it runs after this closes).
review_apply_fixes_set_verdict() {
  local verdict="$1" note="${2:-}"
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  case "$verdict" in
    done|iterate) : ;;
    *) echo "ERROR: review_apply_fixes_set_verdict: invalid verdict '$verdict' (want done|iterate)" >&2; return 2 ;;
  esac
  bd update "$GC_BEAD_ID" --set-metadata review.verdict="$verdict" >/dev/null 2>&1 || true
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true
  bd update "$GC_BEAD_ID" --set-metadata gc.outcome=pass --status=closed \
    --notes "apply-fixes: review.verdict=$verdict. $note"
  echo "[review-apply-fixes] review.verdict=$verdict"
}

# review_apply_fixes_escalate <reason> — terminate the loop to a human. Used when
# synthesis is blocked (could not run) or a surviving blocker is genuinely
# unfixable by the agent: record gc.review.loop_outcome=blocked-needs-human +
# the reason on the molecule ROOT (so the overseer/human gate sees it), then set
# review.verdict=done so the loop STOPS rather than spinning to its cap. The
# verdict-glue check treats done as a converged terminal — if the loop was slung
# with a notify target, that terminal transition fires the fire-and-forget nudge,
# the human-notification path. The loop does not abort_scope; this is a clean stop
# with a flag a human picks up.
review_apply_fixes_escalate() {
  local reason="${1:-synthesis blocked}"
  : "${GC_BEAD_ID:?GC_BEAD_ID must be set by the runtime}"
  : "${REVIEW_ROOT:?call review_apply_fixes_load first}"
  bd update "$REVIEW_ROOT" --set-metadata gc.review.loop_outcome="blocked-needs-human" >/dev/null 2>&1 || true
  bd update "$REVIEW_ROOT" --set-metadata gc.review.loop_blocked_reason="$reason"       >/dev/null 2>&1 || true
  echo "[review-apply-fixes] TERMINATE-TO-HUMAN: $reason" >&2
  review_apply_fixes_set_verdict done "TERMINATE-TO-HUMAN: $reason (gc.review.loop_outcome=blocked-needs-human on $REVIEW_ROOT)"
}
