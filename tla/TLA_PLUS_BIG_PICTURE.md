# TLA+ Big Picture For Jetpack

This note defines the intended TLA+ architecture, file naming, and finish criteria.
The main purpose is to keep the first-step monolithic work separate from the
second-step decoupled composition work.

## Goal

Jetpack is a plugin protocol layered on top of a base protocol. The TLA+ work is
finished only when both of the following stories are covered:

1. the base protocols and monolithic Jetpack integrations are checkable as
   standalone artifacts
2. the decoupled `base_*` + shared `jetpack.tla` architecture is checkable
   without hiding protocol logic inside the wrapper modules

The target base protocols are:
- Raft
- CoPilot
- Mencius

## File Taxonomy

### Part 1: Base protocols and monolithic Jetpack integrations

Base protocol specs:
- `raft.tla`
- `copilot.tla`
- `mencius.tla`

Monolithic integrated specs:
- `jetpack_raft_monolithic.tla`
- `jetpack_copilot_monolithic.tla`
- `jetpack_mencius_monolithic.tla`

A monolithic integrated spec is a self-contained model of "base protocol +
Jetpack integration". It is not a thin wrapper around `base_*` plus `jetpack.tla`.

### Part 2: Decoupled Jetpack composition

Base-adapter specs:
- `base_raft.tla`
- `base_copilot.tla`
- `base_mencius.tla`

Shared Jetpack module:
- `jetpack.tla`

Thin composition wrappers:
- `jetpack_raft_composition.tla`
- `jetpack_copilot_composition.tla`
- `jetpack_mencius_composition.tla`

Each `*_composition.tla` file should extend or instance exactly one `base_*` module
and the shared `jetpack.tla`, then do only the glue needed to wire `Init`, `Next`,
`Spec`, `Safety`, `UNCHANGED`, and any protocol-specific execution ordering helper
such as `ApplyCommitted`.

## Naming Rule

The old filenames `jetpack_raft.tla`, `jetpack_copilot.tla`, and
`jetpack_mencius.tla` were already thin wrappers over `base_*` plus `jetpack.tla`.
They therefore belong to Part 2 and have been renamed to:

- `jetpack_raft_composition.tla`
- `jetpack_copilot_composition.tla`
- `jetpack_mencius_composition.tla`

Do not satisfy the monolithic deliverable by relabeling a composition wrapper.
If a `*_monolithic.tla` file is needed, it must actually be a first-step,
self-contained integrated model.

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
- keeping a flatter base log as the real state and reconstructing `j` or local `k`
  in `jetpack.tla`
- projection operators that fake a 3-D interface from a 2-D state
- moving heavy protocol logic into the `*_composition.tla` wrappers

Per-protocol interpretation:
- Raft: one active logical sequence
- CoPilot: two active logical sequences
- Mencius: one logical sequence per server

## Required Property Coverage

### Standalone base protocols

Expected base properties:
- `raft.tla`:
  - `CommittedLogAgreement`
  - `ElectionSafety`
  - `LogOrderMatchesExecution`
- `copilot.tla`:
  - `CommittedLogAgreement`
  - `ActiveProposerBound`
  - `LogOrderMatchesExecution`
- `mencius.tla`:
  - `SlotAgreement`
  - `CommittedLogAgreement`
  - `LogOrderMatchesExecution`

### Decoupled base modules

The adapted base modules must be able to run and pass the protocol-side invariants
they need before the composition results count:
- `base_raft.tla`
- `base_copilot.tla`
- `base_mencius.tla`

### Integrated Jetpack specs

Both monolithic and composition variants must check:
- the relevant base-protocol properties
- the Jetpack-side properties

Expected Jetpack-facing properties:
- `LogAgreement`
- `LogOrderMatchesExecution`
- `ExecutionDedupMatches`

Protocol-specific additions:
- CoPilot keeps `ActiveProposerBound`
- Mencius keeps `SlotAgreement`

## Config Rules

Canonical base configs:
- `raft.cfg`
- `copilot.cfg`
- `mencius.cfg`

These three config files are immutable. Do not modify them.

Default rule:
- use `raft.cfg`, `copilot.cfg`, and `mencius.cfg` for the base protocol runs
- use the same constants and invariant intent when checking the adapted base modules

Explicit exception rule:
- if a Jetpack-integrated spec needs extra constants or properties such as `Client`
  or `Safety`, it may use a checked-in Jetpack-specific cfg
- that exception must be called out explicitly
- the exception cfg must preserve the same `Server`, `CmdId`, and `Key` cardinalities
  as the canonical base cfg for any claimed finish run

Debug-only rule:
- `*_small.cfg` is allowed for sanity checking and debugging
- a small run is not enough to claim the final task is finished unless the task
  explicitly says otherwise

## Runtime And Resource Rules

Accepted bounded-run target for the integrated specs in the current phase:
- 1 hour per spec

Priority order:
- high priority:
  - `jetpack_raft_composition.tla`
  - `jetpack_copilot_composition.tla`
  - `jetpack_mencius_composition.tla`
- low priority:
  - `jetpack_raft_monolithic.tla`
  - `jetpack_copilot_monolithic.tla`
  - `jetpack_mencius_monolithic.tla`

Before every TLC run:
- inspect total system memory
- cap TLC so it uses at most one third of total RAM
- apply that cap consistently to Java heap, Docker/container limits, and any wrapper
  script settings

Do not silently shorten the 1-hour window and do not weaken the config to make a run fit.

## What Counts As Finished

A deliverable counts only when all of the following are true:
- the spec filename matches the intended deliverable
- the relevant invariants or properties are enabled
- the run uses the canonical cfg or an explicitly justified exception cfg
- the run respects the one-hour time budget for the integrated specs
- the run respects the one-third-memory cap
- the log is saved
- the result is summarized with the exact spec, cfg, memory cap, and outcome

Part 2 composition is finished only when:
- `base_raft.tla`, `base_copilot.tla`, and `base_mencius.tla` each pass their own
  protocol-needed checks
- `jetpack_raft_composition.tla`, `jetpack_copilot_composition.tla`, and
  `jetpack_mencius_composition.tla` each pass both the base properties and Jetpack
  properties
- the composition wrappers remain thin glue modules

Part 1 monolithic is finished only when:
- `jetpack_raft_monolithic.tla`, `jetpack_copilot_monolithic.tla`, and
  `jetpack_mencius_monolithic.tla` exist as real monolithic integrations
- each passes the one-hour bounded run under the accepted rules

## Anti-Shortcut Rules

- Do not claim the composition goal is done merely because `base_*` and `jetpack.tla`
  exist.
- Do not claim the monolithic goal is done by copying or renaming a composition wrapper.
- Do not move base-protocol or Jetpack core logic into `*_composition.tla` just to make
  the composition pass.
- Do not weaken invariants, reduce constants, or use a debug cfg for a claimed finish run
  unless the exception is explicit and approved by the task.
- Do not rely on old logs under the legacy wrapper filenames as final evidence without
  clearly mapping them to the renamed specs and re-checking that the acceptance criteria
  still match.
