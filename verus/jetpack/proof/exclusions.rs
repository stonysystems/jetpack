//! The two schedules of the recovery audit (JETPACK-001, JETPACK-002) are unreachable (not
//! trusted): `PrepareOkFreezes` from the invariant, `AcksOnlyWhenNormal` by inspecting what
//! each action sends, `StaleFinishRecoveryKeepsRecovery` from `learn`.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::defs::*;
use crate::proof::frame::*;
use crate::proof::inductive::*;
use crate::proof::replica_lemmas::*;
use vstd::prelude::*;

verus! {

pub proof fn lemma_prepare_ok_freezes(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        PrepareOkFreezes(cfg, s),
{
    assert forall|p: Packet| #[trigger] s.network.contains(p) && p.msg is PrepareOK && p.src is Replica && cfg.replicas.contains(p.src->Replica_id) implies {
        let st = s.replicas[p.src->Replica_id];
        &&& st.nv > p.msg->PrepareOK_vn
        &&& !(st.mode is Normal && st.lnv == p.msg->PrepareOK_vn)
    } by {
        let r = p.src->Replica_id;
        assert(msg_ok(cfg, s, p));
        assert(poks_ok(cfg, s, r));
        assert(pok_ok(cfg, s, r, p.msg->PrepareOK_view, p.msg->PrepareOK_vn, p.msg->PrepareOK_k, p.msg->PrepareOK_body));
        assert(replica_wf(cfg, s, r));
    }
}

/// What a replica action sends: a FastAck only from N12-N16, while Normal in the view it acks.
pub proof fn lemma_replica_sends_ack(c: ReplicaConsts, st: ReplicaState, st_: ReplicaState, step: ReplicaStep, sent: Set<Packet>, p: Packet)
    requires
        ReplicaNext(c, st, st_, step, sent),
        sent.contains(p),
        p.msg is FastAck,
    ensures
        p.src == me(c),
        st.mode is Normal,
        st.lnv == p.msg->FastAck_view,
{
    match step {
        ReplicaStep::RecvFastCmd { pkt } => {
            let v = pkt.msg->FastCmd_view;
            let cmd = pkt.msg->FastCmd_cmd;
            if v == st.lnv && st.mode is Normal && no_conflict(c, cmd, st.pool.union(pending_cmds(st))) {
                lemma_send_to_msgs(c, pkt.src, Msg::FastAck { view: v, cmd: cmd });
            } else if v != st.lnv || st.mode is Recovery {
                lemma_send_to_msgs(c, pkt.src, Msg::FastNack { lnv: st.lnv, mode: st.mode });
            }
        },
        ReplicaStep::ObserveCommitted { cmd } => {
            lemma_broadcast_msgs(c, Msg::Evict { cmd: cmd });
        },
        ReplicaStep::RecvEvict { pkt } => {},
        ReplicaStep::RecvBeginRecovery { pkt } => {
            let v = pkt.msg->BeginRecovery_view;
            if v >= st.nv && v > st.lnv {
                lemma_send_to_msgs(c, pkt.src, Msg::BeginRecoveryOK { view: v, lnv: st.lnv });
            } else {
                lemma_send_to_msgs(c, pkt.src, Msg::Nack { new_view: st.nv, lnv: st.lnv, k: None });
            }
        },
        ReplicaStep::RecvPrepare { pkt } => {
            let v = pkt.msg->Prepare_view;
            let vn = pkt.msg->Prepare_vn;
            let k = pkt.msg->Prepare_k;
            let s1 = learn(st, vn);
            if stale(s1, v, vn) {
                lemma_send_to_msgs(c, pkt.src, Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None });
            } else {
                let s2 = join_if_newer(s1, v);
                if k > msb_of(s2, vn) {
                    let body = if s2.accepted.contains_key(vn) {
                        PrepareOkBody::Accepted { acc: s2.accepted[vn] }
                    } else {
                        PrepareOkBody::Pool { pool: pool_of(s2, vn) }
                    };
                    lemma_send_to_msgs(c, pkt.src, Msg::PrepareOK { view: v, vn: vn, k: k, body: body });
                } else {
                    lemma_send_to_msgs(c, pkt.src, Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) });
                }
            }
        },
        ReplicaStep::RecvAccept { pkt } => {
            let v = pkt.msg->Accept_view;
            let vn = pkt.msg->Accept_vn;
            let k = pkt.msg->Accept_k;
            let s1 = learn(st, vn);
            if stale(s1, v, vn) {
                lemma_send_to_msgs(c, pkt.src, Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None });
            } else {
                let s2 = join_if_newer(s1, v);
                if k >= msb_of(s2, vn) {
                    lemma_send_to_msgs(c, pkt.src, Msg::AcceptOK { view: v, vn: vn, k: k });
                } else {
                    lemma_send_to_msgs(c, pkt.src, Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) });
                }
            }
        },
        ReplicaStep::RecvFinishRecovery { pkt } => {
            lemma_send_to_msgs(c, pkt.src, Msg::FinishRecoveryOK { view: pkt.msg->FinishRecovery_view });
        },
        ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn } => {
            lemma_broadcast_msgs(c, Msg::Prepare { view: st.coord.view, vn: vn, k: st.coord.k });
        },
        ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset } => {
            lemma_broadcast_msgs(c, Msg::Accept { view: st.coord.view, vn: st.coord.vn, k: st.coord.k, rset: rset });
        },
        ReplicaStep::CoordAcceptOK { pkts, m } => {},
        ReplicaStep::CoordFinish => {
            lemma_broadcast_msgs(c, Msg::FinishRecovery { view: st.coord.view, vn: st.coord.vn, rset: st.coord.rset });
        },
        ReplicaStep::CoordNack { pkt } => {
            let nv_ = pkt.msg->Nack_new_view;
            let lnv_ = pkt.msg->Nack_lnv;
            let k_ = pkt.msg->Nack_k;
            if nv_ > st.coord.view || lnv_ >= st.coord.view {
            } else if lnv_ > st.coord.vn {
                lemma_broadcast_msgs(c, Msg::Prepare { view: st.coord.view, vn: lnv_, k: st.coord.k });
            } else if k_ is Some && k_->Some_0 >= st.coord.k {
                lemma_broadcast_msgs(c, Msg::Prepare { view: st.coord.view, vn: st.coord.vn, k: k_->Some_0 + 1 });
            }
        },
    }
}

