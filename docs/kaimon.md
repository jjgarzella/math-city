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
  mode 0600 inside a 0700 `kaimon` directory. The exposed production bearer was
  replaced during the general-access rollout; only the new bearer is accepted.
- Project registry: the same directory's `projects.json`, mode 0600.
  Top-level `allow_any_project=true` permits arbitrary exact project/worktree
  paths without per-project approval. Existing registry recipes and other keys
  remain intact. Installed Kaimon reads this flag on each request; changing it
  requires no restart. This general-use authorization supersedes the initial
  original-DeRham-only rollout restriction.
- Julia 1.13.0: the installed `julia-1.13.0+0.aarch64.linux.gnu/bin/julia`
  under `/home/jjgarzella/.julia/juliaup/`, launched directly to avoid shim
  auto-installation/depot ambiguity; isolated environment
  `.gc/kaimon-canary/project/`, primary runtime depot `.gc/kaimon-canary/julia_depot/`.
  The runtime Manifest records Kaimon 2.9.0 and KaimonGate 1.4.0.
  Preserve this repaired depot rather than re-resolving packages during rollout.
  The launcher appends `/home/jjgarzella/.julia` as a fallback depot, preserving
  the runtime depot first. `KAIMON_USER_DEPOT` can override the fallback path.
  It sets `JULIAUP_DEPOT_PATH` explicitly to the fallback depot's `juliaup`
  directory so private HOME does not hide installed versions, and disables
  automatic package precompilation. These values are inherited by managed gates.
- Socket-safe XDG cache: `/tmp/math-city-kaimon`. Override only with a similarly
  short `KAIMON_CANARY_CACHE_HOME`; long ZMQ Unix socket paths fail.
- Kaimon's built-in managed launcher uses `--project=<exact-path>` and appends
  the installed KaimonGate environment to `JULIA_LOAD_PATH`. The distributed
  KaimonGate directory lacks a Manifest; service startup supplies the repaired
  server Manifest there so ZMQ resolves without a package update/resolve.
  This modifies only the private installed runtime cache, not upstream source
  or mathematical projects. Recheck this repair after upgrading KaimonGate.
  The original DeRham registry recipe still uses
  `commands/kaimon-canary-julia-session`; its default also launches the installed
  Julia 1.13.0 binary directly. It is not imposed on other projects.
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
credentials: keep them private and ignored. The Gas City rig and its existing
`peter` worktree track an Excalidraw `.mcp.json`; ignore patterns cannot untrack
those files. Their private projected copies are 0600 and have local
`skip-worktree` flags, preserving credential-free index contents. This is a local
staging protection, not Git untracking. Upstream tracked-target projection needs
follow-up `mc-1xkm.12`; do not clear those flags while credentials remain in the
tracked worktree files. New tracked native targets need the same explicit audit. A catalog listing does not prove
that the provider loaded it. The initial production gates found missing
worktree targets and stale ancestor canary configs; retain those failure records.
Refresh projection before starting a fresh verification conversation. Existing
conversations may retain the old MCP connection until they drain naturally.

## Native Julia use

Discover native `kaimon` tools and their installed schemas, then call
`ping(extended=true)`. Launch an existing package environment with
`start_session(project_path="/absolute/exact/worktree", name="<task-owner>")`.
The directory must exist and contain `Project.toml`. Kaimon automatically calls
`Pkg.instantiate` during startup; this can download missing dependencies and
write an absent/stale Manifest. Keep prescribed clean-depot/cold-start gates
separate, and avoid launching an unrelated repository just for scratch work.

Every eval must target the returned key:

```text
ex(e="owned_state = 41", ses="<key>")
ex(e="(owned_state + 1, VERSION, Base.active_project(), getpid())",
   ses="<key>", q=false)
```

The second call reads the first call's state in the same warm Julia process.
`q=true` is the default and suppresses the value; use `q=false` for results.
If evaluation returns a background ID, collect it using
`check_eval(eval_id="<id>")`; continue useful work rather than sleeping.
For changed package code, load the package and verify `pathof(Package)` points
into the required exact worktree. File edits do not automatically replace every
loaded definition. Revise can track supported edits when loaded; module/layout
changes can require a new owned process. Never use a different checkout as
validation for modified code.

### Ownership and scratch projects

Kaimon deduplicates live gates by normalized project path, even if a caller asks
for a different name. A returned existing key is not evidence of ownership.
Inspect the inventory and reuse only your task's exact project/version session.
For independent work, use an owned separate worktree or unique scratch path.
Do not activate another project, redefine state, or shut down another actor's
gate. Retire only disposable owned keys with
`manage_repl(command="shutdown", session="<key>")`.

