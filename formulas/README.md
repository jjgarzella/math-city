# Root `formulas/` — what lives here, and how general it has to be

City-root formulas. `gc` discovers every `*.toml` here automatically (they show
up in `gc formula list` alongside pack-supplied ones). Discovery matches `.toml`
and nothing else, and neither `lib/` nor `test/` contains one — that is why the
shared shell libs and the test harnesses can sit here without being mistaken for
formulas.

This directory is **not a pack**. It has no `pack.toml`, it is not listed in the
root `pack.toml` `[imports]`, and it is not a submodule — unlike every reusable
pack in this city (`gasvillage`, `latex-utils`, `julia-tools`, `labtech`,
`argos`), each of which is its own published repo under `packs/`. So everything
here ships to exactly one city: this one.

That makes root `formulas/` the **staging ground for gascity framework work**:
all eleven formulas here were added in commits carrying a `gcs-*` build epic
from the `gascity` rig, and they live here so they can be dogfooded against a
live city before graduating. The
family it belongs to already has an upstream home —
`gascity/internal/bootstrap/packs/core/formulas/` ships `mol-polecat-base`,
`mol-polecat-commit`, `mol-polecat-report`, and `mol-review-quorum`.

Two tiers live here, and they have **different generality bars**. Know which
one you are editing.

## Tier A — city-local dogfood. Stays here. Do not scrub.

    expansion-smoke-reviewer.toml
    mol-ralph-smoke.toml
    mol-review-loop-smoke.toml
    test/**                        (including the DOGFOOD.md files)

These exist to prove *gascity* behaves correctly in a live city. Their local
references are the point, not leakage: `mol-ralph-smoke` names
`gastownhall/gascity#3029` because reproducing that bug is its entire job, and
`test/mol-standard-review/DOGFOOD.md` pins the real commit range `e1266ea~1..e1266ea`
because a synthetic diff would not have exercised the resolver. Genericizing
these destroys the evidence they carry.

Tests travel with their formula if it graduates; the `DOGFOOD.md` files stay
behind as validation history.

## Tier B — reusable, and on their way out of this repo.

    expansion-standard-reviewer.toml
    expansion-triage-reviewer.toml
    mol-standard-review.toml
    mol-triage-review.toml               (legacy claude-locked; retirement deferred)
    mol-triage-review-independent.toml
    mol-review-loop.toml
    mol-review-loop-standard.toml
    mol-polecat-implement.toml
    lib/*.sh

These are written to be reusable and are already close. Runtime config is fully
portable today: **no absolute paths anywhere**, all 24 `gc.run_target` values in
this directory are the import-relative `gasvillage.polecat` (never a
rig-qualified `gascity/gasvillage.polecat`), and `lib/` is resolved through
`$GC_CITY`. The `gastownhall/gascity#NNNN` references are upstream framework
traceability, which is the same convention the vendored `core` and `bd` packs
use — leave them.

What is *not* general yet is prose: sling examples in `description` blocks that
name the `gascity` rig, and `gcs-*` build-epic IDs in runtime step descriptions.
That is deliberate — these formulas are still being built incrementally, and the
epic IDs are working context while `gcs-f4j` is open. The scrub is filed as
`mc-eza3.6` and `mc-eza3.7` and is **gated on extraction**, not on today.

One Tier-B formula is already load-bearing outside this repo:
`packs/gasvillage/agents/polecat/agent.toml` sets
`default_sling_formula = "mol-polecat-implement"`, but `gasvillage-pack` ships
only `mol-upstream-bugfix.toml`. Any *other* city importing gasvillage gets a
polecat whose default sling formula does not resolve. Tracked as `mc-eza3.8`.

## Adding a formula here

Decide the tier first.

- Smoke test, reproduction, or anything whose value depends on naming a real
  bead / commit / rig → Tier A. Name the specifics; that is what makes it useful.
- Anything another city could plausibly want → Tier B. Keep runtime config
  import-relative and path-free from the start (that is the expensive half to fix
  later), and feel free to put local build context in prose — the scrub beads
  cover it at graduation.
