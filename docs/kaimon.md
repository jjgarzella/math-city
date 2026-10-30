# Production Julia MCP (Kaimon)

Gas City owns the `kaimon` service and projects the neutral HTTP MCP catalog
into Claude and Codex provider configs. The service binds only to
`127.0.0.1:42828`; the MCP endpoint is `http://127.0.0.1:42828/mcp`.
It uses strict bearer authentication and permits localhost IPs only.
Workflow/formula migration is separate work (`mc-1xkm.2` and `.3`).

The memory-constrained execution policy was retired on 2026-10-21; see
[execution policy](execution-policy.md). Native Julia use needs no memory grant,
global numerical lock, headroom/RSS guard, or machine-wide thread restriction.
Historical measurements and workaround recipes below remain evidence of those
specific runs, rather than launch requirements for new work.

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
- Julia 1.13.2 on the current macOS Apple Silicon host: the installed
  `julia-1.13.2+0.aarch64.apple.darwin14/Julia-1.13.app/Contents/Resources/julia/bin/julia`
  under `/Users/jj-agents/.julia/juliaup/`, launched directly to avoid shim
  auto-installation/depot ambiguity; isolated environment
  `.gc/kaimon-canary/project/`, primary runtime depot `.gc/kaimon-canary/julia_depot/`.
  The runtime Manifest records Kaimon 2.9.0 and KaimonGate 1.4.0.
  Preserve this repaired depot rather than re-resolving packages during rollout.
  The launcher appends `/Users/jj-agents/.julia` as a fallback depot, preserving
  the runtime depot first, followed by a trailing empty depot entry so Julia
  retains its bundled stdlib sources and compiled images. `KAIMON_USER_DEPOT`
  can override the fallback path.
  It sets `JULIAUP_DEPOT_PATH` explicitly to the fallback depot's `juliaup`
  directory so private HOME does not hide installed versions. Precompilation
  and thread concurrency use Julia/project defaults or explicit task settings;
  the service imposes no single-task precompile or auto-precompile override.
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
  Julia 1.13.2 binary directly. It is not imposed on other projects.
- Local Kaimon 2.9.0 bootstrap repair (`mc-1xkm.13`): the launcher loads
  `commands/kaimon-managed-bootstrap.jl` after importing Kaimon. It verifies
  the upstream version and generated boot script, then imports the runtime's
  Pkg before optional Revise and KaimonGate. Instantiation and gate attachment
  retain their original positions. Together with the bundled depot entry,
  this prevents the reproduced LibCURL/Pkg startup failure when dependencies
  from a Julia 1.12 target manifest would otherwise load before Julia 1.13 Pkg.
  Neither change alone passed the controlled reproduction. The override changes
  no installed package source or project manifest; revalidate it on upgrade.
  To roll back, remove its launcher include and restore the prior launcher
  environment, then restart only Kaimon after resolving live session state.
  `commands/check-kaimon-bootstrap.jl` retains the generated-script regression:
  run it with the installed Julia 1.13 binary, `--startup-file=no`, the repaired
  service project and combined depot.
  It checks path quoting, Pkg-before-gate ordering, instantiation and both
  restart settings without starting a service or gate.
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
production `kaimon` for this Julia service.

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
When an included script loads packages that may precompile, put its imports
explicitly in the evaluation, for example
`ex(e="using DeRham, Oscar; include(\"/owned/check.jl\")", ses="<key>", q=false)`.
KaimonGate 1.4 detects `using`/`import` in the evaluation's syntax to suspend its
stream capture during package loading. An `include(...)` alone hides those
imports and can fail with `_CaptureIO does not support byte I/O` under Julia
1.12's precompilation world age. This is separate from the repaired LibCURL
bootstrap failure.
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

Without a recipe, gates use the daemon's Julia 1.13.2. Julia 1.12.7 is also
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

Kaimon's thread selection uses its normal project/default settings (`auto`
unless configured). Choose explicit threads for a task when appropriate.
Use the combined runtime/user/bundled depot for pinned DeRham environments.
The user depot alone lacked the exact pinned ColorTypes 0.12.1 source during
`ne-m7l`; its matching source is available in the isolated runtime depot.
Installing newer ColorTypes versions does not satisfy that manifest pin.

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

## Shared dependency images on the current Mac

### Polecat setup and candidate refresh (mc-occii.1)

The refresh branch adds `commands/kaimon-polecat-setup` as the one-line
`formula_vars.setup_command` for DeRham and GPUFiniteFieldMatrices. The normal
`mol-polecat-implement.workspace-setup` step invokes it in the newly created
linked worktree. This branch is pending review; these changes have not been
installed into the running city configuration.

