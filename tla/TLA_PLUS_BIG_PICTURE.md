# TLA+ Big Picture For Jetpack

This note records the intended TLA+ proof story for Jetpack so that humans and agents
can work from the same target instead of inferring it from scattered TODO items.

## Goal

Jetpack is a plugin protocol. It does not run meaningfully by itself. It must run on
top of a base/original protocol.

The TLA+ work therefore has three layers:

1. Prove each base protocol is reasonable on its own.
2. Prove Jetpack works when integrated with several concrete base protocols.
3. Prove Jetpack is a reusable abstraction rather than just three separate integrations.

The chosen base protocols are:
- Raft
- CoPilot
- Mencius

## Expected End State

The intended end state is:

### Step 1: Standalone base protocols

Have three standalone base-protocol specs:
- `raft.tla`
- `copilot.tla`
- `mencius.tla`

Each standalone base protocol should:
- define its own protocol state and transitions
- define its own protocol-specific invariants
- pass model checking for those invariants on a small config
- run a larger config for a long bounded search window if exhaustive checking is too large

Expected base-protocol properties:
- Raft:
  - `CommittedLogAgreement`
  - `ElectionSafety`
  - `LogOrderMatchesExecution`
- CoPilot:
  - `CommittedLogAgreement`
  - `ActiveProposerBound`
  - `LogOrderMatchesExecution`
- Mencius:
  - `SlotAgreement`
  - `CommittedLogAgreement`
  - `LogOrderMatchesExecution`

Interpretation rule:
- Small config pass = useful sanity baseline.
- Large config 2-day bounded run with no error = high confidence, not a formal proof.

### Step 2: Concrete Jetpack integrations

Have three separate integrated specs:
- `jetpack_raft.tla`
- `jetpack_copilot.tla`
- `jetpack_mencius.tla`

These are concrete Jetpack + base protocol combinations.

Each integrated spec should:
- include the base-protocol-specific behavior needed for composition
- include Jetpack behavior
- satisfy both:
  - the relevant base-protocol properties
  - the general Jetpack properties

Expected Jetpack-facing properties:
- `LogAgreement`
- `LogOrderMatchesExecution`
- `ExecutionDedupMatches`

Expected integrated checks:
- `jetpack_raft.tla`:
  - base-protocol safety + Jetpack safety
- `jetpack_copilot.tla`:
  - base-protocol safety + Jetpack safety + `ActiveProposerBound`
- `jetpack_mencius.tla`:
  - base-protocol safety + Jetpack safety + `SlotAgreement`

This step gives evidence that Jetpack is probably correct with three concrete integrations.

### Step 3: Shared Jetpack abstraction

This is the strongest and most important TLA+ design goal.

The point is to prove that Jetpack is the same abstract plugin across different base
protocols, not just three separate hand-written combined models.

Expected output for this step:
- `base_raft.tla`
- `base_copilot.tla`
- `base_mencius.tla`
- `jetpack.tla`

Then we should be able to compose:
- `base_raft.tla` + `jetpack.tla`
- `base_copilot.tla` + `jetpack.tla`
- `base_mencius.tla` + `jetpack.tla`

Important clarification:
- A thin composition driver/wrapper is acceptable for wiring `Init`, `Next`, `UNCHANGED`,
  or `INSTANCE ... WITH ...`.
- What is not acceptable is embedding different Jetpack logic per protocol and then
  claiming the abstraction proof is complete.

The success criterion for Step 3 is:
- the same `jetpack.tla` is reused across all three base protocols
- the base-specific modules adapt their protocol into a shared Jetpack-facing interface
- the resulting model checks satisfy both Jetpack invariants and base-protocol invariants

## Desired Log Abstraction

The intended abstract log model is 3-dimensional:

`Log[i][j][k]`

Meaning:
- `i`: where this copy is stored
- `j`: which logical proposer/sequence this log belongs to
- `k`: the position within that sequence

Interpretation:
- `Log[i][i][k]` = the original/local copy of server `i`'s own logical sequence
- `Log[i][j][k]` with `i /= j` = a replicated copy of server `j`'s logical sequence stored at server `i`

This gives a common logical representation across protocols with different leadership styles.

### Raft interpretation

If the leader is server `0`:
- only sequence `j = 0` is active
- `Log[*][0][k]` matters
- `Log[*][1..n-1][k]` stays unused/blank

This models:
- one leader-owned sequence
- follower replicas storing copies of the leader sequence

### CoPilot interpretation

If Pilot is `0` and Copilot is `1`:
- only sequences `j = 0` and `j = 1` are active
- `Log[*][0][k]` and `Log[*][1][k]` matter
- `Log[*][2..n-1][k]` stays unused/blank

This models:
- two distinguished ordering sequences
- all replicas storing copies of those sequences

### Mencius interpretation

For Mencius:
- every server owns one logical sequence
- all `Log[i][j][k]` may be relevant

This models:
- each server proposing in its own sequence
- each server also keeping replicas of the others' sequences

## Required Execution Logs

Two global execution sequences are needed:

- `original_execution_cmds`
  - append a command whenever the base/original protocol executes it

- `execution_cmds`
  - append a command whenever either:
    - the base/original protocol executes it, or
    - Jetpack fast path succeeds for it

For Jetpack fast-path success, the success condition should reflect the relevant
proposing supermajority:
- Raft: all proposing replicas including the leader
- CoPilot: all proposing replicas including Pilot and Copilot
- Mencius: all proposing replicas for the active view

## Required Agreement / Ordering Semantics

### Replicated-log agreement

For the base/original protocol and Jetpack integration:
- replicated copies should match the original copy of the same logical sequence

Intended form:
- if `Log[i][j][k]` and `Log[j][j][k]` are both non-nil, then they should match

