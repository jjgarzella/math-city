Run `bash formulas/test/review-helper-bd13/run.sh` with the installed `bd`, `jq`,
`git`, and Bash. This suite creates a temporary embedded bd store, clears ambient
store configuration, stubs city heartbeats, and removes its fixtures on exit.
It never reads or writes the city's existing reviews.

The checks exercise actual candidate/container persistence, supported parent and
label commands, mixed durable/ephemeral enumeration, promotion provenance and
retries, severity sorting, and verdict persistence. A wrapper injects write/read
failures and successful commands with missing persistence to verify that the
helpers return failures and leave review steps open.

A lane writes `finding-write-failed-<lane-id>` in its durable input directory
before filing. The marker retains the title, body-file path, and candidate ID
when available. A failure keeps this marker across command substitutions and
worker restarts. Reconcile the failed write (including any already-created
candidate) before removing the marker and retrying or closing the lane. The
helper does not clear unresolved failures on subsequent calls.