The script runs `commands/kaimon-sysimage.py` directly through its Python 3.14
shebang, with `prepare --preserve-project`. Preparation rolls back if it would
rewrite Project.toml. Equivalent declared relative paths remain byte-for-byte
unchanged. Union construction preserves declared city-package URL/revision
sources, validating the workload checkout's clean status, origin and exact
commit first. For example, DeRham's GFM `url@v0.3.1` stays a Git source in both
Project and lock, rather than becoming a reference-worktree path. Julia Pkg
requires this source-kind agreement; an equivalent checkout path is insufficient.
The profile source map must list only intended editable path dependencies,
omitting GFM when the union pins its URL/revision.

Repository-local `info/exclude` entries for `/Manifest-v*.toml` and
`/kaimon.toml` keep the generated lock and host wrapper recipe out of ordinary
`git add`. Git shares that exclusion file across linked worktrees; it changes
no tracked file or running process. Setup refuses tracked/symlinked output
files and primary checkouts, preserves caller launch flags and the original
Julia binary, and respects an explicit image opt-out. It reruns prepare using
the tool's existing receipt on resume. Incompatible targets log the reason and
return success to workspace-setup. If an earlier setup installed the wrapper,
a rejected resume sets its image mode to `off`; remove that opt-out explicitly
before retrying image preparation. Other launch settings remain intact.

For a scoped canary, override only that workflow's setup command with the
owned script path and `--profile /absolute/candidate/profile.json`. Profile
publication alone preserves `.gc/kaimon-sysimages/current`; never activate a
candidate as a shortcut for a canary.

The 2026-10-30 refresh preflight is **blocked before image construction**:
fresh upstream DeRham `a2eee27` declares CUDA `5.7.3`, and CudaNTTs `c8b1fe1`
declares CUDA `5`. Native Julia 1.13.2 `Pkg.Versions` reports an empty
intersection with CUDA `6` for each. GFM v0.3.1 is exactly
`7192d479d2c41d31021a4938beec8223d16d6654`, whose Project has no CUDA compat
bound. No dependency constraint was widened, no CUDA patch was made, and no
new artifact/profile was built or selected. Coordinator disposition is needed
before a CUDA 6 union can satisfy the declared constraints.

| Required candidate evidence | DeRham | GPUFiniteFieldMatrices |
| --- | --- | --- |
| Real polecat workspace-setup | Not run: no compatible candidate | Not run: no candidate |
| Native image id / path / project / package source | Not run | Not run |
| Package load timings, image and off | Not measured | Not measured |
| Prepared-lock package tests | Not run | Not run |
| Clean canary worktree | Not run | Not run |

Owned inputs, dependency-conflict evidence and local regression logs are retained
under `.gc/kaimon-sysimages/mc-occii.1/`. The old artifact and current profile
remain available unchanged. This preflight supplies no image or GPU acceptance.
As a separate local smoke check, the retained profile prepared an owned GFM
v0.3.1 linked worktree twice, with clean Git status after both runs. An owned
DeRham worktree rejected that profile's GFM path substitution and returned
success to setup with its original Project and clean Git status restored.
These local checks did not dispatch polecats or load a candidate image.

### Current published image

The city image targets Julia **1.13.2 on macOS aarch64**. It resolves the
declared dependency union of DeRham, GPUFiniteFieldMatrices, MMPSingularities,
alexp616/GPUPolynomials, CudaNTTs, EdgeIdeals, NewtonExperiments and modern
Nemo 0.56.2, together with the installed KaimonGate bootstrap pins. The older
local Nemo 0.55.1 cannot satisfy DeRham's Oscar >=1.8 constraint; its dirty
checkout and local commit are preserved. The modern upstream source is isolated.
No canonical math Project or legacy Manifest is silently upgraded.

The immutable active profile is
`.gc/kaimon-sysimages/current/profile.json` (`current` is an atomic symlink to
one reviewed profile directory). Its `artifact_id` and absolute artifact path
determine selection, independently of cache directory sort order. Build, select,
prepare, wrapper and managed-hook defaults use that profile's artifact root;
the initial unconfigured build root is `.gc/kaimon-sysimages/artifacts`.
An explicit `--profile`/recipe `profile` or `--artifact`/recipe `artifact` is an
intentional override. Without a profile an isolated cache must contain exactly
one compatible image; multiple compatible images are rejected as ambiguous.

The common lock selects Oscar 1.8.2, Nemo 0.56.2, AbstractAlgebra 0.50.4,
CUDA 5.11.3, CSV 0.10.17 and DataFrames 1.8.2. The complete UUID/version/tree
graph, CPU target, Julia binary/base-image hashes, PackageCompiler lock,
warmup/build-input hashes, artifact checksum, size and build time are recorded
in each artifact's `metadata.json`. Artifacts and pinned build environments
live under ignored `.gc/kaimon-sysimages/`; binaries are never committed.