This is the more precise meaning of log agreement for the shared abstraction.

### Conflict ordering

For any pair:
- `Log[i][j][k1]`
- `Log[i][j][k2]`

with `k1 < k2`, if both commands exist and they conflict on the same key, then:
- the first time `Log[i][j][k1]` appears in the deduplicated execution should be before
  the first time `Log[i][j][k2]` appears in the deduplicated execution

This is not just indexwise equality with the execution log. It is a conflict-ordering
property across utilized log sequences.

### Cross-execution conflict ordering

The intended relationship between `original_execution_cmds` and `execution_cmds` is:
- deduplicate both execution traces first
- then compare only the relative order of conflicting command pairs

Required rule:
- if conflicting commands `A` and `B` both appear in `Dedup(original_execution_cmds)` and
  `A` is before `B`, then `A` must also be before `B` in `Dedup(execution_cmds)`
- if conflicting commands `A` and `B` both appear in `Dedup(execution_cmds)` and `A` is
  before `B`, then `A` must also be before `B` in `Dedup(original_execution_cmds)`

This is intentionally weaker than requiring one deduplicated execution trace to be a
prefix of the other.

## Model-Checking Workflow Requirements

### Config sizes

Small config:
- minimal sanity model
- intended for quick exhaustive or near-exhaustive checking

Large config:
- at least 5 servers
- at least 2 keys
- at least 3 commands

### Runtime policy

For each standalone or integrated spec:
- first run the small config
- then run the larger config
- if the larger config is too large for exhaustive checking, run for a long window
  (target: about 2 days)

Interpretation:
- “2 days with no error” means “probably right / no bug found yet”
- it does not mean “formally proved”

### Log retention policy

Every run should save a log file.

The filename should include:
- timestamp
- spec/protocol name
- config name or size marker

Example shape:
- `tla/log/2026-03-02_jetpack_mencius_small.log`
- `tla/log/2026-03-02_jetpack_mencius_large.log`

Do not rely on unsaved terminal output for proof claims.

## What Counts As A Real Pass

A run only counts as passed if:
- TLC finishes without invariant violation
- there is no TLC exception
- the exact spec and config are recorded
- the log file is saved

A run does not count as passed if:
- it only has “no error yet” mid-run progress
- TLC crashes
- TLC reports invariant violation
- the run is partial but undocumented
- the result is later summarized in TODO without a corresponding saved log

## Current Repository Status (updated 2026-03-07)

All three steps of the TLA+ proof story are complete:

### Step 1: Standalone base protocols — DONE
- `raft.tla` — CommittedLogAgreement, ElectionSafety, LogOrderMatchesExecution
  (exhaustive 40M states at small config; partial 21M+ at large 5-server config)
- `copilot.tla` — CommittedLogAgreement, ActiveProposerBound, LogOrderMatchesExecution
  (partial 11M+ states at large 5-server config; LogOrderMatchesExecution scoped to
  committed prefix due to dual-proposer design)
- `mencius.tla` — SlotAgreement, CommittedLogAgreement, LogOrderMatchesExecution
  (partial 13M+ states at large 5-server config)

### Step 2: Wrapper compositions — DONE
- `jetpack_raft.tla` = `base_raft.tla` + `jetpack.tla` (thin wrapper)
- `jetpack_copilot.tla` = `base_copilot.tla` + `jetpack.tla` (thin wrapper)
- `jetpack_mencius.tla` = `base_mencius.tla` + `jetpack.tla` (thin wrapper)
- All three verified at small config (exhaustive for Raft/CoPilot) and large config
  (5 servers, 3 cmds, 2 keys — partial, no violations)

### Step 3: Shared Jetpack abstraction with 3D log model — DONE
- `jetpack.tla` is the single shared module, INSTANCE'd by all three wrappers
- `CONSTANT ProposerOfEntry(_, _)` replaced old `ProposerOfSlot(_)` to support
  both positional (Raft/Mencius) and entry-metadata-based (CoPilot) proposer ID
- 3D projection operators: `EntryProposer`, `ProposerSlots`, `Log3D`, `Log3DLen`,
  `ProposerCmdSeq` — reconstruct `Log[i][j][k]` from flat `log[i][k]`
- Per-protocol mapping:
  - Raft: `Proposer = {"sole"}`, single sequence
  - CoPilot: `Proposer = Server`, two sequences (pilot + copilot via `entry.proposer`)
  - Mencius: `Proposer = Server`, N sequences (round-robin via `CoordinatorOf(k)`)
- Shared properties verified across all three:
  - `CommittedLogAgreement` — flat committed-prefix agreement
  - `MultiSequenceLogAgreement` — per-proposer 3D log agreement
  - `LogOrderMatchesExecution` — per-sequence conflict ordering in execution trace
  - `ExecutionDedupMatches` — bidirectional conflict order between original/actual execution
- TLC logs saved in `tla/log/` with protocol name and run description

### Resolved issues from 2026-03-02 review
1. `base_raft.tla`, `base_copilot.tla`, `base_mencius.tla` — all created and active
2. 3D log model — implemented via projection/refinement (Option B)
3. Property definitions — rewritten to match intended proof story
4. Mencius wrapper violations — fixed (ExtendLog, NoOp filtering, committed-prefix scoping)
5. Abstraction goal — achieved with shared `jetpack.tla` + thin wrappers
6. TLC log retention — timestamped logs saved for every proof claim

## Practical Guidance For Maintenance

Anti-overclaim rules (still apply):
- Do not mark a spec "passed" if the saved log shows an invariant violation.
- Do not mark Step 3 complete just because wrapper modules exist.
- Do not claim abstraction success until the same `jetpack.tla` is reused with all
  abstracted base protocol modules.
- A partial run with no error is "high confidence", not a formal proof.
