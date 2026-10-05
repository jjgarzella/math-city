# Production Julia MCP (Kaimon)

Gas City owns the `kaimon` service and projects the neutral HTTP MCP catalog
into Claude and Codex provider configs. The service binds only to
`127.0.0.1:42828`; the MCP endpoint is `http://127.0.0.1:42828/mcp`.
It uses strict bearer authentication and permits localhost IPs only.
Workflow/formula migration is separate work (`mc-1xkm.2` and `.3`).

## Configuration and environment

- Non-secret service declaration: `[[service]]` in `city.toml`, named `kaimon`,
  kind `proxy_process`, command `commands/kaimon-canary-service`.
- Private neutral catalog: `mcp/kaimon.toml`, mode 0600, ignored by Git.
  Its Authorization header contains the production bearer. Never print it.
- Persistent runtime: `.gc/kaimon-canary/`. Historical canary path names remain
  intentional so the repaired environment and socket identities stay stable.
- Runtime security config: `.gc/kaimon-canary/xdg-config/kaimon/config.json`,
  mode 0600 inside a 0700 `kaimon` directory. Production rotation replaced the
  temporary canary key; the old key is rejected.
- Managed project allow-list: the same directory's `projects.json`, mode 0600.
  Only `/home/jjgarzella/Developer/ai/city/math-code-projects/DeRham.jl` is
  initially enabled. Do not enable arbitrary projects during verification.
- Julia 1.13.0: `/home/jjgarzella/.juliaup/bin/julia`; isolated environment
  `.gc/kaimon-canary/project/`, isolated depot `.gc/kaimon-canary/julia_depot/`.
  The runtime Manifest records Kaimon 2.9.0 and KaimonGate 1.4.0.
  Preserve this repaired depot rather than re-resolving packages during rollout.
- Socket-safe XDG cache: `/tmp/math-city-kaimon`. Override only with a similarly
  short `KAIMON_CANARY_CACHE_HOME`; long ZMQ Unix socket paths fail.
- The managed-session launcher `commands/kaimon-canary-julia-session` injects
  the installed KaimonGate and server project into Julia's LOAD_PATH and leaves
  the selected mathematical project's activation intact.
- Service state: `.gc/services/kaimon-canary`, retained during the rename.
  The launcher bridges the supervisor's `GC_SERVICE_SOCKET` Unix socket to
  localhost TCP; `/svc/kaimon` is a private service mount. If either child or
  bridge exits, the launcher exits so Gas City can recover it.

## Lifecycle

Inspect with `gc service doctor kaimon` or `gc service list --json`.
Confirm the listener with `ss -ltnp '( sport = :42828 )'`.
A service's `ready` status alone is insufficient: verify native MCP `ping` too.

Start/reconcile the configured service with `gc reload --soft`. This accepts
config drift without forcing active crew conversations to restart. The running
supervisor owns the process; no attached terminal or user systemd is required.

Restart only Kaimon with `gc service restart kaimon --json`. Before any restart
or service removal, use native `ping` to inventory connected Julia sessions.
Kaimon 2.9.0 closes managed PTYs and sends SIGHUP on shutdown, losing in-memory
Julia state. Retire only your disposable verification sessions; preserve real
user state or obtain its explicit disposition before proceeding.

To stop, remove only the Kaimon service stanza and run `gc reload --soft`, after
resolving live session state. Save the stanza privately first. To start again,
restore it and soft-reload. Do not restart the city, supervisor, Dolt, or crew.

## Provider projection and health checks

`gc mcp list --session <session-id>` reports the effective catalog and native
config target without disclosing header values. New targets must show only
production `kaimon` for this Julia service. Named Claude account `anatoly` uses
`CLAUDE_CONFIG_DIR=/home/jjgarzella/.llm-sandbox/auth/claude/kedlaya_lab`;
its account config must be inventoried separately from `~/.claude.json`.

Use Gas City's projection command when a native target is missing or stale:

