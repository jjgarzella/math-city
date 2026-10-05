{{ define "kaimon-guidance" }}
## Kaimon / Julia MCP guidance

Prefer native production `kaimon` MCP tools for interactive Julia evaluation,
exploratory calculations, and repeated work that benefits from warm state.
Read the tool usage instructions/schema as needed and inspect available sessions
before choosing or creating one.

Use a session matching the **exact project/worktree and required Julia version**.
Before evaluating changed code, confirm the active project and loaded package
source. Never validate a modified worktree in a warm session attached to the
original checkout or another branch. Observe module/code reload limitations:
editing files does not automatically replace loaded definitions.

The service is shared. Preserve other agents' and the user's sessions and state;
explicitly target the selected returned session key in subsequent calls. Close
only disposable sessions you own. Do not restart the service, shut down others'
sessions, or change the project/version under a shared live session.

Read `{{ .CityRoot }}/docs/kaimon.md` for lifecycle, project registration,
connectivity, and state policy, including the current managed-project/version
allow-list. Tools are projected by default; this does **not** mean every worktree
or GPUFiniteFieldMatrices project is registered. Currently managed sessions allow
only the original DeRham.jl checkout on Julia 1.13; consult that document for
updates. If the required project/worktree is unregistered, no suitable session
is available, or native calls fail, report
the concrete limitation. Explicitly identify any justified direct-Julia fallback
and its reason; do not claim warm execution or default to repeated `julia -e`
processes. Routine diagnostics do not require another user approval loop.

Keep prescribed formula/test gates and intentionally isolated cold-start or
clean-depot tests intact until the runner/formula migrations (`mc-1xkm.2` and
`mc-1xkm.3`) preserve their semantics. This preference does not authorize skipping
checks or running a gate against the wrong checkout.
{{ end }}
