{{ define "execution-policy" }}
## Execution policy

The overseer retired the memory-constrained execution policy on 2026-10-21
(bead mc-przuv). Authorized work proceeds under its scope and dependencies
without memory grants, reserved heavy-job slots, global numerical locks,
RSS/headroom thresholds, resource-window deadlines, or machine-wide
single-thread requirements. Choose concurrency through normal task and pool
configuration. Explicit benchmark methodology remains part of its experiment.

Historical memory grants, holds, guards, and task resource instructions are
preserved as evidence and have no authority over future execution. Use current
task commands directly, without the retired memory wrappers. See
`{{ .CityRoot }}/docs/execution-policy.md`.

Keep ownership checks, explicit pauses, worktree isolation, dependencies,
review and human merge gates, required tests, Julia project/version/source
checks, and protections for other actors' processes and live state. Retiring
resource policy does not resume paused work, launch tasks, waive validation,
or expand an assignment's scope.
{{ end }}