```sh
gc internal project-mcp --agent claude --identity claude --workdir "$GC_CITY"
gc internal project-mcp --agent codex --identity codex --workdir "$GC_CITY"
# For a concrete worker, use its configured template, identity and workdir:
gc internal project-mcp --agent <qualified-template> \
  --identity <session-name> --workdir <absolute-workdir>
```

This reconciles provider-native config from the neutral catalog and preserves
unrelated settings. Generated `.mcp.json` and `.codex/config.toml` contain
credentials: keep them private and ignored. A catalog listing does not prove
that the provider loaded it. The initial production gates found missing
worktree targets and stale ancestor canary configs; retain those failure records.
Refresh projection before starting a fresh verification conversation. Existing
conversations may retain the old MCP connection until they drain naturally.

In each actual fresh provider, discover native `kaimon` tools, then:

1. Call `ping(extended=true)` and record daemon PID.
2. Call `start_session` for the explicitly allowed DeRham project, with an
   ownership-specific test name. Target that returned key in every subsequent
   call; other agents share this service.
3. Evaluate `6*7` with `ex(e="6*7", ses=<key>, q=false)`; require 42.
4. Load `DeRham`; collect background work with `check_eval` if necessary.
   Verify Julia version, active project, package source and isolated depot.
5. Perform the exact CPU quadratic test: in QQ[x,y,z], convert
   `x^2+2*x*y+3*x*z+4*y^2+5*y*z+6*z^2` to `[6,5,4,3,2,1]` and reconstruct it
   exactly with `polynomial_to_vector` / `vector_to_polynomial`.
6. Shut down only the owned test key using `manage_repl`; preserve other gates.

After an authorized Kaimon-only restart, repeat actual native checks in fresh
providers. Supplemental HTTP initialization must match the response id (SSE
may contain notifications first), support protocol `2025-11-25`, and distinguish
401 authentication failures from JSON-RPC errors. Raw protocol clients do not
prove actual Claude/Codex connectivity. Never paste bearer tokens into commands,
logs or reports. Record old-token rejection after rotation.

## Rollback

The former default Claude user-scoped Julia server command is exactly:

```sh
uv run --directory /opt/julia-mcp python server.py
```

Restore only that MCP entry if needed, preserving other user settings:

```sh
claude mcp add --scope user julia -- uv run --directory /opt/julia-mcp python server.py
```

Run this against the default Claude config scope. Anatoly's separate account had
no legacy Julia entry. Private 0600 backups of the original user configs, canary
catalog, runtime auth and allow-list reside under
`.gc/maintenance/kaimon-production-20261005/private-rollback/` (directory 0700).
Do not copy whole user configs over newer concurrent account/settings changes.

If production service authentication fails, preserve live Julia state first,
restore the prior auth and canary catalog together from private backups, replace
only the service name with `kaimon-canary`, and use `gc reload --soft` plus
neutral projection into affected targets. Keep one localhost listener. Treat
restoring the old bearer as a deliberate rollback, never as a second production
credential. Preserve unrelated city config and worktrees.

## Evidence and limits

Sanitized production evidence is in
`.gc/maintenance/kaimon-production-20261005/`; final provider reports and
`acceptance-report.txt` distinguish initial failures from accepted reruns.
Pre-cutover recovery evidence is in
`.gc/maintenance/kaimon-precutover-20261005/stage-3/recovery/`.

Acceptance covers managed package loading and selected exact CPU polynomial
math. It does not validate all DeRham features, optional Graphviz extensions,
GPU behavior or fresh package resolution. The inherited Oscar Manifest/compat
mismatch and unreaped exited managed children remain operational caveats.
Real-polecat adoption requires actual recent task transcript evidence; diagnostic
acceptance workers establish connectivity only.

One production Claude-managed gate exited with SIGSEGV during `using DeRham`.
An identical fresh Claude retry and the independent fresh Codex gate passed.
The daemon stayed healthy. This is not diagnosed or fixed by promotion; track
`mc-1xkm.9` and preserve the failed/retry evidence. Dormant reusable pool native
configs were also refreshed through neutral projection, with private backups,
so stale workdir canary entries cannot shadow the production root config.
