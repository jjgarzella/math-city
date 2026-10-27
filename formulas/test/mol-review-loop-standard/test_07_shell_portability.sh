# Source the shared command implementation in each caller shell. The same scope,
# baseline, commit and remote behavior must hold without a caller shell switch.
section "07 Bash and Zsh callers"
if [ "${AFX_SHELL:-bash}" = bash ]; then
  command -v zsh >/dev/null || { fail "zsh available for portability proof"; return; }
  shell_log="$(mktemp)"
  AFX_SHELL=zsh bash "$SUITE_DIR/run.sh" 02 04_commit 05 06 09 > "$shell_log" 2>&1
  shell_rc=$?
  assert_eq "0" "$shell_rc" "scope, test, commit, push and blocked outcomes work from Zsh"
  if [ "$shell_rc" -ne 0 ]; then cat "$shell_log"; fi
fi
