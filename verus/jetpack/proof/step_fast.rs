//! §1 normal path, replica side (not trusted): N12-N18 (`RecvFastCmd`), N21-N23
//! (`ObserveCommitted`), N24 (`RecvEvict`) preserve `inv`.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use crate::proof::frame::*;
use crate::proof::keep::*;
use crate::proof::mono::*;
use crate::proof::replica_lemmas::*;
use vstd::prelude::*;

verus! {

/// A step that appends nothing leaves the log as it was.
pub proof fn lemma_log_same(cfg: Config, s: SystemState, s_: SystemState, r: int, step: ReplicaStep)
    requires
        s_.log == s.log + step_appends(cfg, s, r, step),
        step_appends(cfg, s, r, step) == Seq::<Entry>::empty(),
    ensures
        s_.log == s.log,
{
    assert(s_.log =~= s.log);
}

/// N12-N18.
pub proof fn lemma_recv_fast_cmd_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvFastCmd { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvFastCmd { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvFastCmd(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(replica_wf(cfg, s, r));
    let v = pkt.msg->FastCmd_view;
    let cmd = pkt.msg->FastCmd_cmd;
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    if v == st.lnv && st.mode is Normal && no_conflict(c, cmd, st.pool.union(pending_cmds(st))) {
        // N14-N16
        assert(st_ == ReplicaState { pool: st.pool.insert(cmd), ..st });
        let ack = Msg::FastAck { view: v, cmd: cmd };
        assert(sent == send_to(c, pkt.src, ack));
        lemma_send_to_msgs(c, pkt.src, ack);
        assert(replica_mono(st, st_)) by {
            lemma_replica_mono_refl(st);
            assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
                assert(promise_of(st_, w) == promise_of(st, w));
            }
        }
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: ack }));
        }
        lemma_replica_wf_keep(cfg, s, s_, r);
        lemma_coord_ok_keep(cfg, s, s_, r);
        lemma_accepted_ok_keep(cfg, s, s_, r);
        // acks_ok: old acks keep their command (the pool grew); the new ack's command is in it
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is FastAck implies {
            &&& st_.lnv >= p.msg->FastAck_view
            &&& (st_.lnv == p.msg->FastAck_view ==> st_.pool.contains(p.msg->FastAck_cmd) || committed_cmd(cfg, s_, p.msg->FastAck_cmd))
        } by {
            if s.network.contains(p) {
                assert(acks_ok(cfg, s, r));
                if st.lnv == p.msg->FastAck_view && !st.pool.contains(p.msg->FastAck_cmd) {
                    lemma_committed_cmd_mono(cfg, s, s_, p.msg->FastAck_cmd);
                }
            } else {
                assert(p == (Packet { src: me(c), dst: pkt.src, msg: ack }));
            }
        }
        lemma_poks_ok_keep(cfg, s, s_, r);
    } else if v != st.lnv || st.mode is Recovery {
        // N17-N18
        assert(st_ == st);
        let nack = Msg::FastNack { lnv: st.lnv, mode: st.mode };
        assert(sent == send_to(c, pkt.src, nack));
        lemma_send_to_msgs(c, pkt.src, nack);
        lemma_replica_mono_refl(st);
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: nack }));
        }
        lemma_preds_unchanged(cfg, s, s_, r);
    } else {
        assert(st_ == st);
        assert(sent == Set::<Packet>::empty());
        lemma_replica_mono_refl(st);
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
        }
        lemma_preds_unchanged(cfg, s, s_, r);
    }
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// N21-N23.
pub proof fn lemma_observe_committed_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, cmd: int, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::ObserveCommitted { cmd }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::ObserveCommitted { cmd };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(ObserveCommitted(c, st, st_, cmd, sent));
    assert(replica_wf(cfg, s, r));
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    // the command is committed on the original path
    let j = choose|j: int| 0 <= j < st.committed && #[trigger] entry_cmds(st.olog[j]).contains(cmd);
    assert(committed_cmd(cfg, s, cmd));
    assert(replica_mono(st, st_)) by {
        lemma_replica_mono_refl(st);
        assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
            assert(promise_of(st_, w) == promise_of(st, w));
        }
    }
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    lemma_committed_cmd_mono(cfg, s, s_, cmd);
    let ev = Msg::Evict { cmd: cmd };
    assert(sent == broadcast(c, ev));
    lemma_broadcast_msgs(c, ev);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p.msg == ev && p.src == me(c));
    }
    lemma_replica_wf_keep(cfg, s, s_, r);
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    assert forall|c2: int| #[trigger] st.pool.contains(c2) implies st_.pool.contains(c2) || committed_cmd(cfg, s_, c2) by {
        if c2 != cmd {
            assert(st_.pool.contains(c2));
        }
    }
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// N24.
pub proof fn lemma_recv_evict_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvEvict { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvEvict { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvEvict(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    let cmd = pkt.msg->Evict_cmd;
    assert(committed_cmd(cfg, s, cmd));
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    assert(replica_mono(st, st_)) by {
        lemma_replica_mono_refl(st);
        assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
            assert(promise_of(st_, w) == promise_of(st, w));
        }
    }
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    lemma_committed_cmd_mono(cfg, s, s_, cmd);
    assert(sent == Set::<Packet>::empty());
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
    }
    lemma_replica_wf_keep(cfg, s, s_, r);
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    assert forall|c2: int| #[trigger] st.pool.contains(c2) implies st_.pool.contains(c2) || committed_cmd(cfg, s_, c2) by {
        if c2 != cmd {
            assert(st_.pool.contains(c2));
        }
    }
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

} // verus!
