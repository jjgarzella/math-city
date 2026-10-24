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
# The per-finding fix-vs-surface call, whether a blocker is actually fixable,
# and whether a fix was applied this round are the apply-fixes agent's reasoning
# (ZFC); ZERO judgment about what to fix or surface lives here. This file moves
# the durable review state and guards filesystem side effects: edits stay within
# the reviewed paths and related tests, the configured test command satisfies
# its gate before commit, and a successful commit is pushed before the loop
# advances. The severity
# threshold remains config (a formula var the agent is handed); ranking is never
# suppression.
#
# Source it via $GC_CITY (branch-independent, exactly like the sibling libs):
#
#   . "$GC_CITY/formulas/lib/review-apply-fixes.sh"
#   review_apply_fixes_load <phase-suffix>                # sets REVIEW_* + heartbeats
#   review_apply_fixes_findings                          # TSV: id \t severity \t category \t title
#   review_apply_fixes_map_verdict <synth_verdict> <applied yes|no>   # -> done|iterate
#   review_apply_fixes_set_verdict <done|iterate> "<note>"            # write review.verdict + close
#   review_apply_fixes_escalate "<reason>"               # blocked / unfixable -> terminate-to-human
#   review_apply_fixes_check_allowed_paths [newline-list]  # refuse out-of-scope edits
#   review_apply_fixes_test_before_commit [command]        # configured test gate
#   review_apply_fixes_commit_and_push "<message>"         # scope -> tests -> commit -> push
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
# (city root). The formula passes FIX_THRESHOLD, TEST_COMMAND, and ALLOWED_PATHS;
# TEST_GATE, and TEST_FAILURE_PATTERN. Empty ALLOWED_PATHS derives an allowlist
# from the reviewed diff and related tests; empty TEST_COMMAND falls back to
# gc.var.test_command on the root. Empty TEST_GATE defaults to the temporary
# no-new-failures policy; strict remains the permanent target. bd, gc, and git
# are on PATH.

# Strip any non-JSON prefix (bd can emit "warning: ..." on stdout) so jq parses.
review_apply_fixes__json_payload() { awk 'found || /^[[:space:]]*[[{]/{ found=1; print }'; }

# Query the parent-child edges rather than bd show .children (absent in bd 1.3).
# dep list includes both durable issues and wisps, without a list pagination cap.
# Check the root's edges first: an absent lazy container is a valid empty run;
# a failed database read must never masquerade as a clean review.
review_apply_fixes__children() {
  local parents children present
  parents="$(bd dep list "$REVIEW_ROOT" --direction up --type parent-child --json)" || return 2
  present="$(printf '%s\n' "$parents" | review_apply_fixes__json_payload | jq -er --arg id "$REVIEW_FINDINGS" \
    'if type != "array" then error("expected dependency array") else any(.[]; .id == $id) | tostring end')" || return 2
  if [ "$present" = false ]; then
    printf '[]\n'
    return 0
  fi
  children="$(bd dep list "$REVIEW_FINDINGS" --direction up --type parent-child --json)" || return 2
  printf '%s\n' "$children" | review_apply_fixes__json_payload | jq -e \
    'if type == "array" then . else error("expected dependency array") end'
}

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

