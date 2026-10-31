# Verus model and proofs

`jetpack/` is a Verus specification of the Jetpack shim as written in
[`docs/pseudocode.md`](../docs/pseudocode.md) (three-phase recovery, §1 N1–N25, §2 T1–T2 and
L1–L54), over an abstract original protocol, with machine-checked proofs of its safety
properties. `common/` holds the shared set and quorum lemmas it uses.

Scope of the model: one proposer per view, a fixed replica set (no reconfiguration), the
original protocol as a contract (one log, per-replica prefix copies, committed prefixes agree
and never shrink; a proposer appends only when the pseudocode's T2 allows it), no return
values. `jetpack/FIDELITY.md` maps every pseudocode line to the spec function that implements
it; `jetpack/DECISIONS.md` records every modeling choice (DR-1 … DR-18) with the pseudocode
line it comes from; `jetpack/PROGRESS.md` is the status log.

Theorems (`jetpack/top.rs`), each over every state or step of every valid behavior:

1. the pseudocode's §0 replica invariants (`last_normal_view ≤ new_view`;
   `Recovery ⟺ new_view > last_normal_view`), views never decrease, a view's pool is frozen
   once the replica joined a newer view;
2. `RecoveredAgreement`: all Recovered entries for one recovered view carry the same set;
3. `FastCommitDurability`: a command fast-committed in view w is in every Recovered entry
   for w, or is already committed on the original path (paper C1, Case 3, with the GC rule);
4. `Principle2`: the first entry of every view after the initial one is a Recovered entry;
5. the two schedules of the recovery audit (a replica that never froze answering Prepare; a
   stale FinishRecovery unfreezing a replica) are unreachable;
6. two witnesses showing the statements are not vacuous: a behavior that fast-commits a
   command, and one that continues it through a view change and a full recovery in which
   the Recovered entry carries the command and is committed.

Verify (Verus 0.2026.08.02.b677dd5, Rust 1.97.1; `~/.cargo/bin` on `PATH`):

```bash
~/verus/verus --crate-type=lib --no-cheating verus/jetpack/lib.rs
# verification results:: 147 verified, 0 errors
```

The proofs use no `assume`, `admit` or `external_body`. The recorded run is in
`jetpack/results/checks/`.
