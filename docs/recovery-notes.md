# Notes on the recovery protocol: the paper, pseudocode, the models and the code

Last updated 2026-10-31.

## What the paper states and what the figure abbreviates

The OSDI '26 paper states two requirements on recovery in its text:

- Appendix B.1: BeginRecovery freezes the fast path "so that no fast path can succeed during
  recovery".
- §3.3: every message carries the sender's view "so receivers can detect stale operations".

The pseudocode figure in the appendix (Figure 14) is an abbreviation of the protocol and does
not spell out two of the conditions those requirements need:

1. A replica must have joined the new view (and so stopped acknowledging in the old one)
   before it reports its pool in a Prepare reply. Otherwise a replica that missed
   BeginRecovery can report an empty pool and acknowledge the command afterwards.
2. A FinishRecovery message must be applied only for the view the replica has joined, with
   views numbered by the original protocol. Otherwise a FinishRecovery left over from an
   earlier recovery can return a replica to normal mode in the middle of a later one.

[`pseudocode.md`](pseudocode.md) makes both explicit: L14 joins the new view before
the PrepareOK is sent (and the pool of a view is frozen once the replica has joined a newer
one, §0 invariant); `learn` (§0) applies a FinishRecovery only when its view is at least the
replica's new view, and the view ids are the original protocol's (term and config index in
Raft). The full list of places where the pseudocode supplies detail the paper leaves out is the pseudocode §5.

## The formal models

- `tla/jetpack.tla` and the Raft composition `tla/jetpack_raft_composition.tla` are written
  from the pseudocode line by line (the line tags are in the comments). The checked properties include
  `RecoveredAgreement` (one recovery set per recovered view), `FastCommitDurability` (a
  fast-committed command is in every Recovered entry of its view or already committed),
  `Principle2Raft` and the §0 replica invariants. See `tla/README.md` for the configurations
  that were checked and their results.
- `verus/jetpack/` is a Verus model of the pseudocode's three-phase recovery over an abstract
  original protocol (single proposer, fixed membership) with machine-checked proofs of the
  replica invariants, RecoveredAgreement, FastCommitDurability, Principle 2, and of the fact
  that the two schedules above are unreachable. See `verus/README.md`.

## History of the TLA+ and the implementation on this branch

- The TLA+ before 2026-10-02 (up to commit c03e318) applied FinishRecovery unconditionally
  and kept the same recovery epoch across election-triggered recoveries. The 2026-10-02
  revision ("model per-round views in Jetpack recovery") gave every recovery its own epoch
  and gated FinishRecovery on it. The the pseudocode rewrite replaces per-round epochs with the original
  protocol's view ids and adds the durability property to the checked invariants.
- The implementation's merged recovery RPC (`OnJetpackPullRecovery`) has always entered
  recovery mode before reading the command pool, which is condition 1. Condition 2 is the
  `FinishAllowed` rule of `src/deptran/jetpack_rules.h` (a FinishRecovery installs view u
  only if u is at least the newest joined view and above the installed one), with views
  numbered by the backend's terms.
