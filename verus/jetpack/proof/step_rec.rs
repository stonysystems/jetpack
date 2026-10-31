//! §2 recovery, replica side (not trusted): L4-L8 (`RecvBeginRecovery`), L11-L22
//! (`RecvPrepare`), L31-L40 (`RecvAccept`), L51-L54 (`RecvFinishRecovery`) preserve `inv`.
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
use crate::proof::step_fast::lemma_log_same;
use vstd::prelude::*;

verus! {

/// `replica_wf` after learn(u) for a view u of the original protocol, with the log unchanged
/// or extended.
pub proof fn lemma_replica_wf_learn(cfg: Config, s: SystemState, s_: SystemState, r: int, u: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        s_.replicas[r].lnv == learn(s.replicas[r], u).lnv,
        s_.replicas[r].nv == learn(s.replicas[r], u).nv,
        s_.replicas[r].mode == learn(s.replicas[r], u).mode,
        s_.replicas[r].committed == s.replicas[r].committed,
        s_.replicas[r].olog == s.replicas[r].olog,
        bot() <= u <= s.base_view,
    ensures
        replica_wf(cfg, s_, r),
{
    let st = s.replicas[r];
    assert(replica_wf(cfg, s, r));
    lemma_learn_wf(st, u, s.base_view);
    assert forall|j: int| 0 <= j < st.olog.len() implies #[trigger] st.olog[j] == s_.log[j] by {
        assert(st.olog[j] == s.log[j]);
    }
}

/// L4-L8.
pub proof fn lemma_recv_begin_recovery_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvBeginRecovery { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvBeginRecovery { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvBeginRecovery(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    assert(replica_wf(cfg, s, r));
    let v = pkt.msg->BeginRecovery_view;
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    if v >= st.nv && v > st.lnv {
        // L5-L6
        let m = Msg::BeginRecoveryOK { view: v, lnv: st.lnv };
        assert(sent == send_to(c, pkt.src, m));
        lemma_send_to_msgs(c, pkt.src, m);
        if v > st.nv {
            lemma_join_facts(st, v);
            assert(st_ == join(st, v));
        } else {
            assert(st_ == st);
            lemma_replica_mono_refl(st);
        }
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
        }
        // replica_wf: new_view = v within the base view, Recovery iff v > last_normal_view
        assert forall|j: int| 0 <= j < st_.olog.len() implies #[trigger] st_.olog[j] == s_.log[j] by {
            assert(st.olog[j] == s.log[j]);
        }
        assert(replica_wf(cfg, s_, r));
        lemma_coord_ok_keep(cfg, s, s_, r);
        lemma_accepted_ok_keep(cfg, s, s_, r);
        lemma_acks_ok_keep(cfg, s, s_, r);
        lemma_poks_ok_keep(cfg, s, s_, r);
    } else {
        // L7-L8
        assert(st_ == st);
        let m = Msg::Nack { new_view: st.nv, lnv: st.lnv, k: None };
        assert(sent == send_to(c, pkt.src, m));
        lemma_send_to_msgs(c, pkt.src, m);
        lemma_replica_mono_refl(st);
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
        }
        lemma_preds_unchanged(cfg, s, s_, r);
    }
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L11-L22.
pub proof fn lemma_recv_prepare_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvPrepare { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvPrepare { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvPrepare(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    assert(replica_wf(cfg, s, r));
    let v = pkt.msg->Prepare_view;
    let vn = pkt.msg->Prepare_vn;
    let k = pkt.msg->Prepare_k;
    assert(bot() <= vn < v <= s.base_view && k >= 0);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    let s1 = learn(st, vn);
    lemma_learn_facts(st, vn);
    lemma_learn_wf(st, vn, s.base_view);
    if stale(s1, v, vn) {
        // L12
        assert(st_ == s1);
        let m = Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None };
        assert(sent == send_to(c, pkt.src, m));
        lemma_send_to_msgs(c, pkt.src, m);
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
        }
        lemma_replica_wf_learn(cfg, s, s_, r, vn);
        lemma_coord_ok_keep(cfg, s, s_, r);
        lemma_accepted_ok_keep(cfg, s, s_, r);
        lemma_acks_ok_keep(cfg, s, s_, r);
        lemma_poks_ok_keep(cfg, s, s_, r);
    } else {
        assert(v >= s1.nv && s1.lnv <= vn);
        assert(s1.lnv == vn);
        let s2 = join_if_newer(s1, v);
        lemma_join_if_newer_facts(s1, v);
        lemma_replica_mono_trans(st, s1, s2);
        assert(s2.nv == v);
        if k > msb_of(s2, vn) {
            // L16-L20
            assert(st_ == ReplicaState { msb: s2.msb.insert(vn, k), ..s2 });
            lemma_msb_insert_mono(s2, vn, k);
            lemma_replica_mono_trans(st, s2, st_);
            lemma_replica_step_mono(cfg, s, s_, r, step, sent);
            let body = if s2.accepted.contains_key(vn) {
                PrepareOkBody::Accepted { acc: s2.accepted[vn] }
            } else {
                PrepareOkBody::Pool { pool: pool_of(s2, vn) }
            };
            let m = Msg::PrepareOK { view: v, vn: vn, k: k, body: body };
            assert(sent == send_to(c, pkt.src, m));
            lemma_send_to_msgs(c, pkt.src, m);
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
                assert(sent.contains(p));
                assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
            }
            // replica_wf
            assert forall|j: int| 0 <= j < st_.olog.len() implies #[trigger] st_.olog[j] == s_.log[j] by {
                assert(st.olog[j] == s.log[j]);
            }
            assert(replica_wf(cfg, s_, r));
            lemma_coord_ok_keep(cfg, s, s_, r);
            lemma_accepted_ok_keep(cfg, s, s_, r);
            lemma_acks_ok_keep(cfg, s, s_, r);
            // poks_ok: the old PrepareOKs keep, the new one is checked here
            let b = Bal { v: v, k: k };
            assert(promise(s_, r, vn) == b);
            assert(pok_ok(cfg, s_, r, v, vn, k, body)) by {
                assert(st_.nv == v);
                match body {
                    PrepareOkBody::Accepted { acc } => {
                        assert(acc == st.accepted[vn]);
                        assert(accepted_ok(cfg, s, r));
                        assert(voted_for(s, r, vn, acc_bal(acc), acc.val));
                        let vt0 = Vote { r: r, vn: vn, bal: acc_bal(acc), val: acc.val };
                        assert(vote_ok(cfg, s, vt0));
                        assert(bal_le(acc_bal(acc), promise(s, r, vn)));
                        assert(bal_le(promise_of(st, vn), promise_of(s2, vn)));
                        assert(promise_of(s2, vn) == (Bal { v: v, k: msb_of(s2, vn) }));
                        assert(bal_lt(promise_of(s2, vn), b));
                        lemma_bal_le_trans(acc_bal(acc), promise_of(st, vn), promise_of(s2, vn));
                        lemma_bal_le_lt_trans(acc_bal(acc), promise_of(s2, vn), b);
                        assert(s_.votes.contains(vt0));
                        assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) && vt.r == r && vt.vn == vn && bal_lt(vt.bal, b)
                            implies bal_le(vt.bal, acc_bal(acc)) by {
                            assert(s.votes.contains(vt));
                            assert(vote_ok(cfg, s, vt));
                        }
                    },
                    PrepareOkBody::Pool { pool } => {
                        assert(!st.accepted.contains_key(vn));
                        assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) && vt.r == r && vt.vn == vn implies bal_le(b, vt.bal) by {
                            assert(s.votes.contains(vt));
                            assert(vote_ok(cfg, s, vt));
                            assert(false);
                        }
                        assert forall|p2: Packet| #[trigger] s_.network.contains(p2) && p2.src == (Addr::Replica { id: r }) && p2.msg is FastAck && p2.msg->FastAck_view == vn
                            implies pool.contains(p2.msg->FastAck_cmd) || committed_cmd(cfg, s_, p2.msg->FastAck_cmd) by {
                            assert(s.network.contains(p2));
                            assert(acks_ok(cfg, s, r));
                            assert(st.lnv >= vn);
                            assert(st.lnv == vn);
                            assert(s1 == st);
                            assert(pool == st.pool);
                            if !st.pool.contains(p2.msg->FastAck_cmd) {
                                lemma_committed_cmd_mono(cfg, s, s_, p2.msg->FastAck_cmd);
                            }
                        }
                    },
                }
            }
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is PrepareOK
                implies pok_ok(cfg, s_, r, p.msg->PrepareOK_view, p.msg->PrepareOK_vn, p.msg->PrepareOK_k, p.msg->PrepareOK_body) by {
                if s.network.contains(p) {
                    assert(poks_ok(cfg, s, r));
                    lemma_pok_ok_keep(cfg, s, s_, r, p.msg->PrepareOK_view, p.msg->PrepareOK_vn, p.msg->PrepareOK_k, p.msg->PrepareOK_body);
                } else {
                    assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
                }
            }
        } else {
            // L22
            assert(st_ == s2);
            let m = Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) };
            assert(sent == send_to(c, pkt.src, m));
            lemma_send_to_msgs(c, pkt.src, m);
            lemma_replica_step_mono(cfg, s, s_, r, step, sent);
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
                assert(sent.contains(p));
                assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
            }
            assert forall|j: int| 0 <= j < st_.olog.len() implies #[trigger] st_.olog[j] == s_.log[j] by {
                assert(st.olog[j] == s.log[j]);
            }
            assert(replica_wf(cfg, s_, r));
            lemma_coord_ok_keep(cfg, s, s_, r);
            lemma_accepted_ok_keep(cfg, s, s_, r);
            lemma_acks_ok_keep(cfg, s, s_, r);
            lemma_poks_ok_keep(cfg, s, s_, r);
        }
    }
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L31-L40.
pub proof fn lemma_recv_accept_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvAccept { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvAccept { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvAccept(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    assert(replica_wf(cfg, s, r));
    let v = pkt.msg->Accept_view;
    let vn = pkt.msg->Accept_vn;
    let k = pkt.msg->Accept_k;
    let rset = pkt.msg->Accept_rset;
    assert(v0() <= vn < v <= s.base_view && k >= 0);
    let s1 = learn(st, vn);
    lemma_learn_facts(st, vn);
    lemma_learn_wf(st, vn, s.base_view);
    if stale(s1, v, vn) {
        // L32
        assert(!accept_taken(st, v, vn, k));
        assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
        assert(st_ == s1);
        let m = Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None };
        assert(sent == send_to(c, pkt.src, m));
        lemma_send_to_msgs(c, pkt.src, m);
        lemma_replica_step_mono(cfg, s, s_, r, step, sent);
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
            assert(sent.contains(p));
            assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
        }
        lemma_replica_wf_learn(cfg, s, s_, r, vn);
        lemma_coord_ok_keep(cfg, s, s_, r);
        lemma_accepted_ok_keep(cfg, s, s_, r);
        lemma_acks_ok_keep(cfg, s, s_, r);
        lemma_poks_ok_keep(cfg, s, s_, r);
    } else {
        assert(v >= s1.nv && s1.lnv <= vn);
        let s2 = join_if_newer(s1, v);
        lemma_join_if_newer_facts(s1, v);
        lemma_replica_mono_trans(st, s1, s2);
        assert(s2.nv == v);
        if k >= msb_of(s2, vn) {
            // L36-L38: the vote
            assert(accept_taken(st, v, vn, k));
            let b = Bal { v: v, k: k };
            let vt0 = Vote { r: r, vn: vn, bal: b, val: rset };
            assert(votes_cast(r, st, step) =~= set![vt0]);
            let acc = Acc { view: v, k: k, val: rset };
            assert(st_ == ReplicaState { msb: s2.msb.insert(vn, k), accepted: s2.accepted.insert(vn, acc), ..s2 });
            lemma_accept_insert_mono(s2, vn, k, v, rset);
            lemma_replica_mono_trans(st, s2, st_);
            assert(promise(s_, r, vn) == b);
            assert(bal_le(promise_of(st, vn), promise_of(s2, vn)));
            assert(promise_of(s2, vn) == (Bal { v: v, k: msb_of(s2, vn) }));
            assert(bal_le(promise_of(s2, vn), b));
            lemma_bal_le_trans(promise_of(st, vn), promise_of(s2, vn), b);
            assert forall|vt: Vote| #[trigger] votes_cast(r, st, step).contains(vt) implies vt.r == r && bal_le(promise(s, r, vt.vn), vt.bal) by {
                assert(vt == vt0);
            }
            lemma_replica_step_mono(cfg, s, s_, r, step, sent);
            let m = Msg::AcceptOK { view: v, vn: vn, k: k };
            assert(sent == send_to(c, pkt.src, m));
            lemma_send_to_msgs(c, pkt.src, m);
            assert(s_.votes.contains(vt0));
            assert(voted_for(s_, r, vn, b, rset));
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
                assert(sent.contains(p));
                assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
                assert(p.src->Replica_id == r);
                assert(p.msg->AcceptOK_vn == vn && p.msg->AcceptOK_view == v && p.msg->AcceptOK_k == k);
                assert(voted_for(s_, p.src->Replica_id, p.msg->AcceptOK_vn, Bal { v: p.msg->AcceptOK_view, k: p.msg->AcceptOK_k }, rset));
                assert(msg_ok(cfg, s_, p));
            }
            // the new vote
            assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) && !s.votes.contains(vt) implies vote_ok(cfg, s_, vt) && vt.r == r by {
                assert(vt == vt0);
                lemma_safe_at_mono(cfg, s, s_, vn, b, rset);
                assert(s_.network.contains(pkt));
                assert(accept_in_net(s_, b, vn, rset));
                assert(st_.accepted.contains_key(vn));
                assert(st_.accepted[vn] == acc);
            }
            // replica_wf
            assert forall|j: int| 0 <= j < st_.olog.len() implies #[trigger] st_.olog[j] == s_.log[j] by {
                assert(st.olog[j] == s.log[j]);
            }
            assert(replica_wf(cfg, s_, r));
            lemma_coord_ok_keep(cfg, s, s_, r);
            // accepted_ok
            assert forall|w: int| #[trigger] st_.accepted.contains_key(w) implies {
                let a = st_.accepted[w];
                &&& voted_for(s_, r, w, acc_bal(a), a.val)
                &&& wf_bal(acc_bal(a))
            } by {
                if w == vn {
                    assert(st_.accepted[w] == acc);
                } else {
                    assert(st.accepted.contains_key(w));
                    assert(st_.accepted[w] == st.accepted[w]);
                    assert(accepted_ok(cfg, s, r));
                    let a = st.accepted[w];
                    assert(voted_for(s, r, w, acc_bal(a), a.val));
                    assert(s_.votes.contains(Vote { r: r, vn: w, bal: acc_bal(a), val: a.val }));
                }
            }
            lemma_acks_ok_keep(cfg, s, s_, r);
            lemma_poks_ok_keep(cfg, s, s_, r);
        } else {
            // L40
            assert(!accept_taken(st, v, vn, k));
            assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
            assert(st_ == s2);
            assert(s2.lnv == s1.lnv);
            assert(v0() <= s1.lnv <= s.base_view);
            let m = Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) };
            assert(sent == send_to(c, pkt.src, m));
            lemma_send_to_msgs(c, pkt.src, m);
            lemma_replica_step_mono(cfg, s, s_, r, step, sent);
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
                implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
                assert(sent.contains(p));
                assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
            }
            assert forall|j: int| 0 <= j < st_.olog.len() implies #[trigger] st_.olog[j] == s_.log[j] by {
                assert(st.olog[j] == s.log[j]);
            }
            assert(replica_wf(cfg, s_, r));
            lemma_coord_ok_keep(cfg, s, s_, r);
            lemma_accepted_ok_keep(cfg, s, s_, r);
            lemma_acks_ok_keep(cfg, s, s_, r);
            lemma_poks_ok_keep(cfg, s, s_, r);
        }
    }
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L51-L54.
pub proof fn lemma_recv_finish_recovery_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvFinishRecovery { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::RecvFinishRecovery { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(RecvFinishRecovery(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    assert(replica_wf(cfg, s, r));
    let v = pkt.msg->FinishRecovery_view;
    let vn = pkt.msg->FinishRecovery_vn;
    let rset = pkt.msg->FinishRecovery_rset;
    assert(v0() <= vn < v <= s.base_view);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    assert(st_ == learn(st, v));
    lemma_learn_facts(st, v);
    lemma_learn_wf(st, v, s.base_view);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    let m = Msg::FinishRecoveryOK { view: v };
    assert(sent == send_to(c, pkt.src, m));
    lemma_send_to_msgs(c, pkt.src, m);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p == (Packet { src: me(c), dst: pkt.src, msg: m }));
    }
    lemma_replica_wf_learn(cfg, s, s_, r, v);
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    // the log: L52-L53 may append the proposer's own Recovered(S)
    let app = finish_appends(cfg, s, r, pkt);
    assert(step_appends(cfg, s, r, step) == app);
    if st_.nv == v && (cfg.proposer)(v) == r && !has_recovered_in(s.log, v) && s.base_view == v {
        let e = Entry::Recovered { view: v, vn: vn, cmds: rset };
        assert(app == seq![e]);
        assert(s_.log =~= s.log.push(e));
        lemma_chosen_mono(cfg, s, s_, vn, rset);
        lemma_value_ok_mono(cfg, s, s_, vn, rset);
        assert(recovered_ok(cfg, s_, e));
        lemma_log_ok_push(cfg, s, s_, e);
    } else {
        assert(app == Seq::<Entry>::empty());
        assert(s_.log =~= s.log);
        lemma_log_ok_same(cfg, s, s_);
    }
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

} // verus!
