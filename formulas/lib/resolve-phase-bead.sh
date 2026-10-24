#!/usr/bin/env bash
# Resolve and validate the phase bead that a review formula may mutate.
#
# Call `review_phase_resolve <phase-suffix> [expected-root]` before heartbeats,
# updates, or closes on GC_BEAD_ID. The suffix is the final component of the
# formula's gc.step_id (for example, `review-pipeline.apply-fixes` matches
# `apply-fixes`). When GC_BEAD_ID is absent, use the supported session claim
# lookup, then validate the result through bd before exposing it to callers.

review_phase__json_payload() {
  awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'
}

review_phase_resolve() {
  local expected_suffix="${1:-}" expected_root="${2:-}" expected_step_id="${3:-}"
  local bead_id source raw payload actual_id step_id root_id kind
  local root_raw root_payload root_actual_id

  case "$expected_suffix" in
    ''|*[!a-zA-Z0-9._-]*)
      echo "ERROR: review_phase_resolve: expected a valid gc.step_id suffix" >&2
      return 2
      ;;
  esac

  if [ -n "${GC_BEAD_ID:-}" ]; then
    bead_id="$GC_BEAD_ID"
    source="GC_BEAD_ID"
  else
    if ! command -v gc >/dev/null 2>&1; then
      echo "ERROR: review_phase_resolve: GC_BEAD_ID is empty and gc is unavailable" >&2
      return 2
    fi
    bead_id="$(gc hook current --id-only 2>/dev/null)" || {
      echo "ERROR: review_phase_resolve: could not resolve the current phase with 'gc hook current --id-only'" >&2
      return 2
    }
    source="gc hook current"
  fi
  if [ -z "$bead_id" ]; then
    echo "ERROR: review_phase_resolve: $source returned no bead for phase '$expected_suffix'" >&2
    return 2
  fi

  raw="$(bd show "$bead_id" --json 2>/dev/null)" || {
    echo "ERROR: review_phase_resolve: cannot read phase bead '$bead_id'" >&2
    return 2
  }
  payload="$(printf '%s\n' "$raw" | review_phase__json_payload)"
  if [ -z "$payload" ] || ! printf '%s\n' "$payload" | jq -e 'if type == "array" then (.[0] | type == "object") else type == "object" end' >/dev/null 2>&1; then
    echo "ERROR: review_phase_resolve: malformed bead JSON for '$bead_id'" >&2
    return 2
  fi

  actual_id="$(printf '%s\n' "$payload" | jq -r 'if type == "array" then .[0].id // empty else .id // empty end')"
  step_id="$(printf '%s\n' "$payload" | jq -r 'if type == "array" then .[0].metadata["gc.step_id"] // empty else .metadata["gc.step_id"] // empty end')"
  root_id="$(printf '%s\n' "$payload" | jq -r 'if type == "array" then .[0].metadata["gc.root_bead_id"] // empty else .metadata["gc.root_bead_id"] // empty end')"
  kind="$(printf '%s\n' "$payload" | jq -r 'if type == "array" then .[0].metadata["gc.kind"] // empty else .metadata["gc.kind"] // empty end')"

  if [ "$actual_id" != "$bead_id" ]; then
    echo "ERROR: review_phase_resolve: bd returned '$actual_id' while resolving '$bead_id'" >&2
    return 2
  fi
  case "$step_id" in
    "$expected_suffix"|*."$expected_suffix") ;;
    *)
      echo "ERROR: review_phase_resolve: bead '$bead_id' has gc.step_id='${step_id:-<missing>}'; expected phase '$expected_suffix'" >&2
      return 2
      ;;
  esac
  if [ -n "$expected_step_id" ] && [ "$step_id" != "$expected_step_id" ]; then
    echo "ERROR: review_phase_resolve: bead '$bead_id' has gc.step_id='$step_id', expected '$expected_step_id'" >&2
    return 2
  fi

  # Phase beads in the current graph carry no gc.kind. Permit explicit phase
  # kinds, and fail closed on every other kind so workflow/scope/control beads
  # can never be mistaken for a phase terminal.
  case "$kind" in
    ''|step|phase) ;;
    *)
      echo "ERROR: review_phase_resolve: refusing to mutate bead '$bead_id' with control gc.kind='$kind' (phase '$expected_suffix')" >&2
      return 2
      ;;
  esac

  if [ -z "$root_id" ]; then
    # Preserve standalone, single-bead formulas: a validated phase can be its
    # own root when gc.root_bead_id is not populated.
    root_id="$bead_id"
  fi
  if [ -n "$expected_root" ] && [ "$root_id" != "$expected_root" ]; then
    echo "ERROR: review_phase_resolve: phase bead '$bead_id' belongs to root '$root_id', expected '$expected_root'" >&2
    return 2
  fi

  if [ "$root_id" = "$bead_id" ]; then
    root_payload="$payload"
    root_actual_id="$actual_id"
  else
    root_raw="$(bd show "$root_id" --json 2>/dev/null)" || {
      echo "ERROR: review_phase_resolve: cannot read root '$root_id' for phase bead '$bead_id'" >&2
      return 2
    }
    root_payload="$(printf '%s\n' "$root_raw" | review_phase__json_payload)"
    if [ -z "$root_payload" ] || ! printf '%s\n' "$root_payload" | jq -e 'if type == "array" then (.[0] | type == "object") else type == "object" end' >/dev/null 2>&1; then
      echo "ERROR: review_phase_resolve: malformed root JSON for '$root_id'" >&2
      return 2
    fi
    root_actual_id="$(printf '%s\n' "$root_payload" | jq -r 'if type == "array" then .[0].id // empty else .id // empty end')"
  fi
  if [ "$root_actual_id" != "$root_id" ]; then
    echo "ERROR: review_phase_resolve: gc.root_bead_id '$root_id' did not resolve to that root bead" >&2
    return 2
  fi
  REVIEW_PHASE_BEAD_ID="$bead_id"
  REVIEW_PHASE_ROOT_ID="$root_id"
  REVIEW_PHASE_STEP_ID="$step_id"
  REVIEW_PHASE_SUFFIX="$expected_suffix"
  GC_BEAD_ID="$bead_id"
  export REVIEW_PHASE_BEAD_ID REVIEW_PHASE_ROOT_ID REVIEW_PHASE_STEP_ID REVIEW_PHASE_SUFFIX GC_BEAD_ID
}
