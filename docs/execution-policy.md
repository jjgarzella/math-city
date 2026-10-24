# Execution policy

Effective 2026-10-21, by direct overseer instruction recorded in `mc-przuv`,
the city's memory-constrained execution policy is retired for the hardware
migration. This supersedes memory instructions in older beads, mail, task
specifications, handoffs, and experiment/maintenance scripts.

Authorized work follows its task scope, dependencies, normal worker-pool
configuration, and validation requirements. It requires no mayor memory grant,
heavy-job reservation, global numerical lock, prescribed available-memory
floor or RSS ceiling, resource-window deadline, or machine-wide thread limit.
Use the underlying build/test/Julia commands directly. Choose parallelism for
the task and environment; retain experimental controls when they define the
measurement being reproduced.

## Preserved workflows

- Explicit pauses and coordinator review for unresolved scope, access, failure,
  or agent objections; the generic hold/resume/retry helper remains available.
- Task ownership checks, guarded bead updates, isolated worktrees, recorded
  branches/checkpoints, and dependency ordering.
- Review/fix workflows, their control-loop termination, and human merge gates.
- Required tests, baseline comparisons, exact project/version/source checks,
  and intentional cold-start/clean-depot acceptance semantics.
- Kaimon's package-loading repair, depot and Julia-version selection,
  authentication, provider projection, and ownership of live sessions.
- Existing application contracts such as FunSearch evaluator isolation and
  explicitly configured per-evaluation limits. These are part of the engine's
  candidate-execution contract, not the retired city scheduling policy.
- History, benchmark evidence, logs, artifacts, and credential protections.

The retirement does not launch work, resume any paused assignment, authorize a
merge or service restart, change experimental scope, or declare pending tests
passed. An old memory-only blocker can be resolved by recording this changed
condition on its original bead; mixed or unrelated blockers retain their normal
review. User-directed planning and the hardware switch remain with the overseer.

## Historical artifacts

Existing `.gc/maintenance/` inventories, grants, watchers, locks, resource
ledgers, `.gc/ne-m7l/` probes, `.gc/funsearch-smoke/` launchers, and task-local
agent/worktree/validation experiment scripts are historical evidence. Their
recorded limits describe past runs. They are not the execution path for new
work, and their lock files confer no current reservation. Reproduce their
original limits only when explicitly reproducing that historical experiment.

The shared `anatoly-memguard/memguard.py` entry point retains a compatible
command interface without memory or resource-window enforcement; its original
bytes are preserved in the retirement archive. Historical task-specific
watchers remain with their evidence and must not be installed into new tasks.

The city-wide `POVERTY_MODE` option is an explicit token-cost preference and is
inactive in the city configuration. Normal pool limits and scientific
single-thread measurements remain independent of the retired RAM policy.

Retirement snapshots, the artifact inventory, and verification records are under
`.gc/maintenance/memory-policy-retirement-20261021/`. No historical reports or
completed-work records were deleted or rewritten.
