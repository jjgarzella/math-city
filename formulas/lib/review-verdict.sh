#!/usr/bin/env bash
# Shared, reviewer-AGNOSTIC verdict-glue check for the mol-review-loop family
# (gascity gcs-f4j.3). Single source of truth — the base loop and the Tier-2
# quorum variant (gcs-f4j.5) both run THIS exact script as their ralph
# [steps.check]. Lives under formulas/lib/ (ignored by formula discovery,
# which only matches .toml) next to the shared diff resolver (gcs-f4j.2).
#
# The controller runs this after each iteration body closes. It reads the
# newest review.verdict written by THIS attempt's apply-fixes bead and maps it
# to a ralph check exit code:
#
#   exit 0 = converged   (verdict done/approved/pass)            -> stop, clean pass
#   exit 1 = iterate      (verdict iterate/fail/retry, or unknown) -> next attempt
#   exit 2 = undetermined (no verdict visible within the budget) -> fail-closed
#
# The ralph runtime treats exit 0 as GatePass (stop) and EVERY non-zero exit as
# GateFail (iterate, bounded by max_attempts) — so exit 1 and exit 2 differ only
# for diagnosis (the code is persisted to gc.exit_code), never in control flow.
# There is no abort_scope: a non-converging loop simply iterates to its cap and
# the ralph control bead closes gc.outcome=fail, a clean terminal.
#
# Robustness: this reuses the two-read sampling of the gastown adopt-pr review
# check (assets/scripts/checks/adopt-pr-review-approved.sh) — it keeps reading
# the store until two consecutive reads agree, so a slow Dolt write can't make
# the loop act on a stale verdict. It is reviewer-agnostic: it matches the
# apply-fixes bead by (root, attempt, step_ref ~ "apply-fixes") rather than by
# formula name, so the same script drives every variant of the loop.
#
# Optional fire-and-forget notify: if the molecule root carries
# gc.review_loop.notify=<session id-or-alias>, a TERMINAL transition (converged,
# or the loop is about to exhaust its iteration cap) sends a best-effort
# `gc session nudge`. The nudge is never allowed to affect the exit code.
#
# Env (from convergence.ConditionEnv): GC_BEAD_ID (ralph subject scope bead),
# GC_ITERATION (attempt number), BEADS_DIR (so bare `bd` works), GC_CITY. bd,
# gc, and jq are on PATH.
set -uo pipefail

# Strip any non-JSON prefix lines (e.g. bd's "warning: ..." diagnostics emitted
# on stdout before the payload) so jq parses the real JSON.
json_payload() { awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'; }

BEAD_ID="${GC_BEAD_ID:-}"
if [ -z "$BEAD_ID" ]; then
  echo "ERROR: GC_BEAD_ID not set" >&2
  exit 2
fi

# --- resolve attempt + root from the ralph subject bead (retry for store lag) -
ATTEMPT="${GC_ITERATION:-}"
ROOT=""
i=0
while [ "$i" -lt 5 ]; do
  BJSON=$(bd show "$BEAD_ID" --json 2>/dev/null | json_payload)
  if [ -n "$BJSON" ]; then
    if [ -z "$ATTEMPT" ]; then
      ATTEMPT=$(printf '%s\n' "$BJSON" | jq -r 'if type=="array" then .[0] else . end | .metadata["gc.attempt"] // ""')
    fi
    ROOT=$(printf '%s\n' "$BJSON" | jq -r 'if type=="array" then .[0] else . end | .metadata["gc.root_bead_id"] // ""')
    [ -n "$ATTEMPT" ] && [ -n "$ROOT" ] && break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ -z "$ATTEMPT" ] || [ -z "$ROOT" ]; then
  echo "ERROR: missing gc.attempt ($ATTEMPT) or gc.root_bead_id ($ROOT) on $BEAD_ID" >&2
  exit 2
fi

# --- optional fire-and-forget notify (best-effort; never changes the exit) ----
# Fires only on a TERMINAL transition: a converged verdict, or the loop is about
# to hit its cap. The cap (max_attempts) is read from the ralph control bead
# rather than GC_MAX_ITERATIONS, which the ralph check env does not populate.
notify_terminal() {
  local outcome="$1" verdict="$2" target maxatt
  target=$(bd show "$ROOT" --json 2>/dev/null | json_payload |
    jq -r 'if type=="array" then .[0] else . end | .metadata["gc.review_loop.notify"] // ""')
  [ -n "$target" ] || return 0

  if [ "$outcome" != "converged" ]; then
    # Not converged — only a terminal transition if this attempt is the cap.
    maxatt=$(bd list --all --json --limit=0 2>/dev/null | json_payload |
      jq -r --arg root "$ROOT" '
        [ .[] | select(.metadata["gc.root_bead_id"] == $root)
              | select(.metadata["gc.kind"] == "ralph")
              | .metadata["gc.max_attempts"] // empty ] | (.[0] // "")
      ' 2>/dev/null)
    case "$maxatt" in
      ''|*[!0-9]*) return 0 ;;                       # unknown cap -> skip cap-notify
    esac
    [ "$ATTEMPT" -ge "$maxatt" ] 2>/dev/null || return 0
    outcome="capped"
  fi

  gc session nudge "$target" \
    "mol-review-loop $outcome: root=$ROOT attempt=$ATTEMPT verdict=${verdict:-none}" \
    >/dev/null 2>&1 || true
}

# --- two-read stable sample of the newest review.verdict for this attempt -----
# Match the apply-fixes bead by root + attempt + step_ref (reviewer-agnostic:
# any step whose ref contains "apply-fixes"), newest review.verdict wins. Keep
# sampling until two consecutive reads agree, within a ~2s budget.
read_verdict() {
  bd list --all --json --limit=0 2>/dev/null |
    json_payload |
    jq -r --arg root "$ROOT" --arg attempt "$ATTEMPT" '
      [ .[]
        | select(.metadata["gc.root_bead_id"] == $root)
        | select((.metadata["gc.attempt"] // "") == $attempt)
        | select((.metadata["gc.step_ref"] // "") | test("apply-fixes"))
        | select((.metadata["review.verdict"] // "") != "")
        | { v: .metadata["review.verdict"], t: (.updated_at // .created_at // ""), id: (.id // "") }
      ] | sort_by(.t, .id) | (.[-1].v // "")
    ' 2>/dev/null
}

prev=""
current=""
i=0
while [ "$i" -lt 10 ]; do
  current=$(read_verdict) || current=""
  if [ -n "$current" ] && [ "$current" = "$prev" ]; then
    break
  fi
  prev="$current"
  i=$((i + 1))
  sleep 0.2
done
if [ -z "$current" ]; then
  echo "ERROR: no review.verdict for root=$ROOT attempt=$ATTEMPT" >&2
  notify_terminal "undetermined" ""   # may still be a capped terminal
  exit 2
fi

case "$current" in
  done|approved|pass)
    echo "review.verdict=$current (attempt $ATTEMPT) -> converged, stop"
    notify_terminal "converged" "$current"
    exit 0
    ;;
  iterate|fail|retry)
    echo "review.verdict=$current (attempt $ATTEMPT) -> iterate"
    notify_terminal "iterate" "$current"
    exit 1
    ;;
  *)
    echo "unknown review.verdict=$current (attempt $ATTEMPT) -> iterate" >&2
    notify_terminal "iterate" "$current"
    exit 1
    ;;
esac
