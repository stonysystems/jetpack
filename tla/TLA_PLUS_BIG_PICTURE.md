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

### Step 3: Shared Jetpack abstraction with true 3-D base-protocol log

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
- **the shared Jetpack-facing log interface is a real 3-dimensional base-protocol log
  `Log[i][j][k]` that is maintained as actual state by the base protocol, not a
  projection or refinement layer reconstructed from a flatter base log**
- the resulting model checks satisfy both Jetpack invariants and base-protocol invariants

## Non-Negotiable Modeling Rule: The Base Protocol Owns the 3-D Log

This is the single most important design constraint for Step 3.

**Required direction:**
- The base protocol adapts upward to Jetpack.
- Each base protocol module (`base_raft.tla`, `base_copilot.tla`, `base_mencius.tla`)
  **maintains** a genuine 3-D replicated log as protocol state.
- `jetpack.tla` **consumes** that shared 3-D log interface directly. It reads and
  writes `Log[i][j][k]` without needing to know how the base protocol implements it
  internally.

**What "the base protocol owns the 3-D log" means concretely:**
- Each base module declares a variable (or structured set of variables) that represents
  `Log[i][j][k]` — the per-replica, per-proposer, per-position log.
- The base protocol's transitions (propose, replicate, commit) update this 3-D structure
  directly. They may also maintain internal helper state (e.g., Raft's `nextIndex`,
  CoPilot's `matchIndex`, Mencius's slot arrays), but the Jetpack-facing composition
  boundary must expose the genuine 3-D log.
- `jetpack.tla` is INSTANCE'd with a mapping to this 3-D log variable. Jetpack's own
  actions (preaccept, recovery, execution) read and write the 3-D log directly.
- The wrapper/driver module does only wiring (`Init`, `Next`, `UNCHANGED`,
  `INSTANCE ... WITH ...`). It does not synthesize a missing log dimension.

**What is NOT acceptable (the projection/refinement shortcut):**
- Keeping a flat 2-D base log `log[i][k]` as the real base-protocol state.
- Adding projection/refinement operators in `jetpack.tla` (such as `Log3D`, `ProposerSlots`,
  `ProposerOfSlot`, `ProposerOfEntry`, `EntryProposer`, or any equivalent) to reconstruct
  a 3-D view from the flat log.
- Claiming that such a projection is "logically equivalent" to a true 3-D log and closing
  the abstraction step.
- Keeping the projection operators as "convenience helpers" while the real state is flat.
  The proof story must not depend on reconstructing `j` or local sequence position `k`
  from a flatter base log.

**What IS acceptable:**
- Thin wrapper wiring for `Init`, `Next`, `UNCHANGED`, or `INSTANCE ... WITH ...`.
- Unused logical sequences staying blank / `Nil` for protocols that do not use all
  sequences (e.g., Raft uses only one sequence).
- Protocol-specific internal transition logic inside the base module, as long as the
  exported Jetpack-facing log state is truly 3-D.
- The base module internally deriving its 3-D log from internal structures, as long as
  the 3-D log is maintained as real TLA+ state that Jetpack reads directly.