pub proof fn lemma_acks_only_when_normal(cfg: Config, s: SystemState, s_: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
        Next(cfg, s, s_),
    ensures
        AcksOnlyWhenNormal(cfg, s, s_),
{
    let step = choose|step: SysStep| #[trigger] NextStep(cfg, s, s_, step);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.msg is FastAck implies {
        &&& p.src is Replica
        &&& cfg.replicas.contains(p.src->Replica_id)
        &&& s.replicas[p.src->Replica_id].mode is Normal
        &&& s.replicas[p.src->Replica_id].lnv == p.msg->FastAck_view
    } by {
        match step {
            SysStep::Replica { r, step, sent } => {
                lemma_replica_step_frame(cfg, s, s_, r, step, sent);
                assert(sent.contains(p));
                lemma_replica_sends_ack(replica_consts(cfg, r), s.replicas[r], s_.replicas[r], step, sent, p);
            },
            SysStep::Client { k, step, sent } => {
                lemma_client_step_frame(cfg, s, s_, k, step, sent);
                assert(sent.contains(p));
                match step {
                    ClientStep::SendFastCmd { cmd } => {
                        let c = client_consts(cfg, k);
                        lemma_to_replicas_contains(cfg.replicas, client_addr(c), Msg::FastCmd { view: s.clients[k].view, cmd: cmd }, p);
                        assert(false);
                    },
                    _ => {
                        assert(false);
                    },
                }
            },
            SysStep::NewView { v } => {
                let c = replica_consts(cfg, (cfg.proposer)(v));
                lemma_broadcast_msgs(c, Msg::BeginRecovery { view: v });
                assert(broadcast(c, Msg::BeginRecovery { view: v }).contains(p));
                assert(false);
            },
            _ => {
                assert(s_.network == s.network);
                assert(false);
            },
        }
    }
}

pub proof fn lemma_stale_finish_keeps_recovery(cfg: Config, s: SystemState, s_: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        StaleFinishRecoveryKeepsRecovery(cfg, s, s_),
{
    assert forall|r: int, pkt: Packet, sent: Set<Packet>|
        cfg.replicas.contains(r) && #[trigger] ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvFinishRecovery { pkt }, sent)
        && s.replicas[r].mode is Recovery && pkt.msg->FinishRecovery_view < s.replicas[r].nv
        implies s_.replicas[r].mode is Recovery && s_.replicas[r].nv == s.replicas[r].nv by {
        let st = s.replicas[r];
        let v = pkt.msg->FinishRecovery_view;
        assert(RecvFinishRecovery(replica_consts(cfg, r), st, s_.replicas[r], pkt, sent));
        assert(s_.replicas[r] == learn(st, v));
        lemma_learn_facts(st, v);
        assert(replica_wf(cfg, s, r));
    }
}

// ---------------------------------------------------------------------------------------------
// On every behavior
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_exclusions_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] PrepareOkFreezes(cfg, b[i]),
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] AcksOnlyWhenNormal(cfg, b[i], b[i + 1]),
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] StaleFinishRecoveryKeepsRecovery(cfg, b[i], b[i + 1]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] PrepareOkFreezes(cfg, b[i]) by {
        lemma_prepare_ok_freezes(cfg, b[i]);
    }
    assert forall|i: int| 0 <= i < b.len() - 1 implies #[trigger] AcksOnlyWhenNormal(cfg, b[i], b[i + 1]) by {
        lemma_behavior_step(cfg, b, i);
        lemma_acks_only_when_normal(cfg, b[i], b[i + 1]);
    }
    assert forall|i: int| 0 <= i < b.len() - 1 implies #[trigger] StaleFinishRecoveryKeepsRecovery(cfg, b[i], b[i + 1]) by {
        lemma_stale_finish_keeps_recovery(cfg, b[i], b[i + 1]);
    }
}

} // verus!
