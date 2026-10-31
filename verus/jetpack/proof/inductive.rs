//! The induction (not trusted): every branch of `Next` preserves `inv`, so `inv` holds in every
//! state of a valid behavior; and every step keeps the pseudocode §0's step invariants on views and pools.
use crate::common::trace::*;
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::defs::*;
use crate::proof::init::*;
use crate::proof::replica_lemmas::*;
use crate::proof::step_base::*;
use crate::proof::step_client::*;
use crate::proof::step_coord::*;
use crate::proof::step_fast::*;
use crate::proof::step_rec::*;
use vstd::prelude::*;

verus! {

/// A replica step: one lemma per action of `ReplicaNext`.
pub proof fn lemma_replica_step_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, step: ReplicaStep, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, step, sent),
    ensures
        inv(cfg, s_),
{
    match step {
        ReplicaStep::RecvFastCmd { pkt } => lemma_recv_fast_cmd_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::ObserveCommitted { cmd } => lemma_observe_committed_inv(cfg, s, s_, r, cmd, sent),
        ReplicaStep::RecvEvict { pkt } => lemma_recv_evict_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::RecvBeginRecovery { pkt } => lemma_recv_begin_recovery_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::RecvPrepare { pkt } => lemma_recv_prepare_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::RecvAccept { pkt } => lemma_recv_accept_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::RecvFinishRecovery { pkt } => lemma_recv_finish_recovery_inv(cfg, s, s_, r, pkt, sent),
        ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn } => lemma_coord_begin_ok_inv(cfg, s, s_, r, pkts, m, lnvs, vn, sent),
        ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset } => lemma_coord_prepare_ok_inv(cfg, s, s_, r, pkts, m, bodies, rule, rset, sent),
        ReplicaStep::CoordAcceptOK { pkts, m } => lemma_coord_accept_ok_inv(cfg, s, s_, r, pkts, m, sent),
        ReplicaStep::CoordFinish => lemma_coord_finish_inv(cfg, s, s_, r, sent),
        ReplicaStep::CoordNack { pkt } => lemma_coord_nack_inv(cfg, s, s_, r, pkt, sent),
    }
}

/// Every branch of `Next`.
pub proof fn lemma_next_inv(cfg: Config, s: SystemState, s_: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
        Next(cfg, s, s_),
    ensures
        inv(cfg, s_),
{
    let step = choose|step: SysStep| #[trigger] NextStep(cfg, s, s_, step);
    match step {
        SysStep::Replica { r, step, sent } => lemma_replica_step_inv(cfg, s, s_, r, step, sent),
        SysStep::Client { k, step, sent } => lemma_client_step_inv(cfg, s, s_, k, step, sent),
        SysStep::NewView { v } => lemma_new_view_inv(cfg, s, s_, v),
        SysStep::AppendCmd { cmd } => lemma_append_cmd_inv(cfg, s, s_, cmd),
        SysStep::Replicate { r, m } => lemma_replicate_inv(cfg, s, s_, r, m),
        SysStep::AdvanceCommit { m } => lemma_advance_commit_inv(cfg, s, s_, m),
        SysStep::ReplicaCommit { r, m } => lemma_replica_commit_inv(cfg, s, s_, r, m),
    }
}

/// `inv` holds in every state of a valid behavior.
pub proof fn lemma_behavior_inv(cfg: Config, b: Seq<SystemState>)
    requires
        wf(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] inv(cfg, b[i]),
{
    let init = |s: SystemState| Init(cfg, s);
    let next = |s: SystemState, s_: SystemState| Next(cfg, s, s_);
    let invp = |s: SystemState| inv(cfg, s);
    assert forall|s: SystemState| init(s) implies #[trigger] invp(s) by {
        lemma_init_inv(cfg, s);
    }
    assert forall|s: SystemState, s_: SystemState| invp(s) && #[trigger] next(s, s_) implies invp(s_) by {
        lemma_next_inv(cfg, s, s_);
    }
    lemma_invariant_holds_on_behavior(init, next, invp, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] inv(cfg, b[i]) by {
        assert(invp(b[i]));
    }
}

/// Between two adjacent states of a valid behavior there is one `Next` step.
pub proof fn lemma_behavior_step(cfg: Config, b: Seq<SystemState>, i: int)
    requires
        IsValidBehavior(cfg, b),
        0 <= i < b.len() - 1,
    ensures
        Next(cfg, b[i], b[i + 1]),
{
    let next = |s: SystemState, s_: SystemState| Next(cfg, s, s_);
    assert(next(b[i], b[i + 1]));
}