**The current route is the supported per-worktree `julia_bin` wrapper recipe
below. The live daemon has not loaded the managed selection hook. A compatible
Manifest alone does not select the image.** Use the wrapper in an owned project,
preserve its original exact binary and flags, and verify the actual child image.
Profile publication or activation does not install the hook in a live daemon.

`commands/kaimon-managed-sysimages.jl` provides automatic selection for **new
interactive sessions** only after a separately authorized future service rollout.
It retains caller project/version/binary/flags and explicit images. No service
restart, live patch or observer integration is part of this wrapper rollout.
`run_tests` keeps its original image resolver and isolated environment behavior.
The Pkg-before-gate bootstrap repair remains in place. No existing session is
changed by selection, profile publication, guidance updates or source edits.

The selector verifies the actual Julia patch/build, platform, generic CPU
target, immutable build inputs, binary checksum and all overlapping target
dependency UUID/version/tree identities. It also checks the installed gate's
actual hard dependency closure, plus direct compat in local path projects.
Before selecting an image it requires Julia's `Pkg.is_manifest_current` and
recorded hashes for every path dependency's Project file. Ordinary `.jl` edits
remain supported; changed dependency declarations require explicit preparation.
An incompatible/stale image is rejected with a Kaimon log diagnostic and normal
Julia fallback. Child `ENV["KAIMON_CITY_SYSIMAGE"]` reports the selected artifact
ID, `off`, or rejection reason. Always verify `VERSION`, `Base.active_project()`,
`unsafe_string(Base.JLOptions().image_file)` and `pathof` the editable package
with native tools. Explicit caller images remain caller-controlled.

Old committed manifests generally do not match the common lock. Prepare an
**owned isolated worktree before launching it**, using the published current
profile and an explicit map of any local dependency sources:

```sh
"$GC_CITY/commands/kaimon-sysimage.py" prepare \
  --project "$task_worktree" --owned-root "$task_owned_root" \
  --path-map "$GC_CITY/.gc/kaimon-sysimages/current/source-paths.toml"
```

The helper announces exact source replacements, backs up original target bytes
outside source, preserves legacy `Manifest.toml`, checks declared compat and
writes a Julia 1.13 versioned Manifest containing only the target/workspace
hard dependency closure. Rootself and unrelated repositories/stamps are removed;
every transitive editable needs an explicit source map or declared local source.
Frozen external UUID/version/tree pins remain exact. Receipts include the exact
Project diff and rollback bytes. An existing versioned Manifest needs a
matching tool receipt; `--replace-existing` explicitly backs up and replaces an
otherwise conflicting owned output. Symlinked targets, unselected foreign paths
and incompatible local development overrides are rejected. Failure restores the
original target files. Receipts report exact rollback backup locations. Pass
explicit `--julia`, `--union-manifest` and `--artifact` for independent review
before a current profile is published. This command does not authorize editing
a canonical checkout or another actor's worktree.

The initial profile's `source-paths.toml` names the retained reference copies
under `.gc/kaimon-sysimages/mc-xf9j5/workloads/`, not canonical repositories.
These shared inputs stay available after the worker drains. For a dependency
you will actively edit, supply your own `--path-map` with that package's absolute
owned worktree path; do not edit a retained reference copy or another task's
worktree. The root package always comes from your exact `--project`. Preparation
prints each source replacement and records its exact diff and original bytes.
Retain referenced worktrees, profiles, artifact/build depots and source locks
while any profile or session uses them; these city `.gc` paths are independent
of ephemeral provider homes.

For the current live service, use the validated selector through Kaimon's
supported `julia_bin` recipe. Keep existing thread, startup and extra-flag
settings; merge these fields into an untracked
`kaimon.toml` in the owned worktree (never commit host paths into a math repo):

```toml
[launch]
julia_bin = "/Users/Shared/Developer/ai/city/math-city/commands/kaimon-sysimage-julia"
julia_version = "1.13.2"

[city_sysimage]
julia_bin = "/Users/jj-agents/.julia/juliaup/julia-1.13.2+0.aarch64.apple.darwin14/Julia-1.13.app/Contents/Resources/julia/bin/julia"
mode = "auto"
```

The second `julia_bin` is the original exact binary/base wrapper, so `mode=off`
remains usable even if the image profile is broken. The wrapper automatically
validates the actual KaimonGate environment from the managed/base-wrapper load
stack or installed gate; no `bootstrap_projects` safety key is required.
It enforces requested Julia versions, publishes `KAIMON_CITY_SYSIMAGE`, and
forwards all caller flags/project unchanged apart from the validated image.
Kaimon's test runner is forwarded to the original Julia without injecting an
image because its script activates its test environment after startup. Default
hook activation later makes this per-worktree wrapper unnecessary; remove only
the added wrapper field and preserve the original recipe when retiring it.

