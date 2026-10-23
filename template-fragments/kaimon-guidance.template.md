{{ define "kaimon-guidance" }}
## Kaimon / Julia MCP guidance

Use native production `kaimon` tools for interactive Julia and repeated calculations.
Discover the tools/schema and call `ping(extended=true)` to inventory live sessions.
Any existing project/worktree with `Project.toml` can be launched without a
per-project allow-list edit or another human permission loop:
`start_session(project_path="/absolute/exact/worktree", name="<task-owner>")`.
Target its returned key on every call: `ex(e="state = 41", ses="<key>")`, then
`ex(e="state + 1", ses="<key>", q=false)` returns 42 in the same warm process.
Use `q=false` when you need the value; collect slow evaluations with
`check_eval(eval_id="<returned-id>")`. Retain state across repeated calls.

The service is shared. `start_session` deduplicates by normalized project path,
even with a different name. Names alone do not isolate sessions. Reuse a key only
when the live session belongs to this task and has the exact project/version;
otherwise use an owned separate worktree or scratch path. Never mutate another
actor's live session, change its project/version, restart the service, or shut it
down. Close only disposable sessions you own with
`manage_repl(command="shutdown", session="<key>")`.

For ad hoc Julia without a package project, create an owned environment outside
repository source, then pass the printed directory to `start_session`:

```sh
mkdir -p "$GC_CITY/.gc/kaimon-scratch"
scratch=$(mktemp -d "$GC_CITY/.gc/kaimon-scratch/${GC_SESSION_ID:-task}-XXXXXX")
touch "$scratch/Project.toml"
printf '%s\n' "$scratch"
```

Default sessions use the daemon's Julia 1.13.2 on the current Mac. Installed Julia 1.12.7 is also
available. To select it, merge this into the owned project's `kaimon.toml`
before launching, preserving other launch settings:

```toml
[launch]
julia_version = "1.12"
```

An explicit `julia_bin` overrides `julia_version`; check existing recipes. Kaimon may substitute the daemon version if a requested version is
missing. Confirm `VERSION` and `Base.active_project()` with native `ex(q=false)`;
a substituted version does not satisfy a version-specific task.

Use the reviewed city shared dependency image through automatic selection for
compatible **new** Kaimon sessions; agents do not need manual `-J` flags.
Before launching a task-owned worktree whose old Manifest differs from the
published common lock, prepare it explicitly:

```sh
"{{ .CityRoot }}/commands/kaimon-sysimage.py" prepare \
  --project "$task_worktree" --owned-root "$task_owned_root" \
  --path-map "{{ .CityRoot }}/.gc/kaimon-sysimages/current/source-paths.toml"
```

Preparation announces and backs up exact target source/lockfile changes; never
apply it to a canonical or foreign checkout. An existing versioned Manifest
requires a matching tool receipt or explicit `--replace-existing`. A rejected
preparation restores original files. Existing caller flags/images remain intact.
Stale/incompatible images fall back to normal Julia with a diagnostic; check
`ENV["KAIMON_CITY_SYSIMAGE"]` and
`unsafe_string(Base.JLOptions().image_file)` along with version/project/source.
The current image is specific to Julia1.13.2/macOS aarch64; it does not cover
Julia1.12, another host, GPU numerical work, or development of a baked dependency.
Keep Nemo and other local source work editable; a Nemo development context must
use normal Julia when Nemo is baked for Oscar. Never rely on `Pkg.develop` to
replace an already baked package in a running image session.

For prescribed cold/clean-depot/default-image tests or rollback, preserve the
recipe and set `[city_sysimage] mode = "off"` before launching a new owned
session. `mode = "required"` makes compatibility failure explicit. Never restart
the shared service merely to change your worktree's mode. Follow the artifact,
rebuild, receipt rollback and verified deployment instructions in the city docs;
guidance or a saved profile alone does not prove an image was actually selected.

Before evaluating changed package code, confirm the **exact project/worktree**
and loaded package source (`pathof(Package)` after loading it). Editing files
alone does not replace loaded definitions; Revise covers supported edits when
loaded, while structural/module changes may need a fresh owned session. Never
validate a modified worktree in a session attached to another checkout.

Read `{{ .CityRoot }}/docs/kaimon.md` for launch/depot details, ownership,
credential/projection lifecycle and troubleshooting. Fresh Claude/Codex sessions
receive native projection; existing conversations can retain an old credential
until natural refresh. Report concrete native-tool failures and identify any
justified direct-Julia fallback and its reason; do not claim warm execution.

Keep prescribed formula/test gates and intentionally isolated cold-start or
clean-depot tests intact until `mc-1xkm.2` and `mc-1xkm.3` preserve their semantics.
This guidance does not authorize skipping checks or using the wrong checkout.
{{ end }}