**Per-protocol requirements:**
- **Raft**: one active logical sequence (the leader's). All other sequences remain
  blank / `Nil`. Replicas still store the 3-D structure, even if only one logical
  sequence is live.
- **CoPilot**: two active logical sequences (pilot + copilot). Replicas still store
  the 3-D structure, even if only two logical sequences are live.
- **Mencius**: one logical sequence per server. Replicas store the full 3-D structure.

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

Important clarification:
- this 3-D log is **not** a derived view or projection for proofs
- it is the Jetpack-facing log structure that the base protocol must actually maintain
  as TLA+ state
- `jetpack.tla` should reason over this shared 3-D state directly
- if a base protocol keeps auxiliary flat / slot / local structures internally, that is fine,
  but the shared composition boundary with Jetpack must still expose the genuine 3-D log

### Raft interpretation

If the leader is server `0`:
- only sequence `j = 0` is active
- `Log[*][0][k]` matters
- `Log[*][1..n-1][k]` stays unused/blank

This models:
- one leader-owned sequence
- follower replicas storing copies of the leader sequence
- unused logical sequences still exist in the state but remain blank / `Nil`

### CoPilot interpretation

If Pilot is `0` and Copilot is `1`:
- only sequences `j = 0` and `j = 1` are active
- `Log[*][0][k]` and `Log[*][1][k]` matter
- `Log[*][2..n-1][k]` stays unused/blank

This models:
- two distinguished ordering sequences
- all replicas storing copies of those sequences
- unused logical sequences still exist in the state but remain blank / `Nil`

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

Large config for the accepted Jetpack/base composition runs:

```tla
CONSTANTS
  Server = {s1, s2, s3, s4, s5}
  Client = {c1}
  CmdId = {id1, id2, id3}
  Key = {k1, k2}
```

Do not reduce these constants for the accepted large run.
If a smaller config is useful while debugging, keep it clearly labeled as debug-only.

### Runtime policy

For each composed Jetpack/base combination:
- `jetpack.tla` + `base_raft.tla`
- `jetpack.tla` + `base_copilot.tla`
- `jetpack.tla` + `base_mencius.tla`

run exactly two accepted cases:
- first run the small config
- then run the large config above for a fixed 12-hour window

For the big run, "12 hours with no error" is the required acceptance bar for this phase.
Do not silently shorten the run window and do not reduce the constants.

Interpretation:
- "12 hours with no error" means "no bug found in the accepted bounded search window"
- it does not mean "formally proved"

### Log retention policy

Every run should save a log file.

The filename should include:
- timestamp at the **start** of the filename
- spec/protocol name
- config name or size marker

Example shape:
- `tla/log/2026-03-08_14-30-00_jetpack_mencius_small.log`
- `tla/log/2026-03-08_14-30-00_jetpack_mencius_large.log`

The reproducibility contract is:
- the runner command must be checked in
- the config files must be checked in
- the log filename policy must be automatic, not manual
- a fresh agent should be able to rerun the same model-checking workflow from scratch

Do not rely on unsaved terminal output for proof claims.

## What Counts As A Real Pass

A run only counts as passed if:
- TLC finishes without invariant violation
- there is no TLC exception
- the exact spec and config are recorded
- the log file is saved

A run does not count as passed if:
- it only has "no error yet" mid-run progress
- TLC crashes
- TLC reports invariant violation
- the run is partial but undocumented
- the result is later summarized in TODO without a corresponding saved log

## Current Repository Status (updated 2026-03-08)

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

### Step 3: Shared Jetpack abstraction with true 3-D base-protocol log — CODE DONE, VERIFICATION PENDING

**Current state (2026-03-08):** The 3-D log refactor is **code-complete**. All 7 TLA+ files
have been rewritten so the base protocol owns and maintains a genuine `log[i][j][k]` as TLA+
state. `jetpack.tla` consumes this directly with no projection operators.

What was done (commit `fcac8da1`):
- **`jetpack.tla`**: Removed all projection operators (`Log3D`, `ProposerSlots`,
  `EntryProposer`, `ProposerCmdSeq`, `Log3DLen`). Replaced `ProposerOfEntry(_, _)`
  with `ProposerOf(_)`. All invariants now quantify directly over `log[i][j][k]`.
  `ApplyCommitted` moved to wrappers (execution order is protocol-specific).
- **`base_raft.tla`**: `log[i]["sole"][k]`, `commitIndex[i]["sole"]`.
- **`base_copilot.tla`**: `log[i][proposer][k]`, `commitIndex[i][proposer]`.
  Added `mseqnum` to CoPilot messages for per-proposer sequence tracking.
- **`base_mencius.tla`**: `log[i][j][k]`, `commitIndex[i][j]`. Rewrote `ExtendLog` →
  `ExtendLogForProposer` with `SlotFor(j, k)` slot-to-position mapping.
- **Wrappers** (`jetpack_raft.tla`, `jetpack_copilot.tla`, `jetpack_mencius.tla`):
  Only wiring (`Proposer`, `ProposerOf`, `NoOpCmd` via INSTANCE). Each provides
  protocol-specific `ApplyCommitted` with correct execution ordering.

What remains:
- All three Jetpack/base combinations must be re-verified with the 3-D redesign:
  one small run and one 12-hour large run per combination.
- The TLA+ experiment trail must be reproducible from scratch via checked-in runner/docs.
  (Runner script updated: `tla/run-tlc.sh` now saves timestamp-prefixed logs automatically.)

See TODO.md Phase 2I for the detailed task breakdown.

### Resolved issues from 2026-03-02 review (historical)
1. `base_raft.tla`, `base_copilot.tla`, `base_mencius.tla` — all created and active
2. Property definitions — rewritten to match intended proof story
3. Mencius wrapper violations — fixed (ExtendLog, NoOp filtering, committed-prefix scoping)
4. TLC log retention — timestamped logs saved for every proof claim

### Resolved from 2026-03-08 review
1. **3-D log ownership** — RESOLVED. All base protocols now maintain genuine 3-D log state
   (`log[i][j][k]`, `commitIndex[i][j]`). No projection operators remain.
2. **Invariant formulation** — RESOLVED. All invariants quantify directly over the genuine
   3-D log variable. No intermediate projection.

### Unresolved from 2026-03-08 review
1. **12-hour large runs** — all three combinations need re-verification after the 3-D redesign.
2. **Reproducibility** — runner script updated with timestamp-prefixed logs; Docker environment
   required for TLC execution. Full end-to-end verification pending.

## Practical Guidance For Maintenance

Anti-overclaim rules (still apply):
- Do not mark a spec "passed" if the saved log shows an invariant violation.
- Do not mark Step 3 complete just because wrapper modules exist.
- Do not claim abstraction success until the same `jetpack.tla` is reused with all
  abstracted base protocol modules **and** the 3-D log is maintained as real base-protocol
  state (not projected from a flat log).
- A partial run with no error is "high confidence", not a formal proof.
- **Do not close Step 3 by restating the current projection-based design in different
  words.** The base protocol must own and maintain the 3-D log as TLA+ state. Any
  approach that keeps `log[i][k]` flat and reconstructs `j` or local `k` in Jetpack
  is a projection, regardless of how it is described.