City packages and KaimonGate stay outside the image. Registered Nemo is baked
as Oscar's dependency; the selector rejects a Nemo development project or a
path-developed baked dependency. Changing a baked dependency inside an already
running session requires a new session with the image disabled. Worktree code
remains local/editable; Revise is useful only when actually installed and loaded.
The image does not install it or make unsupported structural reloads work.
CUDA import and `functional()==false` on this host are CPU-only checks. They
establish no GPU numerical support or deployment support on another platform.
The full union can activate additional package extensions beyond a smaller
ordinary environment; one representative calculation is not universal workload
or extension/invalidation acceptance.

The `mc-xf9j5` union build uses a **local CUDA 5.11.3 compatibility fork**.
The version number alone does not identify the registered CUDA source. Its
registered base tree is `54751d09f9acf05ea7b7ee6baa6a99677c788880`; the fork commit
is `e8be927e4aba1bcbd9f147f310e2163c2a6246ea`, with tree
`ea57a047d5decf052949ffc063da95c0bd7ab905`. The 13 inserted lines annotate
`exit`/`nanosleep` as device functions and repair the observed Julia 1.13.2
docstring expansion in the existing annotation macro. The original GPU bodies,
signatures, documentation, package version and compat constraints are preserved.
CPU stubs, native precompilation, overlay AST preservation and a CUDA-only
diagnostic image were tested; these checks do not establish GPU execution or
full-union/native-provider acceptance.

The common lock pins that full commit through the local Git URL
`file:///Users/Shared/Developer/ai/city/math-city/.gc/kaimon-sysimages/mc-xf9j5/cuda-aot-repair/CUDA`.
Keep that repository and the retained
`.gc/kaimon-sysimages/mc-xf9j5/cuda-provenance-e8be927/CUDA-e8be927.bundle` on this
host. Image metadata records CUDA's `repo-url`, `repo-rev` and `git-tree-sha1`;
verify those fields when reproducing the build or aligning an owned target.
All other 261 common-lock entries are unchanged. Use the regenerated owned
Manifests for this fork; an old registered-CUDA Manifest must fail image
selection. Replacing the fork with registered/upstream source requires a new
lock, image and acceptance gates.

The current image policy supports **empty effective preferences for baked
package UUIDs (including declared extensions) only**. Julia's package-cache preference invalidation does not
reload modules already serialized into a sysimage. Before adding `-J`, the
selector uses `Base.get_preferences` over the ordered caller, actual base-wrapper
and managed bootstrap stacks, including exported Project preferences and
`JuliaLocalPreferences.toml`/`LocalPreferences.toml` with Julia's precedence and
clearing rules. Preferences for unbaked packages remain allowed. A nonempty
baked-package preference causes normal Julia fallback, or a required-mode error,
even when `Pkg.is_manifest_current` still accepts the lock. Use `mode = "off"`
for custom preferences; changing preferences in an existing image session
requires a new session. This policy does not support custom-preference images.

New builds freeze `preferences.json` and the probe source into the image's
hashed inputs and record the effective empty-preference identity in
`build-spec.json` before construction. They check the exact PackageCompiler
serialization stack again before construction and publication. Receipts contain
UUIDs, paths and hashes without preference values or keys. Older images without
this provenance require a rebuild; no empty-preference history is inferred.

For normal Julia or prescribed cold/clean-depot/default-image gates, preserve
the rest of the recipe and add:

```toml
[city_sysimage]
mode = "off"
```

`mode = "required"` makes image rejection fail the launch instead of falling
back. The service-wide equivalent is `KAIMON_SYSIMAGE_MODE=off` at its next safe
start. Removing the managed-sysimages include from the service launcher restores
upstream command construction; inventory live gates before any service restart.
Do not use an image for intentionally isolated baseline gates. Explicit
`--compiled-modules=no` and `--compiled-modules=existing` also bypass automatic
selection; combining either with `mode=required` fails explicitly.

Rebuild with `commands/kaimon-sysimage.py build` against the reviewed union lock
and exact Julia binary. Replay an artifact's pinned `tools/Manifest.toml` with
`--tools-manifest`; never run a broad update in canonical projects. Any Julia,
root set, dependency graph, PackageCompiler lock, CPU target, preference policy
or workload change
produces a new hash identity. Complete artifacts publish by atomic rename;
keep the previous artifact/profile for rollback and re-run native acceptance
before activating a replacement. Publication alone does not authorize a restart.