For Julia calculations with no package project:

```sh
mkdir -p "$GC_CITY/.gc/kaimon-scratch"
scratch=$(mktemp -d "$GC_CITY/.gc/kaimon-scratch/${GC_SESSION_ID:-task}-XXXXXX")
touch "$scratch/Project.toml"
printf '%s\n' "$scratch"
```

Call `start_session(project_path=<printed-directory>, name=<task-owner>)`.
Kaimon does not create this environment automatically. Keep it outside repository
source; do not add `Project.toml` to an unrelated repo. Retain the directory while
the owned gate is in use, close the gate when done, and remove only your scratch
files when they are no longer needed.

### Installed Julia version selection

Without a recipe, gates use the daemon's Julia 1.13.0. Julia 1.12.7 is also
installed. Before launching, merge the following into the owned project's
`kaimon.toml`, preserving existing settings:

```toml
[launch]
julia_version = "1.12"
```

A series selects an installed patch; an exact patch string requires that patch.
Kaimon reads juliaup's registry through the explicit `JULIAUP_DEPOT_PATH`.
Per-path `projects.json` launch settings override project `kaimon.toml` fields;
`julia_bin` has higher priority than `julia_version` and can name a wrapper.
Do not apply the original DeRham wrapper/version to every project. Check
`VERSION` and `Base.active_project()` after every new launch. Kaimon can offer
an installation or substitute the daemon Julia if a requested version is absent;
report a mismatch rather than treating it as satisfying a version-specific gate.
Routine use of installed versions and arbitrary project paths needs no new human
approval or registry edit. Formula/runner migrations remain separate work.

Kaimon 2.9.0 has a 120-second startup timeout. Cold compilation, including Julia
1.12's Pkg stdlib, can exceed it. A timeout marks the managed entry crashed but
does not necessarily stop its process: inspect native `ping` and the returned
log before retrying, because the owned gate may connect later. Repeated starts
while the first process is still booting can create duplicate late arrivals;
path deduplication applies to already-connected gates. Once it connects,
`start_session` on that path returns its live key. Verify ownership and close
all of your disposable gates, preserving other actors' state. This does not
change the prescribed cold-start/clean-depot gate semantics.


### Prescribed production math gate

The original production CPU acceptance gate remains available; general warm use
has not replaced formula/test gates. In a disposable owned DeRham worktree gate,
verify Julia version, active project and `pathof(DeRham)`, then in QQ[x,y,z]
convert `x^2+2*x*y+3*x*z+4*y^2+5*y*z+6*z^2` to `[6,5,4,3,2,1]` and reconstruct
it exactly with `polynomial_to_vector` / `vector_to_polynomial`. Retire only the
owned key. Preserve intentionally isolated cold-start and clean-depot tests.

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

For authentication repair, preserve live Julia state first. Generate a fresh
bearer privately and replace the runtime `api_keys` with only that credential;
update the neutral catalog's Authorization header consistently. Kaimon captures
security config at server startup, so credentials require a service-only restart
in a quiescent window. Immediately before restarting, inventory native `ping`;
if other actors have live gates, coordinate disposition through durable mail.
Do not silently destroy their Julia memory. Use `gc internal project-mcp` to
reconcile affected native targets and confirm old-key HTTP 401/new-key success
without printing credentials. Keep files 0600 and private directories 0700.
Private rotation backups are in
`.gc/maintenance/kaimon-general-access-20261006/private-rollback/`; they contain
an exposed revoked credential and must not be restored as an accepted key.
Preserve unrelated settings and allow existing conversations to refresh
naturally; projected files cannot replace credentials already loaded in memory.

## Evidence and limits

General-access rollout evidence is in
`.gc/maintenance/kaimon-general-access-20261006/`, including the fresh native
Claude/Codex reports, credential rejection check, projection/preservation checks,
strict prompt renders and focused doctor results. Fresh Claude verified default
Julia 1.13.0; fresh Codex verified project-selected Julia 1.12.7. Both exercised
unlisted exact worktrees, loaded the disposable package from the correct source,
retained state across calls, confirmed path deduplication and used independent
scratch projects. All proof evaluations used actual provider-native tools.
The first cold Julia 1.12 launch timed out while Pkg compiled, then connected;
the documented startup/late-arrival caveat remains. The optional detached DeRham
launch failed before gate attachment during Pkg/Downloads/LibCURL precompilation
(`Zstd_jll` precompiled image unavailable with the requested cache flags).
The copied Manifest was unchanged; package loading in that worktree is unverified.
No package update/resolve or external source repair was attempted. Existing
conversations can retain revoked credentials until natural refresh.

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