# review_apply_fixes_load <phase-suffix> — resolve this apply-fixes step bead,
# then resolve the molecule root, read the synthesis verdict
# + counts synthesis recorded on it, the findings container, the work_dir under
# review (the feature branch apply-fixes resumes), and the fix threshold. Expose
# them as REVIEW_* globals and heartbeat this bead. A single-bead molecule is its
# own root, so this works identically standalone and in-loop (loop root, where
# the expanded reviewer's synthesis wrote the verdict this same root carries).
review_apply_fixes_load() {
  local phase_suffix="${1:-}"
  : "${GC_CITY:?GC_CITY must be set by the runtime}"
  if [ -z "$phase_suffix" ]; then
    echo "ERROR: review_apply_fixes_load: pass the apply-fixes gc.step_id suffix" >&2
    return 2
  fi
  unset REVIEW_PHASE_BEAD_ID REVIEW_PHASE_ROOT_ID REVIEW_PHASE_STEP_ID REVIEW_PHASE_SUFFIX
  . "$GC_CITY/formulas/lib/resolve-phase-bead.sh" || return 2
  review_phase_resolve "$phase_suffix" || return 2
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true

  REVIEW_ROOT="$REVIEW_PHASE_ROOT_ID"

  REVIEW_SYNTHESIS_VERDICT="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_verdict')"
  REVIEW_SYNTHESIS_PROMOTED="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_promoted')"
  REVIEW_SYNTHESIS_BURNED="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.synthesis_burned')"
  REVIEW_WORK_DIR="$(review_apply_fixes__meta "$REVIEW_ROOT" 'work_dir')"
  [ -z "$REVIEW_WORK_DIR" ] && REVIEW_WORK_DIR="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.work_dir')"
  REVIEW_BASE_SHA="${BASE_SHA:-}"
  [ -z "$REVIEW_BASE_SHA" ] && REVIEW_BASE_SHA="$(review_apply_fixes__meta "$REVIEW_ROOT" 'base_sha')"
  REVIEW_BASE_BRANCH="${BASE_BRANCH:-}"
  [ -z "$REVIEW_BASE_BRANCH" ] && REVIEW_BASE_BRANCH="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.var.base_branch')"
  [ -z "$REVIEW_BASE_BRANCH" ] && REVIEW_BASE_BRANCH="main"
  REVIEW_TEST_COMMAND="${TEST_COMMAND:-}"
  [ -z "$REVIEW_TEST_COMMAND" ] && REVIEW_TEST_COMMAND="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.var.test_command')"
  REVIEW_TEST_GATE="${TEST_GATE:-}"
  [ -z "$REVIEW_TEST_GATE" ] && REVIEW_TEST_GATE="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.var.test_gate')"
  [ -z "$REVIEW_TEST_GATE" ] && REVIEW_TEST_GATE="no-new-failures"
  REVIEW_TEST_FAILURE_PATTERN="${TEST_FAILURE_PATTERN:-}"
  [ -z "$REVIEW_TEST_FAILURE_PATTERN" ] && REVIEW_TEST_FAILURE_PATTERN="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.var.test_failure_pattern')"
  REVIEW_ALLOWED_PATHS="${ALLOWED_PATHS:-}"
  [ -z "$REVIEW_ALLOWED_PATHS" ] && REVIEW_ALLOWED_PATHS="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.var.allowed_paths')"
  REVIEW_FINDINGS="${REVIEW_ROOT}.findings"
  REVIEW_FIX_THRESHOLD="${FIX_THRESHOLD:-minor}"

  export REVIEW_ROOT REVIEW_SYNTHESIS_VERDICT REVIEW_SYNTHESIS_PROMOTED \
    REVIEW_SYNTHESIS_BURNED REVIEW_WORK_DIR REVIEW_BASE_SHA REVIEW_BASE_BRANCH \
    REVIEW_TEST_COMMAND REVIEW_TEST_GATE REVIEW_TEST_FAILURE_PATTERN \
    REVIEW_ALLOWED_PATHS REVIEW_FINDINGS REVIEW_FIX_THRESHOLD
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
  local children
  children="$(review_apply_fixes__children)" || return 2
  printf '%s\n' "$children" | jq -r '
        [ .[]
        | select((.status // "") != "closed" and (.ephemeral // false) == false)
        | ( (.labels // []) | map(select(startswith("severity:")))
            | (.[0] // "") | sub("^severity:"; "") ) as $sev
        | select($sev != "")
        | { id: .id,
            sev: $sev,
            rank: ( {"blocker":0,"major":1,"minor":2,"nit":3}[$sev] // 2 ),
            cat: ( (.labels // []) | map(select(startswith("category:")))
                   | (.[0] // "category:?") | sub("^category:"; "") ),
            title: (.title // "") } ]
        | sort_by(.rank, .id) | .[] | [.id, .sev, .cat, .title] | @tsv'
}

# review_apply_fixes__valid_path <path> — path-list entries are repo-relative
# and may not escape the worktree. Newline-containing git paths cannot be
# represented by the newline-delimited allowed_paths var, so fail closed.
review_apply_fixes__valid_path() {
  local path="$1"
  case "$path" in
    ""|/*|.|..|../*|*/../*|*/..|*$'\n'*) return 1 ;;
    *) return 0 ;;
  esac
}

# review_apply_fixes__base_ref — return the immutable review base, or resolve
# the configured base branch when a direct sling has no recorded base_sha.
review_apply_fixes__base_ref() {
  local base="${REVIEW_BASE_SHA:-}" branch="${REVIEW_BASE_BRANCH:-main}"
  : "${REVIEW_WORK_DIR:?call review_apply_fixes_load first}"
  if [ -n "$base" ]; then
    git -C "$REVIEW_WORK_DIR" rev-parse --verify "$base^{commit}" 2>/dev/null || {
      echo "ERROR: invalid review base commit: $base" >&2
      return 2
    }
    return 0
  fi
  base="$(git -C "$REVIEW_WORK_DIR" merge-base "$branch" HEAD 2>/dev/null)" \
    || base="$(git -C "$REVIEW_WORK_DIR" merge-base "origin/$branch" HEAD 2>/dev/null)" \
    || {
      echo "ERROR: cannot resolve review base branch $branch" >&2
      return 2
    }
  printf '%s\n' "$base"
}

# review_apply_fixes__reviewed_paths — NUL-delimited paths already present in
# the immutable diff under review. Local edits must never widen the default list.
review_apply_fixes__reviewed_paths() {
  local base
  : "${REVIEW_WORK_DIR:?call review_apply_fixes_load first}"
  base="$(review_apply_fixes__base_ref)" || return $?
  git -C "$REVIEW_WORK_DIR" diff --name-only -z "$base..HEAD" || return 2
}

# review_apply_fixes__changed_paths — NUL-delimited reviewed, staged, unstaged,
# and untracked paths. Ignored runtime files are deliberately excluded.
review_apply_fixes__changed_paths() {
  : "${REVIEW_WORK_DIR:?call review_apply_fixes_load first}"
  review_apply_fixes__reviewed_paths || return $?
  git -C "$REVIEW_WORK_DIR" diff --name-only -z || return 2
  git -C "$REVIEW_WORK_DIR" diff --cached --name-only -z || return 2
  git -C "$REVIEW_WORK_DIR" ls-files --others --exclude-standard -z || return 2
}

# review_apply_fixes__append_test_tree <suite-dir> <allow-file> — add the
# existing tests plus a directory prefix so new related tests are also allowed.
review_apply_fixes__append_test_tree() {
  local suite="$1" allow_file="$2" files_file path
  [ -n "$suite" ] || return 0
  printf '%s/\n' "$suite" >> "$allow_file" || return 2
  files_file="$(mktemp)" || return 2
  git -C "$REVIEW_WORK_DIR" ls-files --cached --others --exclude-standard -z -- "$suite" > "$files_file" || {
    rm -f "$files_file"
    return 2
  }
  while IFS= read -r -d '' path; do
    review_apply_fixes__valid_path "$path" || {
      echo "ERROR: unsupported test path in allowlist: $path" >&2
      rm -f "$files_file"
      return 2
    }
    printf '%s\n' "$path" >> "$allow_file" || {
      rm -f "$files_file"
      return 2
    }
  done < "$files_file"
  rm -f "$files_file"
}

# review_apply_fixes__append_related_tests <changed-path> <allow-file> — match
# formula files to their suite and shared helpers to test suites that reference
# them. Also allow existing top-level test trees for source changes. Existing test
# files are listed exactly; suite prefixes cover new tests.
review_apply_fixes__append_related_tests() {
  local path="$1" allow_file="$2" suite="" name hits_file test_path rest grep_status root_suite
  case "$path" in
    formulas/*.toml)
      name="${path##*/}"
      name="${name%.toml}"
      suite="formulas/test/$name"
      review_apply_fixes__append_test_tree "$suite" "$allow_file" || return $?
      ;;
    formulas/test/*)
      rest="${path#formulas/test/}"
      suite="formulas/test/${rest%%/*}"
      review_apply_fixes__append_test_tree "$suite" "$allow_file" || return $?
      ;;
    formulas/lib/*)
      name="${path##*/}"
      hits_file="$(mktemp)" || return 2
      if git -C "$REVIEW_WORK_DIR" grep -l -z -F -e "$name" -- formulas/test > "$hits_file" 2>/dev/null; then
        while IFS= read -r -d '' test_path; do
          rest="${test_path#formulas/test/}"
          suite="formulas/test/${rest%%/*}"
          review_apply_fixes__append_test_tree "$suite" "$allow_file" || {
            rm -f "$hits_file"
            return 2
          }
        done < "$hits_file"
      else
        grep_status=$?
        if [ "$grep_status" -gt 1 ]; then
          echo "ERROR: cannot find tests referencing $path" >&2
          rm -f "$hits_file"
          return 2
        fi
      fi
      rm -f "$hits_file"
      ;;
  esac

  # Rigs commonly keep tests in one of the repository's top-level test trees.
  # Allow those trees for any reviewed path, but only when they already exist;
  # the reviewed source paths themselves remain the only non-test paths allowed.
  for root_suite in test tests; do
    if [ -d "$REVIEW_WORK_DIR/$root_suite" ]; then
      review_apply_fixes__append_test_tree "$root_suite" "$allow_file" || return $?
    fi
  done
}

# review_apply_fixes_allowed_paths [newline-list] — print the effective allowlist.
# An explicit list is exact apart from entries ending in /, which authorize that
# directory subtree. The default is the reviewed diff plus related test suites.
review_apply_fixes_allowed_paths() {
  local explicit="${1:-${REVIEW_ALLOWED_PATHS:-}}" allow_file changed_file path line
  if [ -n "$explicit" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      review_apply_fixes__valid_path "${line%/}" || {
        echo "ERROR: invalid allowed_paths entry: $line" >&2
        return 2
      }
      printf '%s\n' "$line"
    done < <(printf '%s\n' "$explicit")
    return 0
  fi

  allow_file="$(mktemp)" || return 2
  changed_file="$(mktemp)" || { rm -f "$allow_file"; return 2; }
  if ! review_apply_fixes__reviewed_paths > "$changed_file"; then
    rm -f "$allow_file" "$changed_file"
    return 2
  fi
  while IFS= read -r -d '' path; do
    review_apply_fixes__valid_path "$path" || {
      echo "ERROR: unsupported path in reviewed diff: $path" >&2
      rm -f "$allow_file" "$changed_file"
      return 2
    }
    printf '%s\n' "$path" >> "$allow_file" || {
      rm -f "$allow_file" "$changed_file"
      return 2
    }
    review_apply_fixes__append_related_tests "$path" "$allow_file" || {
      rm -f "$allow_file" "$changed_file"
      return 2
    }
  done < "$changed_file"
  sort -u "$allow_file"
  local sort_status=$?
  rm -f "$allow_file" "$changed_file"
  return "$sort_status"
}

# review_apply_fixes_check_allowed_paths [newline-list] — refuse the commit if
# any tracked, staged, unstaged, or non-ignored untracked edit is outside scope.
# Returns 3 for a scope violation, 2 for an inspection failure, 0 when clean.
review_apply_fixes_check_allowed_paths() {
  local explicit="${1:-${REVIEW_ALLOWED_PATHS:-}}" allow_file changed_file path line ok violation=0
  allow_file="$(mktemp)" || return 2
  changed_file="$(mktemp)" || { rm -f "$allow_file"; return 2; }
  if ! review_apply_fixes_allowed_paths "$explicit" > "$allow_file"; then
    rm -f "$allow_file" "$changed_file"
    return 2
  fi
  if ! review_apply_fixes__changed_paths > "$changed_file"; then
    rm -f "$allow_file" "$changed_file"
    return 2
  fi
  while IFS= read -r -d '' path; do
    review_apply_fixes__valid_path "$path" || {
      echo "ERROR: unsupported changed path: $path" >&2
      violation=1
      continue
    }
    ok=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        */) case "$path" in "$line"*) ok=1 ;; esac ;;
        *) [ "$path" = "$line" ] && ok=1 ;;
      esac
    done < "$allow_file"
    if [ "$ok" -ne 1 ]; then
      echo "ERROR: out-of-scope edit refused: $path" >&2
      violation=1
    fi
  done < "$changed_file"
  rm -f "$allow_file" "$changed_file"
  [ "$violation" -eq 0 ] || return 3
  echo "[review-apply-fixes] allowed-path check passed"
}

# review_apply_fixes__failure_set <output-file> [pattern] — emit a sorted unique
# set of failure identifiers. A configured pattern is a Bash ERE with exactly
# one capture group. Without one, keep normalized output lines that mention
# FAIL/ERROR, replacing volatile timings and memory addresses first.
review_apply_fixes__failure_set() {
  local output_file="$1" pattern="${2:-}" raw_file normalized_file failure_lines_file line status id
  [ -f "$output_file" ] || { echo "ERROR: test output is missing" >&2; return 2; }

  if [ -n "$pattern" ]; then
    if [[ "" =~ $pattern ]]; then
      :
    else
      status=$?
      if [ "$status" -eq 2 ]; then
        echo "ERROR: invalid test_failure_pattern ERE" >&2
        return 2
      fi
    fi
    raw_file="$(mktemp)" || return 2
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ $pattern ]]; then
        if [ "${#BASH_REMATCH[@]}" -ne 2 ]; then
          rm -f "$raw_file"
          echo "ERROR: test_failure_pattern must contain exactly one capture group" >&2
          return 2
        fi
        id="${BASH_REMATCH[1]}"
        id="$(printf '%s' "$id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        if [ -z "$id" ]; then
          rm -f "$raw_file"
          echo "ERROR: test_failure_pattern captured an empty failure identifier" >&2
          return 2
        fi
        printf '%s\n' "$id" >> "$raw_file" || { rm -f "$raw_file"; return 2; }
      else
        status=$?
        if [ "$status" -eq 2 ]; then
          rm -f "$raw_file"
          echo "ERROR: invalid test_failure_pattern ERE" >&2
          return 2
        fi
      fi
    done < "$output_file"
    LC_ALL=C sort -u "$raw_file"
    status=$?
    rm -f "$raw_file"
    return "$status"
  fi

  normalized_file="$(mktemp)" || return 2
  failure_lines_file="$(mktemp)" || { rm -f "$normalized_file"; return 2; }
  sed -E \
    -e 's/0[xX][[:xdigit:]]{6,}/<ADDR>/g' \
    -e 's/([[:space:],;:=()])([[:digit:]]+([.][[:digit:]]+)?[[:space:]]*(seconds?|secs?|s|milliseconds?|msecs?|ms|usecs?|us))([[:space:],;)]|$)/\1<TIME>\5/g' \
    -e 's/[[:space:]]+/ /g' \
    -e 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    "$output_file" > "$normalized_file" || { rm -f "$normalized_file" "$failure_lines_file"; return 2; }
  grep -iE 'FAIL|ERROR' "$normalized_file" > "$failure_lines_file"
  status=$?
  case "$status" in
    0) LC_ALL=C sort -u "$failure_lines_file"; status=$? ;;
    1) status=0 ;; # grep 1 means the output has no failure lines.
    *) status=2 ;;
  esac
  rm -f "$normalized_file" "$failure_lines_file"
  return "$status"
}

review_apply_fixes__ids_json() {
  printf '%s\n' "${1:-}" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# Record the gate mode and its baseline comparison on the molecule root. A
# JSON null means no comparison was made; an array is the immutable base's
# known failure set (including an empty array when it passed).
review_apply_fixes__record_test_gate_state() {
  local gate="$1" failures_json="$2" error="${3:-}"
  : "${REVIEW_ROOT:?call review_apply_fixes_load first}"
  bd update "$REVIEW_ROOT" \
    --set-metadata gc.review.test_gate_mode="$gate" \
    --set-metadata gc.review.preexisting_test_failures="$failures_json" \
    --set-metadata gc.review.test_gate_error="$error" >/dev/null || {
      echo "ERROR: could not record test-gate state on $REVIEW_ROOT" >&2
      return 2
    }
}

# review_apply_fixes__record_test_failure <command> <status> <output> [details] —
# create a durable major/testing finding under the review findings container.
review_apply_fixes__record_test_failure() {
  local command_text="$1" status="$2" output="$3" details="${4:-}" description finding_id
  description="$(printf 'Test command failed with exit status %s.\n\nCommand:\n%s\n\nOutput (last 100 lines):\n%s\n' \
    "$status" "$command_text" "$output")"
  if [ -n "$details" ]; then
    description="$(printf '%s\n\nFailure-set comparison:\n%s\n' "$description" "$details")"
  fi
  finding_id="$(bd create --parent "$REVIEW_FINDINGS" \
    --title "Apply-fixes test command failed (exit $status)" \
    --description "$description" --type bug --priority 1 \
    --labels "severity:major,category:testing" --silent)" || {
      echo "ERROR: could not record failed test command as a finding" >&2
      return 2
    }
  [ -n "$finding_id" ] || {
    echo "ERROR: bd create returned no id for the failed-test finding" >&2
    return 2
  }
  printf '%s\n' "$finding_id"
}

# Record a failed test run, set review.verdict=iterate, and return the existing
# status 10 terminal so the caller makes no commit or push.
review_apply_fixes__test_failure_iterate() {
  local command_text="$1" status="$2" output_file="$3" details="$4" output finding_id
  output="$(tail -n 100 "$output_file")"
  finding_id="$(review_apply_fixes__record_test_failure "$command_text" "$status" "$output" "$details")" || return 2
  review_apply_fixes_set_verdict iterate \
    "test_command failed with exit $status; failure recorded as finding $finding_id; no commit made" || return 2
  echo "ERROR: test_command failed (exit $status); finding=$finding_id; refusing to commit" >&2
  return 10
}

# Fail closed when a comparison dependency is unavailable. Keep it on the
# existing finding/iterate terminal so this cannot fall through to a commit.
review_apply_fixes__comparison_failure_iterate() {
  local command_text="$1" head_status="$2" output_file="$3" reason="$4" details
  review_apply_fixes__record_test_gate_state "${REVIEW_TEST_GATE:-no-new-failures}" null "$reason" || return 2
  details="$(printf '%s. Comparison failed closed; no commit was made.' "$reason")"
  review_apply_fixes__test_failure_iterate "$command_text" "$head_status" "$output_file" "$details"
}

# review_apply_fixes_test_before_commit [command] — run the rig test command in
# the review worktree. `strict` preserves the original any-failure gate;
# `no-new-failures` compares a failing fix-head run with one disposable run at
# the immutable review base. Return 10 only after a failure was recorded and
# review.verdict=iterate closed this apply-fixes bead.
review_apply_fixes_test_before_commit() {
  local command_text="${1:-${REVIEW_TEST_COMMAND:-}}" gate="${REVIEW_TEST_GATE:-no-new-failures}"
  local pattern="${REVIEW_TEST_FAILURE_PATTERN:-}" output_file status head_status parse_status
  local head_failures=""
  local base_ref base_error_file base_error temp_root base_worktree base_output setup_output
  local review_real temp_real
  local cleanup_output base_status cleanup_status base_failures base_json head_file base_file new_file
  local new_failures failure_details

  case "$gate" in
    strict|no-new-failures) : ;;
    *) echo "ERROR: unsupported test_gate '$gate' (want strict|no-new-failures)" >&2; return 2 ;;
  esac
  if [ -z "$command_text" ]; then
    review_apply_fixes__record_test_gate_state "$gate" null "test command skipped; baseline not evaluated" || return 2
    echo "[review-apply-fixes] no test_command configured; skipping test gate"
    return 0
  fi
  [ -n "${REVIEW_WORK_DIR:-}" ] && [ -d "$REVIEW_WORK_DIR" ] || {
    echo "ERROR: test gate has no valid REVIEW_WORK_DIR" >&2
    return 2
  }
  output_file="$(mktemp)" || return 2
  echo "[review-apply-fixes] running test_command in $REVIEW_WORK_DIR"
  (cd "$REVIEW_WORK_DIR" && bash -c "$command_text") > "$output_file" 2>&1
  head_status=$?
  if [ "$head_status" -eq 0 ]; then
    if [ "$gate" = "no-new-failures" ]; then
      review_apply_fixes__record_test_gate_state "$gate" null "fix-head tests passed; baseline was not needed" || { rm -f "$output_file"; return 2; }
    else
      review_apply_fixes__record_test_gate_state "$gate" null "strict mode; baseline not compared" || { rm -f "$output_file"; return 2; }
    fi
    rm -f "$output_file"
    echo "[review-apply-fixes] test_command passed"
    return 0
  fi
  status="$head_status"

  if [ "$gate" = "strict" ]; then
    review_apply_fixes__record_test_gate_state "$gate" null "strict mode; baseline not compared" || { rm -f "$output_file"; return 2; }
    failure_details="strict mode: any non-zero test result blocks the commit; baseline comparison was not performed"
    review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  base_error_file="$(mktemp)" || {
    base_error="cannot allocate a diagnostic file for resolving the immutable base"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  base_ref="$(review_apply_fixes__base_ref 2>"$base_error_file")"
  parse_status=$?
  if [ "$parse_status" -ne 0 ] || [ -z "$base_ref" ]; then
    base_error="cannot resolve immutable review base: $(tail -n 5 "$base_error_file" | tr '\n' ' ' | cut -c 1-1000)"
    rm -f "$base_error_file"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$(printf '%s\nFix-head failure identifiers: %s' \
      "$base_error. Treating all fix-head failures as new; no commit was made." "${head_failures:-unparsed}")"
    review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi
  rm -f "$base_error_file"

  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/review-apply-fixes-base.XXXXXX")" || {
    base_error="cannot create a disposable directory for the immutable-base worktree"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  review_real="$(cd "$REVIEW_WORK_DIR" && pwd -P)" || {
    base_error="cannot resolve the review worktree path; baseline comparison failed closed"
    rm -rf "$temp_root"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  temp_real="$(cd "$temp_root" && pwd -P)" || {
    base_error="cannot resolve the disposable worktree path; baseline comparison failed closed"
    rm -rf "$temp_root"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  if [[ "$temp_real" == "$review_real" || "$temp_real" == "$review_real/"* ]]; then
    base_error="system temporary directory resolves inside the review worktree; refusing to create the baseline worktree there"
    rm -rf "$temp_root"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  fi
  base_worktree="$temp_root/worktree"
  base_output="$temp_root/output"
  setup_output="$temp_root/setup-output"
  cleanup_output="$temp_root/cleanup-output"
  if ! git -C "$REVIEW_WORK_DIR" worktree add --quiet --detach "$base_worktree" "$base_ref" > "$setup_output" 2>&1; then
    base_error="cannot create disposable worktree at $base_ref: $(tail -n 5 "$setup_output" | tr '\n' ' ' | cut -c 1-1000)"
    rm -rf "$base_worktree" "$temp_root"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$(printf '%s\nFix-head failure identifiers: %s' \
      "$base_error. Treating all fix-head failures as new; no commit was made." "${head_failures:-unparsed}")"
    review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  echo "[review-apply-fixes] comparing test failures against immutable base $base_ref"
  (cd "$base_worktree" && bash -c "$command_text") > "$base_output" 2>&1
  base_status=$?
  if ! git -C "$REVIEW_WORK_DIR" worktree remove --force "$base_worktree" > "$cleanup_output" 2>&1; then
    rm -rf "$base_worktree"
    git -C "$REVIEW_WORK_DIR" worktree prune >/dev/null 2>&1 || true
    cleanup_status=1
  else
    cleanup_status=0
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    base_error="could not clean up disposable baseline worktree; comparison failed closed"
    rm -rf "$temp_root"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$(printf '%s\nFix-head failure identifiers: %s' \
      "$base_error. Treating all fix-head failures as new; no commit was made." "${head_failures:-unparsed}")"
    review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  if [ "$base_status" -eq 126 ] || [ "$base_status" -eq 127 ] || [ "$base_status" -ge 128 ]; then
    base_error="baseline test command could not be run or completed normally (exit $base_status); comparison failed closed"
    rm -rf "$temp_root"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$(printf '%s\nFix-head failure identifiers: %s' \
      "$base_error. Treating all fix-head failures as new; no commit was made." "${head_failures:-unparsed}")"
    review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  if [ "$head_status" -eq 126 ] || [ "$head_status" -eq 127 ] || [ "$head_status" -ge 128 ]; then
    base_error="fix-head test command could not be run or completed normally (exit $head_status); comparison failed closed"
    rm -rf "$temp_root"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$base_error. The same command was attempted at the immutable base; no commit was made."
    review_apply_fixes__test_failure_iterate "$command_text" "$head_status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  head_failures="$(review_apply_fixes__failure_set "$output_file" "$pattern")"
  parse_status=$?
  if [ "$parse_status" -ne 0 ] || [ -z "$head_failures" ]; then
    if [ "$parse_status" -ne 0 ]; then
      base_error="could not parse fix-head failure identifiers; ${pattern:+test_failure_pattern is invalid or does not yield one capture group}${pattern:-default failure lines were unavailable}"
    else
      base_error="fix-head output contained no recognizable failure identifiers; comparison failed closed"
    fi
    rm -rf "$temp_root"
    review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
    failure_details="$base_error. The same command was run at the immutable base; no commit was made."
    review_apply_fixes__test_failure_iterate "$command_text" "$head_status" "$output_file" "$failure_details"
    status=$?
    rm -f "$output_file"
    return "$status"
  fi

  base_failures=""
  if [ "$base_status" -ne 0 ]; then
    base_failures="$(review_apply_fixes__failure_set "$base_output" "$pattern")"
    parse_status=$?
    if [ "$parse_status" -ne 0 ] || [ -z "$base_failures" ]; then
      if [ "$parse_status" -ne 0 ]; then
        base_error="could not parse immutable-base failure identifiers"
      else
        base_error="immutable-base run failed without recognizable failure identifiers"
      fi
      rm -rf "$temp_root"
      review_apply_fixes__record_test_gate_state "$gate" null "$base_error" || { rm -f "$output_file"; return 2; }
      failure_details="$(printf '%s\nFix-head failure identifiers: %s' \
        "$base_error; comparison failed closed. Treating all fix-head failures as new; no commit was made." "$head_failures")"
      review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
      status=$?
      rm -f "$output_file"
      return "$status"
    fi
  fi
  rm -rf "$temp_root"

  head_file="$(mktemp)" || {
    base_error="cannot allocate scratch storage for the failure-set comparison"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  base_file="$(mktemp)" || {
    base_error="cannot allocate scratch storage for the failure-set comparison"
    rm -f "$head_file"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  new_file="$(mktemp)" || {
    base_error="cannot allocate scratch storage for the failure-set comparison"
    rm -f "$head_file" "$base_file"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  if ! printf '%s\n' "$head_failures" | sed '/^$/d' > "$head_file" ||
     ! printf '%s\n' "$base_failures" | sed '/^$/d' > "$base_file" ||
     ! LC_ALL=C comm -23 "$head_file" "$base_file" > "$new_file"; then
    base_error="could not compare normalized fix-head and immutable-base failure sets"
    rm -f "$head_file" "$base_file" "$new_file"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  fi
  new_failures="$(cat "$new_file")" || {
    base_error="could not read the normalized failure-set comparison result"
    rm -f "$head_file" "$base_file" "$new_file"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  rm -f "$head_file" "$base_file" "$new_file"

  base_json="$(review_apply_fixes__ids_json "$base_failures")" || {
    base_error="could not serialize immutable-base failure identifiers"
    review_apply_fixes__comparison_failure_iterate "$command_text" "$head_status" "$output_file" "$base_error"
    status=$?; rm -f "$output_file"; return "$status"
  }
  review_apply_fixes__record_test_gate_state "$gate" "$base_json" "" || { rm -f "$output_file"; return 2; }
  if [ -z "$new_failures" ]; then
    rm -f "$output_file"
    echo "[review-apply-fixes] fix-head failures are a subset of the immutable-base failures; commit allowed"
    return 0
  fi

  failure_details="$(printf 'new failure identifiers: %s\nimmutable-base failure identifiers (recorded as pre-existing): %s\nfix-head failure identifiers: %s' \
    "$new_failures" "${base_failures:-none}" "$head_failures")"
  review_apply_fixes__test_failure_iterate "$command_text" "$status" "$output_file" "$failure_details"
  status=$?
  rm -f "$output_file"
  return "$status"
}

# review_apply_fixes_push_branch — push the current review branch to origin and
# report a clear error if no branch or a remote push failure prevents it.
review_apply_fixes_push_branch() {
  local branch
  : "${REVIEW_WORK_DIR:?call review_apply_fixes_load first}"
  branch="$(git -C "$REVIEW_WORK_DIR" symbolic-ref --quiet --short HEAD)" || {
    echo "ERROR: cannot push a detached review worktree" >&2
    return 2
  }
  if ! git -C "$REVIEW_WORK_DIR" push origin "HEAD:refs/heads/$branch"; then
    echo "ERROR: failed to push review branch $branch to origin" >&2
    return 1
  fi
  echo "[review-apply-fixes] pushed $branch to origin"
}

# review_apply_fixes_commit_and_push <message> — the only supported commit path:
# scope check, test gate, commit, then push. A test failure returns 10 after it
# has written iterate and closed the bead; no git add/commit/push has run.
review_apply_fixes_commit_and_push() {
  local message="${1:-}" status
  [ -n "$message" ] || { echo "ERROR: commit message is required" >&2; return 2; }
  review_apply_fixes_check_allowed_paths || return $?
  review_apply_fixes_test_before_commit "${REVIEW_TEST_COMMAND:-}"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  # Tests can generate or mutate files; re-check after they pass so such
  # side-effects cannot enter the commit through git add -A.
  review_apply_fixes_check_allowed_paths || return $?
  (
    cd "$REVIEW_WORK_DIR" || exit 2
    git add -A || exit $?
    git diff --cached --quiet
    status=$?
    if [ "$status" -eq 0 ]; then
      echo "[review-apply-fixes] no new changes to commit; retrying branch push"
      exit 0
    elif [ "$status" -ne 1 ]; then
      exit "$status"
    fi
    git commit -m "$message"
  ) || {
    status=$?
    echo "ERROR: apply-fixes commit failed (status $status)" >&2
    return "$status"
  }
  review_apply_fixes_push_branch || return $?
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
  local verdict="$1" note="${2:-}" gate_mode preexisting_failures gate_error
  : "${REVIEW_PHASE_SUFFIX:?call review_apply_fixes_load first}"
  : "${REVIEW_ROOT:?call review_apply_fixes_load first}"
  case "$verdict" in
    done|iterate) : ;;
    *) echo "ERROR: review_apply_fixes_set_verdict: invalid verdict '$verdict' (want done|iterate)" >&2; return 2 ;;
  esac
  gate_mode="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.test_gate_mode')"
  preexisting_failures="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.preexisting_test_failures')"
  gate_error="$(review_apply_fixes__meta "$REVIEW_ROOT" 'gc.review.test_gate_error')"
  if [ -n "$gate_mode" ]; then
    note="$(printf '%s\nTest gate: mode=%s; pre-existing failures=%s%s' \
      "$note" "$gate_mode" "${preexisting_failures:-null}" \
      "${gate_error:+; comparison note=$gate_error}")"
  fi
  . "${GC_CITY:?GC_CITY must be set by the runtime}/formulas/lib/resolve-phase-bead.sh" || return 2
  review_phase_resolve "$REVIEW_PHASE_SUFFIX" "$REVIEW_ROOT" "${REVIEW_PHASE_STEP_ID:-}" || return 2
  bd update "$GC_BEAD_ID" --set-metadata review.verdict="$verdict" >/dev/null || return 2
  gc bd heartbeat "$GC_BEAD_ID" >/dev/null 2>&1 || true
  bd update "$GC_BEAD_ID" --set-metadata gc.outcome=pass --status=closed \
    --notes "apply-fixes: review.verdict=$verdict. $note" || return 2
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
  : "${REVIEW_PHASE_SUFFIX:?call review_apply_fixes_load first}"
  : "${REVIEW_ROOT:?call review_apply_fixes_load first}"
  . "${GC_CITY:?GC_CITY must be set by the runtime}/formulas/lib/resolve-phase-bead.sh" || return 2
  review_phase_resolve "$REVIEW_PHASE_SUFFIX" "$REVIEW_ROOT" "${REVIEW_PHASE_STEP_ID:-}" || return 2
  bd update "$REVIEW_ROOT" --set-metadata gc.review.loop_outcome="blocked-needs-human" >/dev/null || return 2
  bd update "$REVIEW_ROOT" --set-metadata gc.review.loop_blocked_reason="$reason"       >/dev/null || return 2
  echo "[review-apply-fixes] TERMINATE-TO-HUMAN: $reason" >&2
  review_apply_fixes_set_verdict done "TERMINATE-TO-HUMAN: $reason (gc.review.loop_outcome=blocked-needs-human on $REVIEW_ROOT)"
}