For the exact repaired Kaimon 2.9.0 managed bootstrap, image launch first runs
`Pkg.instantiate(; io=devnull, allow_autoprecomp=false)` in the original ordinary Julia process with the
same target project, working directory, depot and caller/bootstrap load path.
This keeps Pkg's dynamic artifact-selector children on Julia's base image.
The supported Pkg option suppresses redundant ordinary-image cache warming;
it retains resolution and artifact installation. Editable packages load normally
in the actual image session. Other launch routes retain their original automatic
precompilation behavior.
Afterwards selection requires unchanged Project/Manifest bytes and repeats
artifact, bootstrap dependency, path-source freshness, compat and preference
validation. Only after these checks succeed does the image process replace the
already completed instantiation with a comment; its Pkg/Revise/Gate imports,
gate options and caller launch flags remain unchanged. An unfamiliar managed
script rejects automatic image use. Instantiation failure or changed inputs
also rejects; auto mode retains the original ordinary Julia startup, while
required mode fails. Off mode, explicit caller images, test scripts and cache
policy bypasses retain their original bootstrap without this prelaunch step.

The selected-image route performs both freshness/compat/preference audits and
instantiation in one owned ordinary-Julia process. The first audit must pass
before Pkg acts. The second audit rereads target and path-source inputs;
Project/Manifest bytes and preference-file hashes must remain unchanged.
Comparing preference input hashes also rejects drift if Julia has cached an
earlier empty preference value. Artifact checksum and bootstrap provenance are
revalidated after that process returns. This reduces repeated Pkg startup;
it makes no change to caller flags or the readiness requirement.

`commands/check-kaimon-neutral-bootstrap.py` exercises this route with actual
ordinary-Julia processes and a copied owned DeRham fixture. It checks success,
the pre-instantiation preference veto, Project/Manifest mutations, a post-audit
preference veto, and preference-file drift with empty values. Supply the exact
`--julia`, `--artifact`, prepared `--source-project`, `--bootstrap-project` and
an explicit `--owned-root` for receipts. It loads no image, starts no gate and
edits only its new test directory; native delivery remains a separate gate.
The cold `check-kaimon-sysimages.jl` command test can additionally exercise the
real selected-image JSON/script path by setting `KAIMON_TEST_PROFILE`,
`KAIMON_TEST_PROJECT` and `KAIMON_TEST_OWNED_ROOT`. It constructs the command
against a copied target without executing the image or starting a gate.

Selected city images require the exact project to remain available. Singular's
baked initializer calls `Pkg.dependencies()` and fails if there is no active
project. The wrapper therefore exports `JULIA_PROJECT=<exact resolved project>`
before executing a selected image, in addition to the original `--project` flag.
The managed hook sets the same environment value in its bootstrap for later
children. This protects `Base.julia_cmd()` descendants which inherit `-J`
without an explicit project. Explicit child `--project` still takes precedence.
Off mode, test runners, explicit caller images and rejected city images retain
their original project environment. `check-kaimon-sysimage-child.py` checks an
owned inherited-image child with no project flag and an explicit-child override;
it starts no Gate or daemon and is not native acceptance or a benchmark.

After source/native review, create a frozen profile from the completed image,
the full union lock and the explicit source map:

```sh
"$GC_CITY/commands/kaimon-sysimage.py" publish-profile \
  --artifact "$artifact_directory" --union-manifest "$union_manifest" \
  --path-map "$source_path_map" --julia "$exact_julia_binary"
"$GC_CITY/commands/kaimon-sysimage.py" activate --profile "$reviewed_profile_json"
```

Publication preserves the current pointer. Activation atomically switches it
for future sessions; rollback runs `activate --profile` against the retained
previous profile. Both select the named artifact exclusively: an incompatible
profile falls back to normal Julia rather than silently choosing another cache.
They do not restart Kaimon or mutate an existing gate. Retain profile snapshots,
image/build depots and old artifacts while any profile or process references them.

`commands/kaimon-sysimage-benchmark.py` alternates same-version/project image
and normal fresh processes with matching managed bootstrap/thread settings,
then repeats CPU calculations in each process. It samples aggregate descendant
RSS. Existing depots and OS caches remain intact: these are process-cold tests,
not claims of OS-cold caches or clean depots. Record the first launch separately,
report the actual 60-second result, and retain the prescribed independent gates.

### Native acceptance results and wrapper release (2026-10-24)

The completed current-Mac image is
`be6cc6b35c11eef2b1077e5e0b0d3874f540d2a6872f2253f7ed2eb329487640`,
SHA256 `fb46d195e7392f87a1a262149cb6c420dd05ee67702f637bedebd729672fb2a9`.
It contains 32 external roots and 253 dependency graph entries, occupies
1,818,498,328 bytes and took 1,637 seconds to build with Julia 1.13.2 and
PackageCompiler 2.4.3. Profile `ceb668e8...` is now the active current profile
for the canonical wrapper route. The live service has not loaded the automatic
hook. The final launcher `e178a64` passed independent source review and the
delivered Codex checks below; earlier failed attempts remain part of this record.

