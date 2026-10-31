//! The theorems this crate states (trusted): statements use only `model/` and `common/`; bodies
//! only call lemmas in `proof/`. Each theorem is over every state (or every step) of every valid
//! behavior of a well-formed configuration.
use crate::model::client::FastCommit;
use crate::model::properties::{
    committed_cmd, fast_committed, AcksOnlyWhenNormal, ClientFastCommitDurability, FastCommitDurability,
    PrepareOkFreezes, Principle2, RecoveredAgreement, ReplicaInvariants, ReplicaStepInvariants,
    StaleFinishRecoveryKeepsRecovery, WellFormed,
};
use crate::model::system::{IsValidBehavior, SystemState};
use crate::model::types::{v0, Config};
use crate::proof::exclusions::lemma_exclusions_behavior;
use crate::proof::props::{
    lemma_fast_commit_durability_behavior, lemma_principle2_behavior, lemma_recovered_agreement_behavior,
    lemma_replica_invariants_behavior, lemma_replica_step_invariants_behavior,
};
use crate::witness::steps::{cfg3, lemma_cfg3};
use crate::witness::w_fast::lemma_w1_behavior;
use crate::witness::w_recovery::lemma_w2_behavior;
use vstd::prelude::*;

verus! {

/// 1a. the pseudocode §0 "Invariants on every Jetpack replica R": R.last_normal_view <= R.new_view and
/// R.mode = Recovery <==> R.new_view > R.last_normal_view, in every state.
pub proof fn theorem_replica_invariants(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] ReplicaInvariants(cfg, b[i]),
{
    lemma_replica_invariants_behavior(cfg, b);
}

/// 1b. the pseudocode §0: neither view ever decreases, and the pool changes only while R is Normal (once
/// R.new_view > R.last_normal_view = w, pool[w] is frozen), over every step.
pub proof fn theorem_replica_step_invariants(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] ReplicaStepInvariants(cfg, b[i], b[i + 1]),
{
    lemma_replica_step_invariants_behavior(cfg, b);
}

/// 2. RecoveredAgreement: any two Recovered entries, in any replicas' logs, that recover the
/// same fast-path view carry the same set (the recovery Paxos of L10-L47 with ballots (view, k)).
pub proof fn theorem_recovered_agreement(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] RecoveredAgreement(cfg, b[i]),
{
    lemma_recovered_agreement_behavior(cfg, b);
}

/// 3. FastCommitDurability (paper C1 Case 3 with the GC rule): if c was fast-committed in view
/// w (a superquorum containing every proposer of w ack'd it in w) then every Recovered entry
/// that recovers w contains c, or c is in the committed prefix of some replica's log. Also for
/// the fast commits the clients decided (N2-N5).
pub proof fn theorem_fast_commit_durability(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] FastCommitDurability(cfg, b[i]),
        forall|i: int| 0 <= i < b.len() ==> #[trigger] ClientFastCommitDurability(cfg, b[i]),
{
    lemma_fast_commit_durability_behavior(cfg, b);
}

/// 4. Principle 2 as a log property (T2): in every replica's copy of the original log, the first
/// entry of every view other than v_0 is a Recovered entry.
pub proof fn theorem_principle2(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] Principle2(cfg, b[i]),
{
    lemma_principle2_behavior(cfg, b);
}

/// 5. The two schedules of the recovery audit are unreachable. JETPACK-001 (a replica that never
/// froze answers a Prepare, then acks): every PrepareOK for w comes from a replica whose
/// new_view is above w (L14), and a FastAck in w is sent only while Normal with last normal
/// view w (N12). JETPACK-002 (a stale FinishRecovery unfreezes a replica that joined a newer
/// view): learn's second branch keeps the replica in Recovery in its newer view.
pub proof fn theorem_audit_schedules_excluded(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] PrepareOkFreezes(cfg, b[i]),
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] AcksOnlyWhenNormal(cfg, b[i], b[i + 1]),
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] StaleFinishRecoveryKeepsRecovery(cfg, b[i], b[i + 1]),
{
    lemma_exclusions_behavior(cfg, b);
}

// ---------------------------------------------------------------------------------------------
// Reachability witnesses: the theorems above are not vacuous
// ---------------------------------------------------------------------------------------------

/// W1. A valid behavior of a well-formed configuration with three replicas and one client in
/// which command 7 is fast-committed in v_0 (N1-N5, N12-N16): `fast_committed` holds and the
/// client recorded it.
pub proof fn theorem_witness_fast_commit()
    ensures
        exists|cfg: Config, b: Seq<SystemState>| #[trigger] IsValidBehavior(cfg, b)
            && WellFormed(cfg)
            && cfg.replicas.len() == 3
            && cfg.clients.len() == 1
            && fast_committed(cfg, b.last(), v0(), 7)
            && b.last().clients[0].fast.contains(FastCommit { view: v0(), cmd: 7 }),
{
    lemma_cfg3();
    let tr = lemma_w1_behavior();
    assert(IsValidBehavior(cfg3(), tr));
}

/// W2. A valid behavior that continues W1 (its state 5 is W1's last state, with the fast commit)
/// by NewView(1) and a full recovery (L1-L48, L51-L54): at the end replica 0 is Normal in view
/// 1 and a Recovered entry for v_0 containing 7 is in its committed prefix, so the conclusion of
/// FastCommitDurability holds by both disjuncts: 7 is in the recovered set and committed.
pub proof fn theorem_witness_recovery()
    ensures
        exists|cfg: Config, b: Seq<SystemState>| #[trigger] IsValidBehavior(cfg, b)
            && WellFormed(cfg)
            && cfg.replicas.len() == 3
            && cfg.clients.len() == 1
            && b.len() == 26
            && fast_committed(cfg, b[5], v0(), 7)
            && b[5].clients[0].fast.contains(FastCommit { view: v0(), cmd: 7 })
            && fast_committed(cfg, b.last(), v0(), 7)
            && b.last().replicas[0].mode is Normal
            && b.last().replicas[0].lnv == 1
            && b.last().replicas[0].nv == 1
            && b.last().replicas[0].committed == 1
            && b.last().replicas[0].olog.len() == 1
            && b.last().replicas[0].olog[0] is Recovered
            && b.last().replicas[0].olog[0]->Recovered_vn == v0()
            && b.last().replicas[0].olog[0]->Recovered_cmds.contains(7)
            && committed_cmd(cfg, b.last(), 7),
{
    lemma_cfg3();
    let tr = lemma_w2_behavior();
    assert(IsValidBehavior(cfg3(), tr));
}

} // verus!
