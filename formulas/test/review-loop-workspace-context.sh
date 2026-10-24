# Shared behavior checks for the base and standard review-loop workspace setup.

section "workspace context behavior"

CTX_TEST_ROOT="$TMPDIR/review-loop-context-$$"
mkdir -p "$CTX_TEST_ROOT/bin" "$CTX_TEST_ROOT/city/formulas/lib"
cat > "$CTX_TEST_ROOT/city/formulas/lib/review-verdict.sh" <<'CHECK'
#!/usr/bin/env bash
exit 0
CHECK
chmod +x "$CTX_TEST_ROOT/city/formulas/lib/review-verdict.sh"

cat > "$CTX_TEST_ROOT/bin/bd" <<'BD'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  show)
    target="${2:-}"
    if [ "$target" = "${GC_BEAD_ID:-}" ]; then
      jq -nc --arg id "$target" --arg root "${BD_ROOT_ID:-context-root}" \
        '[{id:$id,metadata:{"gc.root_bead_id":$root}}]'
    elif [ "$target" = "${BD_ROOT_ID:-context-root}" ]; then
      jq -nc --arg id "$target" --arg wd "${BD_ROOT_WORK_DIR:-}" \
        --arg branch "${BD_ROOT_BRANCH:-}" --arg sha "${BD_ROOT_BASE_SHA:-}" \
        '[{id:$id,metadata:{work_dir:$wd,"gc.work_dir":$wd,branch:$branch,base_sha:$sha}}]'
    else
      printf '[]\n'
    fi
    ;;
  update)
    printf '%s\n' "$*" >> "$BD_LOG"
    ;;
  *)
    echo "unexpected bd command: $*" >&2
    exit 2
    ;;
esac
BD
cat > "$CTX_TEST_ROOT/bin/gc" <<'GC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GC_LOG"
GC
chmod +x "$CTX_TEST_ROOT/bin/bd" "$CTX_TEST_ROOT/bin/gc"

CTX_BLOCK="$(formula_py block workspace-setup '.gc-review-verdict.sh')"
render_context_block() {
  printf '%s' "$CTX_BLOCK" | CTX_WORK_VALUE="$1" CTX_BRANCH_VALUE="$2" CTX_SHA_VALUE="$3" CTX_NOTIFY_VALUE="" \
      python3 -c 'import os,sys; s=sys.stdin.read();
for key, env in (("work_dir","CTX_WORK_VALUE"),("branch","CTX_BRANCH_VALUE"),("base_sha","CTX_SHA_VALUE"),("notify_target","CTX_NOTIFY_VALUE")):
    s=s.replace("{{"+key+"}}", os.environ.get(env,""))
sys.stdout.write(s)'
}

run_context_case() {
  local name="$1" explicit_dir="$2" metadata_dir="$3" metadata_branch="$4" metadata_sha="$5" explicit_branch="$6" explicit_sha="$7"
  local case_dir="$CTX_TEST_ROOT/$name" work_dir="$CTX_TEST_ROOT/$name/context" root_dir="$CTX_TEST_ROOT/$name/root" pwd_dir="$CTX_TEST_ROOT/$name/pwd"
  local block out rc
  mkdir -p "$case_dir" "$pwd_dir"
  [ -n "$metadata_dir" ] && mkdir -p "$metadata_dir"
  [ -n "$explicit_dir" ] && mkdir -p "$explicit_dir"
  : > "$case_dir/bd.log"
  : > "$case_dir/gc.log"
  block="$(render_context_block "$explicit_dir" "$explicit_branch" "$explicit_sha")"
  out="$case_dir/output"
  if (
    cd "$pwd_dir" && \
    env PATH="$CTX_TEST_ROOT/bin:$PATH" \
      GC_CITY="$CTX_TEST_ROOT/city" GC_BEAD_ID=context-step GC_AGENT=context-test \
      BD_ROOT_ID=context-root BD_ROOT_WORK_DIR="$metadata_dir" \
      BD_ROOT_BRANCH="$metadata_branch" BD_ROOT_BASE_SHA="$metadata_sha" \
      BD_LOG="$case_dir/bd.log" GC_LOG="$case_dir/gc.log" \
      bash -c "$block"
  ) > "$out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  CTX_RC="$rc"
  CTX_OUT="$(cat "$out")"
  CTX_BD_LOG="$(cat "$case_dir/bd.log")"
  CTX_GC_LOG="$(cat "$case_dir/gc.log")"
  CTX_PWD_DIR="$pwd_dir"
  CTX_ROOT_DIR="$metadata_dir"
  CTX_EXPLICIT_DIR="$explicit_dir"
}

# A supplied var wins over different work_dir/branch/base_sha root metadata and
# over the worker PWD.
CONTEXT_DIR="$CTX_TEST_ROOT/explicit-context"
ROOT_CONTEXT_DIR="$CTX_TEST_ROOT/root-context"
run_context_case explicit "$CONTEXT_DIR" "$ROOT_CONTEXT_DIR" root-branch root-base-sha explicit-branch explicit-base-sha
assert_eq "0" "$CTX_RC" "workspace setup succeeds with explicit context"
if [ -f "$CONTEXT_DIR/.gc-review-verdict.sh" ]; then ok "explicit work_dir receives the verdict check"; else fail "explicit work_dir receives the verdict check"; fi
if [ ! -e "$ROOT_CONTEXT_DIR/.gc-review-verdict.sh" ] && [ ! -e "$CTX_PWD_DIR/.gc-review-verdict.sh" ]; then
  ok "root metadata and PWD do not override explicit work_dir"
else
  fail "root metadata and PWD do not override explicit work_dir"
fi
assert_contains "$CTX_BD_LOG" "set-metadata branch=explicit-branch" "explicit branch is recorded on the root"
assert_contains "$CTX_BD_LOG" "set-metadata base_sha=explicit-base-sha" "explicit base_sha is recorded on the root"

# With no vars, known root metadata remains a supported direct-sling fallback.
FALLBACK_DIR="$CTX_TEST_ROOT/metadata-context"
run_context_case metadata "" "$FALLBACK_DIR" metadata-branch metadata-base-sha "" ""
assert_eq "0" "$CTX_RC" "workspace setup accepts root metadata when vars are empty"
if [ -f "$FALLBACK_DIR/.gc-review-verdict.sh" ] && [ ! -e "$CTX_PWD_DIR/.gc-review-verdict.sh" ]; then
  ok "root work_dir is used without falling back to PWD"
else
  fail "root work_dir is used without falling back to PWD"
fi
assert_contains "$CTX_BD_LOG" "set-metadata branch=metadata-branch" "root branch remains the fallback"
assert_contains "$CTX_BD_LOG" "set-metadata base_sha=metadata-base-sha" "root base_sha remains the fallback"

# Missing both explicit and metadata paths must fail even though PWD exists.
run_context_case missing "" "" "" "" "" ""
if [ "$CTX_RC" -ne 0 ]; then ok "workspace setup fails when work_dir is unknown"; else fail "workspace setup fails when work_dir is unknown"; fi
assert_contains "$CTX_OUT" "STOP: no valid work_dir" "missing work_dir failure explains the stop"
if [ ! -e "$CTX_PWD_DIR/.gc-review-verdict.sh" ]; then ok "unknown work_dir never installs into PWD"; else fail "unknown work_dir never installs into PWD"; fi

rm -rf "$CTX_TEST_ROOT"
