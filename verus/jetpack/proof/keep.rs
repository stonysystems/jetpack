//! The per-replica predicates kept across a `mono` step under weak hypotheses (not trusted):
//! `coord_ok` when the coordinator is unchanged and no Accept of its view appears, `accepted_ok`
//! when the accepted map is unchanged, `acks_ok` when the pool only loses committed commands,
//! `pok_ok` for every PrepareOK already sent. `lemma_preds_unchanged` is their conjunction for
//! a replica that did not move.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use crate::proof::mono::*;
use vstd::prelude::*;

verus! {

/// `coord_ok` when r's coordinator is unchanged and no new Accept carries its view.
pub proof fn lemma_coord_ok_keep(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        s_.replicas[r].coord == s.replicas[r].coord,
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.msg is Accept
            ==> p.msg->Accept_view != s.replicas[r].coord.view,
    ensures
        coord_ok(cfg, s_, r),
{
    let co = s.replicas[r].coord;
    assert(coord_ok(cfg, s, r));
    if !(co.phase is Idle) {
        assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co.view implies {
            &&& p.msg->Accept_vn <= co.vn
            &&& p.msg->Accept_k <= co.k
            &&& (co.phase is P2a ==> !(p.msg->Accept_vn == co.vn && p.msg->Accept_k == co.k))
        } by {
            assert(s.network.contains(p));
        }
        if co.phase is P2b || co.phase is P3 || co.phase is Done {
            lemma_accept_in_net_mono(s, s_, Bal { v: co.view, k: co.k }, co.vn, co.rset);
        }
        if co.phase is P3 || co.phase is Done {
            lemma_chosen_mono(cfg, s, s_, co.vn, co.rset);
        }
    }
}

/// `accepted_ok` when r's accepted map is unchanged.
pub proof fn lemma_accepted_ok_keep(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        s_.replicas[r].accepted == s.replicas[r].accepted,
    ensures
        accepted_ok(cfg, s_, r),
{
    assert(accepted_ok(cfg, s, r));
    assert forall|w: int| #[trigger] s_.replicas[r].accepted.contains_key(w) implies {
        let acc = s_.replicas[r].accepted[w];
        &&& voted_for(s_, r, w, acc_bal(acc), acc.val)
        &&& wf_bal(acc_bal(acc))
    } by {
        let acc = s.replicas[r].accepted[w];
        assert(voted_for(s, r, w, acc_bal(acc), acc.val));
        assert(s_.votes.contains(Vote { r: r, vn: w, bal: acc_bal(acc), val: acc.val }));
    }
}

/// `acks_ok` when r sent no new FastAck and, if its last normal view stayed, its pool lost only
/// committed commands.
pub proof fn lemma_acks_ok_keep(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) ==> !(p.src == (Addr::Replica { id: r }) && p.msg is FastAck),
        s_.replicas[r].lnv == s.replicas[r].lnv ==> forall|c: int| #[trigger] s.replicas[r].pool.contains(c)
            ==> s_.replicas[r].pool.contains(c) || committed_cmd(cfg, s_, c),
    ensures
        acks_ok(cfg, s_, r),
{
    assert(acks_ok(cfg, s, r));
    assert(replica_mono(s.replicas[r], s_.replicas[r]));
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is FastAck implies {
        &&& s_.replicas[r].lnv >= p.msg->FastAck_view
        &&& (s_.replicas[r].lnv == p.msg->FastAck_view
            ==> s_.replicas[r].pool.contains(p.msg->FastAck_cmd) || committed_cmd(cfg, s_, p.msg->FastAck_cmd))
    } by {
        assert(s.network.contains(p));
        let w = p.msg->FastAck_view;
        let c = p.msg->FastAck_cmd;
        if s_.replicas[r].lnv == w {
            assert(s.replicas[r].lnv == w);
            if s.replicas[r].pool.contains(c) {
            } else {
                lemma_committed_cmd_mono(cfg, s, s_, c);
            }
        }
    }
}

/// `pok_ok` for a PrepareOK r already sent, when r sent no new FastAck of view w (new votes
/// are above r's old promise by `mono`, so above the PrepareOK's ballot).
pub proof fn lemma_pok_ok_keep(cfg: Config, s: SystemState, s_: SystemState, r: int, v: int, w: int, k: int, body: PrepareOkBody)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            ==> !(p.src == (Addr::Replica { id: r }) && p.msg is FastAck && p.msg->FastAck_view == w),
        pok_ok(cfg, s, r, v, w, k, body),
    ensures
        pok_ok(cfg, s_, r, v, w, k, body),
{
    let b = Bal { v: v, k: k };
    lemma_promise_mono(cfg, s, s_, r, w);
    lemma_bal_le_trans(b, promise(s, r, w), promise(s_, r, w));
    assert(replica_mono(s.replicas[r], s_.replicas[r]));
    match body {
        PrepareOkBody::Accepted { acc } => {
            assert(s_.votes.contains(Vote { r: r, vn: w, bal: acc_bal(acc), val: acc.val }));
            assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) && vt.r == r && vt.vn == w && bal_lt(vt.bal, b) implies bal_le(vt.bal, acc_bal(acc)) by {
                if s.votes.contains(vt) {
                } else {
                    assert(bal_le(promise(s, r, w), vt.bal));
                    lemma_bal_le_trans(b, promise(s, r, w), vt.bal);
                    lemma_bal_asym(vt.bal, b);
                    assert(false);
                }
            }
        },
        PrepareOkBody::Pool { pool } => {
            assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) && vt.r == r && vt.vn == w implies bal_le(b, vt.bal) by {
                if s.votes.contains(vt) {
                } else {
                    assert(bal_le(promise(s, r, w), vt.bal));
                    lemma_bal_le_trans(b, promise(s, r, w), vt.bal);
                }
            }
            assert forall|p2: Packet| #[trigger] s_.network.contains(p2) && p2.src == (Addr::Replica { id: r }) && p2.msg is FastAck && p2.msg->FastAck_view == w
                implies pool.contains(p2.msg->FastAck_cmd) || committed_cmd(cfg, s_, p2.msg->FastAck_cmd) by {
                assert(s.network.contains(p2));
                if !pool.contains(p2.msg->FastAck_cmd) {
                    lemma_committed_cmd_mono(cfg, s, s_, p2.msg->FastAck_cmd);
                }
            }
        },
    }
}