The original independent Codex native calls used the same owned DeRham worktree, exact
runtime, prepared lock, managed depot and default `auto` threads (14+1).
Each row starts a fresh process; OS caches and existing depots were retained.
Full delivery includes startup, native call handling, provenance checks,
package loading, math and collection of the native result.

| Run | `start_session` seconds | Package load seconds | First math seconds | Full native delivery seconds | Peak aggregate RSS, GB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Image 1 | 34.128 | 0.179 | 0.138 | 54.558 | 5.67 |
| Off 1 | 48.137 | 52.474 | 0.792 | 168.621 | 2.87 |
| Off 2 | 18.129 | 54.927 | 1.146 | 104.883 | 2.95 |
| Image 2 | 80.317 | 0.247 | 0.927 | 100.948 | 5.62 |

**The repeated 60-second readiness gate failed.** Image 1 met that threshold
without overlap from the Claude reviewer. Off 1 overlapped that reviewer's
finite configuration checks (03:41:36–03:43:24 UTC). Off 1's
result delivery was interrupted and recovered later, so its full time is not
a clean comparison. Off 2's full time includes delayed background-result
collection; its package/math evaluation completed in 58.8 seconds after that
evaluation began. Off 2 and Image 2 ran after the reviewer stopped Julia work.
Fast image imports establish a package-load improvement; these measurements
do not establish a large improvement in total native readiness.

A subsequent source-edit acceptance attempt timed out at 120.332 seconds;
its late gate stalled and refused evaluation. After owned shutdown, a fresh
follow-up returned in 104.284 seconds and delivered package/math results in
126.141 seconds. That follow-up saw the source-only probe return 42, retained
Project/Manifest hashes and the correct editable source, and verified the
actual CUDA source tree. Revise was absent; this proves a fresh-session edit,
without establishing live reload or passing readiness.

The finite startup investigation first located Image 2's actual image process
about 5.3 seconds after invocation, followed by serial child processes until
about 74 seconds. Historical RSS samples record descendant IDs and root
commands, so they cannot identify those children. Installed Julia Pkg code
launches dynamic artifact selectors through `Base.julia_cmd()`, which inherits
the current image; this is a candidate source of repeated initialization
overhead. Separate first-image cache compilation was also reported by the
Claude reviewer. Full child commands and timestamped bootstrap phases are
being collected on owned acceptance fixtures to distinguish those costs.
No cause, fix, readiness waiver or production activation is inferred from
the import timings.

The subsequent owned trace established the expensive operation: instantiation
took 75.565 seconds, while Pkg import, optional Revise and KaimonGate import
took 0.001, 0.045 and 0.030 seconds respectively. Full command captures from
the Claude retry showed sequential CUDA runtime/compiler, LLVMExtra and CUDA
driver artifact selectors inheriting the full image, including its initialization
children. The neutral-instantiation repair above keeps those selectors on the
base image. Its first version still triggered ordinary-image package
precompilation: a native canary took 100.281 seconds to start, including an
observed 50.724-second DeRham compilation child, and failed readiness.

After disabling automatic precompilation only in the neutral selected-image
step, a fresh owned worktree with a source-only probe passed exact runtime,
project, image, editable source, lock/freshness, QQ math and state 41→42 checks.
The continuous native times were 56.193 seconds to session key, 62.273 to
provenance, 89.320 to delivered math and 94.589 to delivered state 42.
**Full readiness still failed the 60-second requirement.** No setup time is
excluded from that result. Neutral instantiation took 8.982 seconds and its
artifact selectors were subsecond base-image children. Compatibility/preference
processes occupied about 14 seconds; the image ran for about 24 seconds before
the session key returned. A fresh DeRham compilation child occupied about
21 seconds of the 27-second package/math call. Simple native calls also took
5–6 seconds. This is a cold source/worktree result with existing depots and OS
caches retained, not a fair paired benchmark. Independent updated cold/warm
measurements and review remain required before adoption.

Further independent checks of the refined route remain failures or incomplete
evidence. Codex's first image launch timed out at 120.325 seconds although its
gate advertised; the gate's local connected banner is unconditional and proves
no daemon adoption. The off-mode session delivered correct QQ math and state.
A second image launch has a recorded 40.2-second daemon startup and later native
provenance, but client interruption prevented a continuous full-readiness
measurement. Claude's fresh edited-source image session returned a key in
35.7 seconds; its first state assignment executed in the gate, while the reply
timed out and later calls reported a stalled session. An earlier no-image
session also lost replies. The exact transport failure remains under separate
investigation; these observations do not attribute it to the image.

