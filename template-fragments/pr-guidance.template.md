{{ define "pr-guidance" }}
## Pull request guidance

Any agent preparing, opening, or updating a pull request must use a PR template
format similar to Gas City's, rather than inventing its own format.

Use the Gas City rig's `.github/pull_request_template.md` as the reference:
`{{ .CityRoot }}/../gascity/.github/pull_request_template.md`.
Keep its **Summary**, **Testing**, and **Checklist** structure. Adapt the testing
commands and checklist items to the target repository, and preserve any fields
required by that repository's existing PR template. Report the checks actually
performed and their results; only mark completed checklist items as checked.
{{ end }}