/// `poks_ok` when r sent no new PrepareOK, and any new FastAck from r is one of its current
/// last normal view while Normal (N12-N16): every PrepareOK r sent is for a view below its
/// new_view = last_normal_view, so no snapshot is concerned.
pub proof fn lemma_poks_ok_keep(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.src == (Addr::Replica { id: r }) ==> {
            &&& !(p.msg is PrepareOK)
            &&& (p.msg is FastAck ==> p.msg->FastAck_view == s.replicas[r].lnv && s.replicas[r].mode is Normal)
        },
    ensures
        poks_ok(cfg, s_, r),
{
    assert(poks_ok(cfg, s, r));
    assert(replica_wf(cfg, s, r));
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is PrepareOK
        implies pok_ok(cfg, s_, r, p.msg->PrepareOK_view, p.msg->PrepareOK_vn, p.msg->PrepareOK_k, p.msg->PrepareOK_body) by {
        assert(s.network.contains(p));
        let v = p.msg->PrepareOK_view;
        let w = p.msg->PrepareOK_vn;
        assert(msg_ok(cfg, s, p));
        assert(pok_ok(cfg, s, r, v, w, p.msg->PrepareOK_k, p.msg->PrepareOK_body));
        assert forall|p2: Packet| #[trigger] s_.network.contains(p2) && !s.network.contains(p2)
            implies !(p2.src == (Addr::Replica { id: r }) && p2.msg is FastAck && p2.msg->FastAck_view == w) by {
            if p2.src == (Addr::Replica { id: r }) && p2.msg is FastAck {
                assert(s.replicas[r].mode is Normal);
                assert(s.replicas[r].nv == s.replicas[r].lnv);
                assert(w < v <= s.replicas[r].nv);
            }
        }
        lemma_pok_ok_keep(cfg, s, s_, r, v, w, p.msg->PrepareOK_k, p.msg->PrepareOK_body);
    }
}

/// `replica_wf` when r's views, mode, committed length and log copy are unchanged.
pub proof fn lemma_replica_wf_keep(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        s_.replicas[r].lnv == s.replicas[r].lnv,
        s_.replicas[r].nv == s.replicas[r].nv,
        s_.replicas[r].mode == s.replicas[r].mode,
        s_.replicas[r].committed == s.replicas[r].committed,
        s_.replicas[r].olog == s.replicas[r].olog,
    ensures
        replica_wf(cfg, s_, r),
{
    let st = s.replicas[r];
    assert(replica_wf(cfg, s, r));
    assert forall|j: int| 0 <= j < st.olog.len() implies #[trigger] st.olog[j] == s_.log[j] by {
        assert(st.olog[j] == s.log[j]);
    }
}

/// All five predicates of a replica that did not move, given that no new packet is a FastAck
/// or PrepareOK from it and no new Accept carries its coordinator's view.
pub proof fn lemma_preds_unchanged(cfg: Config, s: SystemState, s_: SystemState, r: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        s_.replicas[r] == s.replicas[r],
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            ==> !(p.src == (Addr::Replica { id: r }) && (p.msg is FastAck || p.msg is PrepareOK)),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.msg is Accept
            ==> p.msg->Accept_view != s.replicas[r].coord.view,
    ensures
        replica_wf(cfg, s_, r),
        coord_ok(cfg, s_, r),
        accepted_ok(cfg, s_, r),
        acks_ok(cfg, s_, r),
        poks_ok(cfg, s_, r),
{
    lemma_replica_wf_keep(cfg, s, s_, r);
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
}

} // verus!