The finite Claude review also found two image-initialization limits: starting
it without an active project fails in Singular's `locate_libsingular` through
`Pkg.dependencies()`, and a bare image process with an active project opens a
localhost TCP listener at startup (8086, advancing to 8087 when occupied).
At that review the listener's caller was unidentified. Normal Polymake/GAP/Singular probes
opened no listener; those controls do not establish the cause. Identification
and the project contract are separate acceptance gates. No package, tree or
builder input was changed based on this observation. Production remains
inactive, with the 60-second requirement and native delivery gates unmet.

The follow-up B3 investigation identified that listener as Tracy's profiler
client: CUDA → GPUCompiler → Tracy 0.1.6 → LibTracyClient_jll 0.13.1.
A native `bind`/`listen` interposer captured `tracy::ListenSocket::Listen` from
`tracy::Profiler::Worker` during package initialization. An ordinary-Julia
control loading only LibTracyClient_jll produced the same localhost listener;
`TRACY_PORT=9311` moved it to that port. The default is 8086, advancing when
occupied. It remains for the process lifetime. The coordinator accepted and
documented this behavior, with no package removal, artifact override or rebuild.
The launcher preserves a caller's `TRACY_PORT`. No connection to the ZMQ
reply/adoption failure was established. Detailed evidence is retained in
`image-init-diagnosis/FINDING.md` under the task directory. The active-project
contract is covered by the selected-launcher inheritance guard and child
control above; native delivery and full readiness remain separate gates.

The final `e178a64` launcher was reviewed independently after the fused guards
and selected-project inheritance changes. Its two sequential Codex image runs
used the supported wrapper on the unchanged production service (daemon PID
18411), exact Julia 1.13.2, owned prepared DeRham project, caller flags and depot.
The second image case included a new source-only probe in a fresh process;
Project and Manifest bytes stayed unchanged. Actual native results asserted
runtime, project, source paths, image checksum, dependency pins, QQ coefficients
`[6,5,4,3,2,1]`, evaluation `114`, CUDA unavailable and state 41→42. The edited
source probe also returned 42. Revise was absent; this proves a fresh-session
edit, without a live-reload claim.

| Final e178 case | Startup seconds | Package load seconds | Checked math delivered seconds | Separate state 42 delivered seconds | Peak aggregate RSS, decimal GB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Image 1 | 16.100 | 7.729 | 35.325 | 36.158 | 5.825 |
| Off 1 | 12.121 | 40.471 | 74.943 | 85.900 | 2.995 |
| Image 2, source edit | 26.153 | 13.916 | 52.100 | 53.459 | 5.857 |

**Both final Codex image observations passed the full 60-second requirement.**
Calls within each image sequence were prewritten and sequential, without agent
turn gaps. These successful later samples do not erase the original
100.948-second repeated image failure or the 94.589-second cold edited-source
failure. Existing package and OS caches were retained throughout; no clean-depot
or OS-cold result is claimed. Source-edit Image 2 forced root-package compilation
and is labelled separately from Image 1.

Off 1's evaluation reported 46.9 seconds, promoted to a background job after
30.080 seconds. Native collection occurred 32.736 seconds after promotion;
the separate state call also includes a 10.016-second agent gap. Those raw
74.943/85.900-second delivery times are retained, without deriving a wall-time
speedup ratio. A reversed Off 2 process started in 18.146 seconds but its first
evaluation and the script's erroneous follow-up both timed out waiting for
replies. No package result file existed. Its metadata, socket state, process
commands and sample were captured before coordinator-authorized owned cleanup.
The sampled main thread was in TTY setup; this observation does not establish
the transport failure's cause. There was no baseline retry. The coordinator
permitted only the planned Image 2 source-edit case, so the final record contains
one complete matched pair and a separate second image result.

The selected route retains full neutral instantiation with automatic cache
precompilation disabled; off mode keeps the original cache policy. Consequently
the comparison measures that reviewed adoption route, not an isolated image-only
effect. The RSS figures sum the root and its child processes; shared image
mappings can be counted twice. These samples show no memory saving and do not
establish universal readiness or a repair to general native transport reliability.
General transport follow-up `mc-rh0r2` remains BLOCKED and unrouted. Its disabled
observer implementation has not been integrated into the live service.

Independent Claude native acceptance on the same reviewed launcher also
delivered the edited-source probe, provenance, QQ math, persistent state and a
35-second background result. Measured startup/import/math components totalled
39.45 seconds. The raw wall to math was about 75 seconds, including one invalid
agent call and turn gaps; the component sum is not a measured full-delivery
60-second pass. The raw limitations remain in its receipt.

