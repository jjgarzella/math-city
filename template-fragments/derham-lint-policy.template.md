{{ define "derham-lint-policy" }}
## DeRham.jl comment-lint policy

This policy applies to everyone coding or reviewing in the DeRham.jl rig. It was set by the overseer and is recorded in bead dr-to77; its city-owned source is `template-fragments/derham-lint-policy.template.md`. It supersedes the generic handling of the `lint_command` gate in formulas:

- The `no-code-comments.sh` lint is enforced **only for new changes**. Do not add non-doc `#` or `#=` comments in `src/` or `test/`. Docstrings are fine.
- The base branch already has hundreds of pre-existing findings. They do not fail preflight, self-review, or acceptance. Do not file bugs for them; they are tracked by the deferred bead dr-3zud. Do not clean up unrelated existing comments as part of your task.
- To check, compare findings between the merge base and HEAD with line numbers stripped. Any finding that appears only at HEAD is new and must be fixed:

```sh
LINT='PATH=/Users/jj-agents/.juliaup/bin:$PATH /Users/Shared/Developer/ai/city/math-city/packs/julia-tools/lib/no-code-comments.sh'
norm() { grep ': non-doc comment: ' | sed -E 's/:[0-9]+:/:/' | sort; }
eval "$LINT" 2>&1 | norm > /tmp/lint-head.txt
git worktree add --detach /tmp/lint-base "$(git merge-base HEAD origin/<base_branch>)"
(cd /tmp/lint-base && eval "$LINT") 2>&1 | norm > /tmp/lint-base.txt
git worktree remove --force /tmp/lint-base
comm -13 /tmp/lint-base.txt /tmp/lint-head.txt
```

The gate passes when the final `comm` command prints nothing. Report it in the PR or bead as "no-code-comments: no new findings (pre-existing baseline per dr-to77)".
{{ end }}
