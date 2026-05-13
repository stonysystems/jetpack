# TLA+ Big Picture For Jetpack

This note defines the intended TLA+ architecture, file naming, and finish
criteria for the decoupled `base_*` + shared `jetpack.tla` composition work.

## Goal

Jetpack is a plugin protocol layered on top of a base protocol. The TLA+ work
is finished when the decoupled `base_*` + shared `jetpack.tla` architecture is
checkable for every integrated protocol, without hiding protocol logic inside
the wrapper modules.

The target base protocols are:
- Raft
- CoPilot
- Mencius
- MongoDB

> **History note.** An earlier plan also called for "monolithic"
> single-file integrations (`jetpack_<proto>_monolithic.tla`) alongside the
> decoupled composition track. That plan was dropped: no `_monolithic.tla`
> files exist in the repo. All verification is now done via the
> decoupled `base_*` + `jetpack.tla` + `jetpack_<proto>_composition.tla`
> architecture described below.

## File Taxonomy

### Decoupled Jetpack composition (the only active track)

Base-adapter specs:
- `base_raft.tla`
- `base_copilot.tla`
- `base_mencius.tla`
- `base_mongodb.tla`

Shared Jetpack module:
- `jetpack.tla`

Thin composition wrappers:
- `jetpack_raft_composition.tla`
- `jetpack_copilot_composition.tla`
- `jetpack_mencius_composition.tla`
- `jetpack_mongodb_composition.tla`

Each `*_composition.tla` file should extend or instance exactly one `base_*`
module and the shared `jetpack.tla`, then do only the glue needed to wire
`Init`, `Next`, `Spec`, `Safety`, `UNCHANGED`, and any protocol-specific
execution-ordering helper such as `ApplyCommitted`.

## Naming Rule

The old filenames `jetpack_raft.tla`, `jetpack_copilot.tla`, and
`jetpack_mencius.tla` were thin wrappers over `base_*` plus `jetpack.tla`. They
were renamed on 2026-03-16 to:

- `jetpack_raft_composition.tla`
- `jetpack_copilot_composition.tla`
- `jetpack_mencius_composition.tla`

The MongoDB composition (`jetpack_mongodb_composition.tla`) was added later and
was created under the new naming scheme directly.

## Non-Negotiable Modeling Rule: The Base Protocol Owns the 3-D Log

This is the key design constraint for the decoupled architecture.

Required direction:
- the base protocol adapts upward to Jetpack
- each base module maintains a genuine 3-D replicated log as TLA+ state
- `jetpack.tla` consumes that 3-D interface directly

Required shared log shape:
- `log[i][j][k]`

Meaning:
- `i`: replica storing the copy
- `j`: logical proposer or sequence owner
- `k`: position inside that sequence

Concrete meaning:
- `log[i][i][k]` is replica `i`'s own logical sequence
- `log[i][j][k]` for `i /= j` is replica `i`'s copy of proposer `j`'s sequence

What is acceptable:
- base modules may keep extra internal helper state
- wrappers may do thin wiring
- unused logical sequences may stay blank / `Nil`

What is not acceptable:
- keeping a flatter base log as the real state and reconstructing `j` or local
  `k` in `jetpack.tla`
- projection operators that fake a 3-D interface from a 2-D state
- moving heavy protocol logic into the `*_composition.tla` wrappers

Per-protocol interpretation:
- Raft: one active logical sequence
- CoPilot: two active logical sequences
- Mencius: one logical sequence per server
- MongoDB: one active logical sequence (Raft-style)

## Required Property Coverage

Every composition checks the shared Jetpack-facing properties (all defined in
`jetpack.tla` and re-exported by the composition wrappers):

- `CommittedLogAgreement`
- `LogOrderMatchesExecution`
- `ExecutionDedupMatches`

Per-composition additions inside `Safety`:

- **Raft:** `NoLogDivergence`, `MaxOneReconfigurationAtATime` (reconfig
  invariants); `LogOrderMatchesExecution` is overridden to filter out config
  entries.
- **CoPilot:** `MultiSequenceLogAgreement`, `ActiveProposerBound`.
- **Mencius:** `MultiSequenceLogAgreement`, `SlotAgreement`.
- **MongoDB:** `MultiSequenceLogAgreement`.

For exact `Safety` formulas, see the corresponding `*_composition.tla`
file.

## Config Rules

Canonical configs used today:

- `jetpack_raft_large.cfg` — Raft only (reconfig constants, no `SYMMETRY`).
- `large.cfg` — shared by copilot / mencius / mongodb (5 servers, 3 clients,
  3 cmds, 2 keys, `SYMMETRY` on).
- `jetpack_<proto>_small.cfg` — small sanity-check configs for raft / copilot
  / mencius / mongodb (3 servers, narrow bounds).

Default rule:
- use the appropriate large config for each composition's accepted finish run
- use the small config for quick sanity checks after editing a spec

Debug-only rule:
- `*_small.cfg` is allowed for sanity checking and debugging
- a small run is not enough to claim the final task is finished unless the
  task explicitly says otherwise

## Runtime And Resource Rules

Accepted bounded-run target for the integrated specs:
- the run continues until it reaches the BFS depth limit imposed by the
  config's `StateConstraint`, or until manually stopped after the recorded
  evidence window in `VERIFICATION.md`

Before every TLC run:
- inspect total system memory
- cap TLC so it uses at most one third of total RAM
- apply that cap consistently to Java heap, Docker/container limits, and any
  wrapper-script settings

Do not silently shorten the evidence window and do not weaken the config to
make a run fit.

## What Counts As Finished

A deliverable counts only when all of the following are true:
- the spec filename matches one of the four composition wrappers
- the relevant invariants or properties are enabled in `Safety`
- the run uses the canonical cfg or an explicitly justified exception cfg
- the run respects the recorded time / depth window
- the run respects the one-third-memory cap
- the log is saved
- the result is summarized with the exact spec, cfg, memory cap, and outcome

The composition track is finished when:
- `base_raft.tla`, `base_copilot.tla`, `base_mencius.tla`, and
  `base_mongodb.tla` each pass their own protocol-needed checks
- `jetpack_raft_composition.tla`, `jetpack_copilot_composition.tla`,
  `jetpack_mencius_composition.tla`, and `jetpack_mongodb_composition.tla`
  each pass both the base properties and the Jetpack properties
- the composition wrappers remain thin glue modules

The latest snapshot recorded in `VERIFICATION.md` constitutes the current
accepted finish evidence across all four compositions (~8.5 B states
generated, ~1.21 B distinct as of 2026-05-13, with no safety violations;
the Raft and MongoDB runs are still progressing under the 2026-05-07
batch, while CoPilot and Mencius completed in the 2026-04-21 batch).

## Anti-Shortcut Rules

- Do not claim the composition goal is done merely because `base_*` and
  `jetpack.tla` exist.
- Do not move base-protocol or Jetpack core logic into `*_composition.tla`
  just to make the composition pass.
- Do not weaken invariants, reduce constants, or use a debug cfg for a
  claimed finish run unless the exception is explicit and approved by the
  task.
- Do not rely on old logs under the legacy wrapper filenames as final
  evidence without clearly mapping them to the renamed specs and re-checking
  that the acceptance criteria still match.