Final Codex events, full results, RSS, source-edit and cleanup receipts are in
`acceptance-codex-mc-wisp-21fg9x/e178a64-final-enzhrl/` under the task directory.
The separate Claude receipt is
`.gc/kaimon-scratch/mc-xf9j5.3-accept/e178/native-e178-receipt.json`.
All owned native keys/processes/samplers were retired, seven fixture source and
Project/Manifest hashes restored, and recipes restored. No service, profile or
production default was changed by these acceptance runs. At their completion
the profile was inactive; scoped installation, current-profile selection and a
canonical-wrapper native canary require the separate coordinator release check.

The coordinator-approved scoped release installed the 23 reviewed targets and
atomically selected profile
`ceb668e8da63456dd6423911510397236172bf0dd9fe10ee4271e38db7e0e467`.
One owned production-native canary used the canonical wrapper and **default
current profile**, without an explicit profile override. It delivered exact
Julia 1.13.2/project/image/status/`JULIA_PROJECT`/editable-source assertions,
image checksum, QQ coefficients and evaluation 114, then state 42 in a separate
call. The owned gate shut down; inventory returned to zero sessions and daemon
PID 18411 stayed unchanged. This verified installed-path/default-profile
adoption, not another benchmark. Actual `gc prime` output for Codex and Claude
and the native projection catalog passed the wrapper-route guidance check.
No service restart, live patch or observer integration occurred. Installation,
prior-absent/current pointer, canary metadata, shutdown and guidance receipts
are retained in `.gc/kaimon-sysimages/mc-xf9j5/release-20261024T0556Z/`.
For rollback use per-project `mode = "off"`; the current pointer was absent
before this release. Preserve all retained artifact/source/lock inputs above.

Raw receipts are retained under
`.gc/kaimon-sysimages/mc-xf9j5/acceptance-codex-mc-wisp-21fg9x/continuation-2jgcfx/`
(`native-events.json`, `native-results/`, startup logs and RSS samples), with
finite diagnostic receipts under the same task's `readiness-diagnostic/` and
`full-retry-e8be927/` directories. Preserve the failed attempts when adding
later acceptance or fix results.

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

The October 13 startup repair (`mc-1xkm.13`, commit `9ab0407`) passed fresh
Claude/Julia 1.13 and Codex/Julia 1.12 native startup, Pkg/Downloads provenance,
and persistent-state checks. This resolves the reproduced bootstrap failure;
it does not establish that every mathematical workload fits the host's budget.
Evidence and the reproducible CPU check are under
`.gc/maintenance/kaimon-repair-20261013/`.

An owned, unchanged copy of DeRham at `59b331b` passed actual native loading and
the QQ polynomial round-trip on Julia 1.12.7 with this explicit workaround:

```toml
[launch]
julia_version = "1.12"
threads = "1,1"
extra_flags = ["--compiled-modules=existing"]
```

The session returned state 42 from previously stored state 41 and verified
DeRham, Oscar and KaimonGate source paths. Loading took 437 seconds; the full
verification window peaked at 3.44 GiB. This is unsuitable evidence for a
60-second cold-start target and does not replace default compiled-module,
clean-depot, or benchmark gates. A previous one-thread trial lost its native
connection despite completing the package load in its process log; its cause
remains unknown. The successful two-pool trial does not establish that cause.

Default Hecke precompilation exceeded the tested 3–4 GiB setup caps on Julia
1.12, and the Julia 1.13 default workload trial also exceeded its 4 GiB cap.
Those owned jobs were stopped while several GiB remained available; the
default workload checks are still incomplete. A later Julia 1.12 setup with
explicit image/GC/BLAS thread limits exited successfully after 682 seconds,
peaking at 3.80 GiB, but reported Graphviz extension and Oscar/Polymake cache
warnings. Its native default-module follow-up verified Julia 1.12.7 and the
exact project, then disconnected during package loading after 471 seconds
while the Julia process remained alive. Its watcher recorded a 3.38 GiB peak
and no limit breach. The disconnect cause remains unknown; two thread pools
do not establish a fix. The owned process was retired after evidence capture.
The earlier explicit existing-cache native CPU/state proof remains valid.
An additional Julia 1.13 trial with the same existing-cache flag returned
native version/project/state provenance, then hit its 4 GiB owned RSS guard
after 252 seconds (4,228,968 KiB peak; 3,551,268 KiB minimum host availability).
Its native package/CPU evaluation failed on the resulting disconnect. The
owned process exited; this trial supplies no Julia 1.13 workload acceptance
and does not establish inherent version incompatibility.
The thread caps, external RSS/host-floor guards, and resource windows used in
these historical trials were retired by `mc-przuv`. Their original records are
preserved in the maintenance evidence. New work follows the current execution
policy and its actual test/benchmark requirements.

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
