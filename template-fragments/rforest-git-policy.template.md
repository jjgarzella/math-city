{{ define "rforest-git-policy" }}
## rforest publication policy

This policy applies to everyone coding, reviewing, or coordinating work in the rforest rig. Its persistent city-owned source is `template-fragments/rforest-git-policy.template.md`. The overseer's policy supersedes generic Git workflow guidance:

- Publish changes through pull requests targeting the fork `jjgarzella/rforest` only. Never create or update an upstream pull request.
- Push feature branches only to `https://github.com/jjgarzella/rforest.git`. Never push directly to `main`, in the fork or any other repository.
- Always pass `--repo jjgarzella/rforest` explicitly to GitHub pull-request commands; do not rely on fork/upstream defaults.
- Keep pull requests open for review. Do not merge unless the overseer explicitly authorizes merging.
- The test work uses the branch `tests/aws-regressions`, with its pull request targeting the fork's `main`. Base the first feature branch and pull request on `tests/aws-regressions`. Base subsequent dependent feature branches and pull requests on their immediate predecessor's feature branch, all in `jjgarzella/rforest`. Update pull-request bases after prerequisite pull requests merge.

If a task or formula still instructs a direct push to `main`, follow this rig policy and surface the conflicting instruction to the coordinator.
{{ end }}