// ---------------------------------------------------------------------------------------------
// the pseudocode §0's step invariants: views never decrease, the pool changes only while Normal
// ---------------------------------------------------------------------------------------------

/// One replica action: its views do not decrease, and its pool changes only while it is Normal
/// or when its last normal view advances (learn empties the pool of the new view).
pub proof fn lemma_replica_next_views(c: ReplicaConsts, st: ReplicaState, st_: ReplicaState, step: ReplicaStep, sent: Set<Packet>)
    requires
        ReplicaNext(c, st, st_, step, sent),
    ensures
        st_.lnv >= st.lnv,
        st_.nv >= st.nv,
        st_.pool != st.pool ==> st.mode is Normal || st_.lnv > st.lnv,
{
    match step {
        ReplicaStep::RecvFastCmd { pkt } => {},
        ReplicaStep::ObserveCommitted { cmd } => {},
        ReplicaStep::RecvEvict { pkt } => {},
        ReplicaStep::RecvBeginRecovery { pkt } => {
            let v = pkt.msg->BeginRecovery_view;
            if v >= st.nv && v > st.lnv && v > st.nv {
                lemma_join_facts(st, v);
            }
        },
        ReplicaStep::RecvPrepare { pkt } => {
            let v = pkt.msg->Prepare_view;
            let vn = pkt.msg->Prepare_vn;
            let s1 = learn(st, vn);
            lemma_learn_facts(st, vn);
            if !stale(s1, v, vn) {
                if v > s1.nv {
                    lemma_join_facts(s1, v);
                }
            }
        },
        ReplicaStep::RecvAccept { pkt } => {
            let v = pkt.msg->Accept_view;
            let vn = pkt.msg->Accept_vn;
            let s1 = learn(st, vn);
            lemma_learn_facts(st, vn);
            if !stale(s1, v, vn) {
                if v > s1.nv {
                    lemma_join_facts(s1, v);
                }
            }
        },
        ReplicaStep::RecvFinishRecovery { pkt } => {
            lemma_learn_facts(st, pkt.msg->FinishRecovery_view);
        },
        ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn } => {
            lemma_learn_facts(st, vn);
        },
        ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset } => {},
        ReplicaStep::CoordAcceptOK { pkts, m } => {},
        ReplicaStep::CoordFinish => {},
        ReplicaStep::CoordNack { pkt } => {
            lemma_learn_facts(st, pkt.msg->Nack_lnv);
        },
    }
}

/// Every branch of `Next` keeps the step invariants of every replica.
pub proof fn lemma_next_step_invariants(cfg: Config, s: SystemState, s_: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
        Next(cfg, s, s_),
    ensures
        ReplicaStepInvariants(cfg, s, s_),
{
    let step = choose|step: SysStep| #[trigger] NextStep(cfg, s, s_, step);
    match step {
        SysStep::Replica { r, step, sent } => {
            lemma_replica_next_views(replica_consts(cfg, r), s.replicas[r], s_.replicas[r], step, sent);
            assert forall|q: int| #[trigger] cfg.replicas.contains(q) && q != r implies s_.replicas[q] == s.replicas[q] by {}
        },
        SysStep::Client { k, step, sent } => {
            assert(s_.replicas == s.replicas);
        },
        SysStep::NewView { v } => {
            let p = (cfg.proposer)(v);
            assert forall|q: int| #[trigger] cfg.replicas.contains(q) && q != p implies s_.replicas[q] == s.replicas[q] by {}
        },
        SysStep::AppendCmd { cmd } => {
            assert(s_.replicas == s.replicas);
        },
        SysStep::Replicate { r, m } => {
            assert forall|q: int| #[trigger] cfg.replicas.contains(q) && q != r implies s_.replicas[q] == s.replicas[q] by {}
        },
        SysStep::AdvanceCommit { m } => {
            assert(s_.replicas == s.replicas);
        },
        SysStep::ReplicaCommit { r, m } => {
            assert forall|q: int| #[trigger] cfg.replicas.contains(q) && q != r implies s_.replicas[q] == s.replicas[q] by {}
        },
    }
}

} // verus!
