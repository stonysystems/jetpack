//! §2 recovery, coordinator side (not trusted): L9-L10 (`CoordBeginOK`), L23-L30
//! (`CoordPrepareOK`: the Paxos argument that C.rset is safe at (C.view, C.k) and respects the
//! snapshots), L47 (`CoordAcceptOK`: C.rset is chosen), L48 (`CoordFinish`), L41-L46
//! (`CoordNack`) preserve `inv`.
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
use crate::proof::quorum::*;
use crate::proof::replica_lemmas::*;
use crate::proof::step_fast::lemma_log_same;
use crate::proof::step_rec::lemma_replica_wf_learn;
use vstd::prelude::*;

verus! {

/// A coordinator step changes only the coordinator record: the replica is `replica_mono`.
pub proof fn lemma_coord_only_mono(st: ReplicaState, st_: ReplicaState)
    requires
        st_ == (ReplicaState { coord: st_.coord, ..st }),
    ensures
        replica_mono(st, st_),
{
    lemma_replica_mono_refl(st);
    assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
        assert(promise_of(st_, w) == promise_of(st, w));
    }
}

/// `is_majority` of the replica constants is `is_maj` of the configuration.
pub proof fn lemma_is_majority(cfg: Config, r: int, m: Set<int>)
    requires
        is_majority(replica_consts(cfg, r), m),
    ensures
        is_maj(cfg, m),
{
}

/// L9-L10.
pub proof fn lemma_coord_begin_ok_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkts: Set<Packet>, m: Set<int>, lnvs: Map<int, int>, vn: int, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(CoordBeginOK(c, st, st_, pkts, m, lnvs, vn, sent));
    assert(replica_wf(cfg, s, r));
    assert(coord_ok(cfg, s, r));
    let co = st.coord;
    assert(co.phase is P1);
    assert(0 <= co.view <= s.base_view && (cfg.proposer)(co.view) == r && co.k >= 0 && co.vn == bot());
    // the largest reported last normal view is one some replica reported: below C.view
    let rw = choose|q: int| #[trigger] m.contains(q) && lnvs[q] == vn;
    let pw = from_replica(c, rw, Msg::BeginRecoveryOK { view: co.view, lnv: lnvs[rw] });
    assert(pkts.contains(pw));
    assert(replica_received(step).contains(pw));
    assert(s.network.contains(pw));
    assert(msg_ok(cfg, s, pw));
    assert(v0() <= vn < co.view);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    let s1 = learn(st, vn);
    lemma_learn_facts(st, vn);
    lemma_learn_wf(st, vn, s.base_view);
    assert(st_ == ReplicaState { coord: Coord { phase: Phase::P2a, vn: vn, ..co }, ..s1 });
    lemma_coord_only_mono(s1, st_);
    lemma_replica_mono_trans(st, s1, st_);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    let msg = Msg::Prepare { view: co.view, vn: vn, k: co.k };
    assert(sent == broadcast(c, msg));
    lemma_broadcast_msgs(c, msg);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p.msg == msg && p.src == me(c));
    }
    lemma_replica_wf_learn(cfg, s, s_, r, vn);
    // coord_ok: P2a with a real v_n; no Accept of C.view exists yet (in P1 any would have v_n <= ⊥)
    let co_ = st_.coord;
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co_.view implies {
        &&& p.msg->Accept_vn <= co_.vn
        &&& p.msg->Accept_k <= co_.k
        &&& (co_.phase is P2a ==> !(p.msg->Accept_vn == co_.vn && p.msg->Accept_k == co_.k))
    } by {
        assert(s.network.contains(p));
        assert(msg_ok(cfg, s, p));
        assert(p.msg->Accept_vn <= co.vn);
        assert(false);
    }
    assert(coord_ok(cfg, s_, r));
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L23-L30.
pub proof fn lemma_coord_prepare_ok_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkts: Set<Packet>, m: Set<int>, bodies: Map<int, PrepareOkBody>, rule: RsetRule, rset: Set<int>, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(CoordPrepareOK(c, st, st_, pkts, m, bodies, rule, rset, sent));
    assert(replica_wf(cfg, s, r));
    assert(coord_ok(cfg, s, r));
    let co = st.coord;
    assert(co.phase is P2a);
    assert(0 <= co.view <= s.base_view && (cfg.proposer)(co.view) == r && co.k >= 0);
    let w = co.vn;
    let b = Bal { v: co.view, k: co.k };
    lemma_is_majority(cfg, r, m);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    assert(st_ == ReplicaState { coord: Coord { phase: Phase::P2b, rset: rset, ..co }, ..st });
    lemma_coord_only_mono(st, st_);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    assert(s_.votes == s.votes);
    // every member's PrepareOK(C.view, C.v_n, C.k, body) is in the network, with its facts
    assert forall|q: int| #[trigger] m.contains(q) implies s.network.contains(from_replica(c, q, Msg::PrepareOK { view: co.view, vn: w, k: co.k, body: bodies[q] }))
        && pok_ok(cfg, s, q, co.view, w, co.k, bodies[q]) && cfg.replicas.contains(q) by {
        let p = from_replica(c, q, Msg::PrepareOK { view: co.view, vn: w, k: co.k, body: bodies[q] });
        assert(pkts.contains(p));
        assert(replica_received(step).contains(p));
        assert(s.network.contains(p));
        assert(poks_ok(cfg, s, q));
    }
    // v_n is a real view: some member's PrepareOK says so
    let q0 = lemma_maj_member(cfg, m);
    assert(msg_ok(cfg, s, from_replica(c, q0, Msg::PrepareOK { view: co.view, vn: w, k: co.k, body: bodies[q0] })));
    assert(v0() <= w < co.view);
    // promises are unchanged by this step
    assert forall|q: int| #[trigger] cfg.replicas.contains(q) implies promise(s_, q, w) == promise(s, q, w) by {
        if q != r {
            assert(s_.replicas[q] == s.replicas[q]);
        }
    }
    // safe_at(w, b, rset)
    assert forall|b2: Bal| wf_bal(b2) && bal_lt(b2, b) implies #[trigger] none_other_choosable_at(cfg, s_, w, b2, rset) by {
        match rule {
            RsetRule::Adopt { r: rs } => {
                let accs = bodies[rs]->Accepted_acc;
                let bs = acc_bal(accs);
                assert(rset == accs.val);
                assert(pok_ok(cfg, s, rs, co.view, w, co.k, bodies[rs]));
                assert(voted_for(s, rs, w, bs, rset));
                let vts = Vote { r: rs, vn: w, bal: bs, val: rset };
                assert(vote_ok(cfg, s, vts));
                if bal_lt(b2, bs) {
                    assert(none_other_choosable_at(cfg, s, w, b2, rset));
                    lemma_noc_mono(cfg, s, s_, w, b2, rset);
                } else {
                    lemma_bal_total(b2, bs);
                    assert(bal_le(bs, b2));
                    assert forall|q: int| #[trigger] m.contains(q) implies voted_for(s_, q, w, b2, rset) || cannot_vote_at(s_, q, w, b2) by {
                        assert(pok_ok(cfg, s, q, co.view, w, co.k, bodies[q]));
                        assert(bal_le(b, promise(s, q, w)));
                        lemma_bal_lt_le_trans(b2, b, promise(s, q, w));
                        assert(bal_lt(b2, promise(s_, q, w)));
                        if did_not_vote_at(s_, q, w, b2) {
                        } else {
                            let val = choose|val: Set<int>| #[trigger] voted_for(s_, q, w, b2, val);
                            let vt = Vote { r: q, vn: w, bal: b2, val: val };
                            assert(s.votes.contains(vt));
                            match bodies[q] {
                                PrepareOkBody::Pool { pool } => {
                                    assert(bal_le(b, vt.bal));
                                    lemma_bal_asym(b2, b);
                                    assert(false);
                                },
                                PrepareOkBody::Accepted { acc } => {
                                    assert(bal_le(b2, acc_bal(acc)));
                                    assert(bal_le(acc_bal(acc), bs));
                                    lemma_bal_le_trans(b2, acc_bal(acc), bs);
                                    if b2 != bs {
                                        assert(bal_lt(b2, bs) || bal_lt(bs, b2));
                                        if bal_lt(b2, bs) {
                                            assert(false);
                                        } else {
                                            lemma_bal_asym(bs, b2);
                                            assert(false);
                                        }
                                    }
                                    assert(b2 == bs);
                                    assert(vote_ok(cfg, s, vt));
                                    let p1 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: bs.v, vn: w, k: bs.k, rset: val });
                                    let p2 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: bs.v, vn: w, k: bs.k, rset: rset });
                                    assert(one_decree(s));
                                    assert(val == rset);
                                    assert(voted_for(s_, q, w, b2, rset));
                                },
                            }
                        }
                    }
                    assert(is_maj(cfg, m));
                }
            },
            RsetRule::Count => {
                assert forall|q: int| #[trigger] m.contains(q) implies cannot_vote_at(s_, q, w, b2) by {
                    assert(pok_ok(cfg, s, q, co.view, w, co.k, bodies[q]));
                    assert(bodies[q] is Pool);
                    assert(bal_le(b, promise(s, q, w)));
                    lemma_bal_lt_le_trans(b2, b, promise(s, q, w));
                    assert forall|val: Set<int>| !#[trigger] voted_for(s_, q, w, b2, val) by {
                        if voted_for(s_, q, w, b2, val) {
                            let vt = Vote { r: q, vn: w, bal: b2, val: val };
                            assert(s.votes.contains(vt));
                            assert(bal_le(b, vt.bal));
                            lemma_bal_asym(b2, b);
                            assert(false);
                        }
                    }
                }
                assert(is_maj(cfg, m));
            },
        }
    }
    assert(safe_at(cfg, s_, w, b, rset));
    // value_ok(w, rset)
    match rule {
        RsetRule::Adopt { r: rs } => {
            let accs = bodies[rs]->Accepted_acc;
            let bs = acc_bal(accs);
            assert(voted_for(s, rs, w, bs, rset));
            assert(vote_ok(cfg, s, Vote { r: rs, vn: w, bal: bs, val: rset }));
            let p = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: bs.v, vn: w, k: bs.k, rset: rset });
            assert(msg_ok(cfg, s, p));
            assert(value_ok(cfg, s, w, rset));
            lemma_value_ok_mono(cfg, s, s_, w, rset);
        },
        RsetRule::Count => {
            let pools = pools_of(m, bodies);
            assert forall|q: int| #[trigger] m.contains(q) implies pok_pool_from(s_, q, w, pools[q]) by {
                let p = from_replica(c, q, Msg::PrepareOK { view: co.view, vn: w, k: co.k, body: bodies[q] });
                assert(s_.network.contains(p));
                assert(pools[q] == bodies[q]->Pool_pool);
                assert(bodies[q] == (PrepareOkBody::Pool { pool: pools[q] }));
            }
            assert(pools_reported(s_, m, w, pools));
            assert forall|cmd: int| #[trigger] pool_count(m, pools, cmd) >= t(cfg) implies rset.contains(cmd) by {
                assert(c_t(c) == t(cfg));
                assert(is_recover_set(c, m, pools, rset));
            }
            assert(counts_into(cfg, m, pools, rset));
            assert(value_ok(cfg, s_, w, rset));
        },
    }
    // the new Accepts
    let msg = Msg::Accept { view: co.view, vn: w, k: co.k, rset: rset };
    assert(sent == broadcast(c, msg));
    lemma_broadcast_msgs(c, msg);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p.msg == msg && p.src == me(c));
    }
    // one_decree: no Accept(C.view, C.v_n, C.k, ·) was in the network (coord_ok in P2a)
    assert forall|p1: Packet, p2: Packet|
        #[trigger] s_.network.contains(p1) && #[trigger] s_.network.contains(p2)
        && p1.msg is Accept && p2.msg is Accept
        && p1.msg->Accept_view == p2.msg->Accept_view && p1.msg->Accept_vn == p2.msg->Accept_vn && p1.msg->Accept_k == p2.msg->Accept_k
        implies p1.msg->Accept_rset == p2.msg->Accept_rset by {
        if s.network.contains(p1) && s.network.contains(p2) {
            assert(one_decree(s));
        } else if !s.network.contains(p1) && !s.network.contains(p2) {
            assert(p1.msg == msg && p2.msg == msg);
        } else if !s.network.contains(p1) {
            assert(p1.msg == msg);
            assert(p2.msg->Accept_view == co.view);
            assert(!(p2.msg->Accept_vn == co.vn && p2.msg->Accept_k == co.k));
            assert(false);
        } else {
            assert(p2.msg == msg);
            assert(p1.msg->Accept_view == co.view);
            assert(!(p1.msg->Accept_vn == co.vn && p1.msg->Accept_k == co.k));
            assert(false);
        }
    }
    // r's predicates
    lemma_replica_wf_keep(cfg, s, s_, r);
    let co_ = st_.coord;
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co_.view implies {
        &&& p.msg->Accept_vn <= co_.vn
        &&& p.msg->Accept_k <= co_.k
        &&& (co_.phase is P2a ==> !(p.msg->Accept_vn == co_.vn && p.msg->Accept_k == co_.k))
    } by {
        if s.network.contains(p) {
        } else {
            assert(p.msg == msg);
        }
    }
    lemma_broadcast_has(c, msg, r);
    assert(s_.network.contains(Packet { src: me(c), dst: Addr::Replica { id: r }, msg: msg }));
    assert(accept_in_net(s_, b, w, rset));
    assert(coord_ok(cfg, s_, r));
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L47.
pub proof fn lemma_coord_accept_ok_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkts: Set<Packet>, m: Set<int>, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::CoordAcceptOK { pkts, m }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::CoordAcceptOK { pkts, m };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(CoordAcceptOK(c, st, st_, pkts, m, sent));
    assert(replica_wf(cfg, s, r));
    assert(coord_ok(cfg, s, r));
    let co = st.coord;
    assert(co.phase is P2b);
    assert(0 <= co.view <= s.base_view && (cfg.proposer)(co.view) == r && co.k >= 0 && 0 <= co.vn < co.view);
    let w = co.vn;
    let b = Bal { v: co.view, k: co.k };
    assert(accept_in_net(s, b, w, co.rset));
    lemma_is_majority(cfg, r, m);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    assert(st_ == ReplicaState { coord: Coord { phase: Phase::P3, ..co }, ..st });
    lemma_coord_only_mono(st, st_);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    assert(sent == Set::<Packet>::empty());
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
    }
    // C.rset is chosen: every member voted for the value of C's Accept
    let pa = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b.v, vn: w, k: b.k, rset: co.rset });
    assert forall|q: int| #[trigger] m.contains(q) implies voted_for(s, q, w, b, co.rset) by {
        let p = from_replica(c, q, Msg::AcceptOK { view: co.view, vn: w, k: co.k });
        assert(pkts.contains(p));
        assert(replica_received(step).contains(p));
        assert(s.network.contains(p));
        assert(msg_ok(cfg, s, p));
        let val = choose|val: Set<int>| #[trigger] voted_for(s, p.src->Replica_id, w, Bal { v: co.view, k: co.k }, val);
        assert(p.src->Replica_id == q);
        let vt = Vote { r: q, vn: w, bal: b, val: val };
        assert(s.votes.contains(vt));
        assert(vote_ok(cfg, s, vt));
        let pv = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b.v, vn: w, k: b.k, rset: val });
        assert(one_decree(s));
        assert(val == co.rset);
    }
    assert(quorum_voted(s, m, w, b, co.rset));
    assert(chosen(cfg, s, w, co.rset));
    lemma_chosen_mono(cfg, s, s_, w, co.rset);
    // the log gains Recovered(C.view, C.v_n, C.rset)
    let e = recovered_entry(co);
    assert(step_appends(cfg, s, r, step) == seq![e]);
    assert(s_.log =~= s.log.push(e));
    assert(entry_view(e) == co.view);
    assert(s.base_view == co.view);
    assert(msg_ok(cfg, s, pa));
    assert(value_ok(cfg, s, w, co.rset));
    lemma_value_ok_mono(cfg, s, s_, w, co.rset);
    assert(recovered_ok(cfg, s_, e));
    lemma_log_ok_push(cfg, s, s_, e);
    // r's predicates
    lemma_replica_wf_keep(cfg, s, s_, r);
    let co_ = st_.coord;
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co_.view implies {
        &&& p.msg->Accept_vn <= co_.vn
        &&& p.msg->Accept_k <= co_.k
        &&& (co_.phase is P2a ==> !(p.msg->Accept_vn == co_.vn && p.msg->Accept_k == co_.k))
    } by {
        assert(s.network.contains(p));
    }
    lemma_accept_in_net_mono(s, s_, b, w, co.rset);
    assert(coord_ok(cfg, s_, r));
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L48.
pub proof fn lemma_coord_finish_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::CoordFinish, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::CoordFinish;
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(CoordFinish(c, st, st_, sent));
    assert(replica_wf(cfg, s, r));
    assert(coord_ok(cfg, s, r));
    let co = st.coord;
    assert(co.phase is P3);
    assert(0 <= co.view <= s.base_view && (cfg.proposer)(co.view) == r && co.k >= 0 && 0 <= co.vn < co.view);
    let w = co.vn;
    let b = Bal { v: co.view, k: co.k };
    assert(accept_in_net(s, b, w, co.rset));
    assert(chosen(cfg, s, w, co.rset));
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    assert(st_ == ReplicaState { coord: Coord { phase: Phase::Done, ..co }, ..st });
    lemma_coord_only_mono(st, st_);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    let pa = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b.v, vn: w, k: b.k, rset: co.rset });
    assert(msg_ok(cfg, s, pa));
    assert(value_ok(cfg, s, w, co.rset));
    lemma_value_ok_mono(cfg, s, s_, w, co.rset);
    lemma_chosen_mono(cfg, s, s_, w, co.rset);
    let msg = Msg::FinishRecovery { view: co.view, vn: w, rset: co.rset };
    assert(sent == broadcast(c, msg));
    lemma_broadcast_msgs(c, msg);
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p.msg == msg && p.src == me(c));
    }
    lemma_replica_wf_keep(cfg, s, s_, r);
    let co_ = st_.coord;
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co_.view implies {
        &&& p.msg->Accept_vn <= co_.vn
        &&& p.msg->Accept_k <= co_.k
        &&& (co_.phase is P2a ==> !(p.msg->Accept_vn == co_.vn && p.msg->Accept_k == co_.k))
    } by {
        assert(s.network.contains(p));
    }
    lemma_accept_in_net_mono(s, s_, b, w, co.rset);
    assert(coord_ok(cfg, s_, r));
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// L41-L46.
pub proof fn lemma_coord_nack_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, pkt: Packet, sent: Set<Packet>)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::CoordNack { pkt }, sent),
    ensures
        inv(cfg, s_),
{
    let step = ReplicaStep::CoordNack { pkt };
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    lemma_log_same(cfg, s, s_, r, step);
    let c = replica_consts(cfg, r);
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(CoordNack(c, st, st_, pkt, sent));
    assert(replica_received(step).contains(pkt));
    assert(s.network.contains(pkt));
    assert(msg_ok(cfg, s, pkt));
    assert(replica_wf(cfg, s, r));
    assert(coord_ok(cfg, s, r));
    let co = st.coord;
    assert(co.phase is P1 || co.phase is P2a || co.phase is P2b);
    assert(0 <= co.view <= s.base_view && (cfg.proposer)(co.view) == r && co.k >= 0);
    let nv_ = pkt.msg->Nack_new_view;
    let lnv_ = pkt.msg->Nack_lnv;
    let k_ = pkt.msg->Nack_k;
    assert(v0() <= lnv_ <= s.base_view);
    assert(votes_cast(r, st, step) =~= Set::<Vote>::empty());
    let s1 = learn(st, lnv_);
    lemma_learn_facts(st, lnv_);
    lemma_learn_wf(st, lnv_, s.base_view);
    assert(st_ == ReplicaState { coord: st_.coord, ..s1 });
    lemma_coord_only_mono(s1, st_);
    lemma_replica_mono_trans(st, s1, st_);
    lemma_replica_step_mono(cfg, s, s_, r, step, sent);
    lemma_replica_wf_learn(cfg, s, s_, r, lnv_);
    let co_ = st_.coord;
    if nv_ > co.view || lnv_ >= co.view {
        // L42
        assert(co_ == Coord { phase: Phase::Stopped, ..co });
        assert(sent == Set::<Packet>::empty());
    } else if lnv_ > co.vn {
        // L44
        assert(co_ == Coord { phase: Phase::P2a, vn: lnv_, ..co });
        let msg = Msg::Prepare { view: co.view, vn: lnv_, k: co.k };
        assert(sent == broadcast(c, msg));
        lemma_broadcast_msgs(c, msg);
    } else if k_ is Some && k_->Some_0 >= co.k {
        // L46
        assert(co_ == Coord { phase: Phase::P2a, k: k_->Some_0 + 1, ..co });
        let msg = Msg::Prepare { view: co.view, vn: co.vn, k: k_->Some_0 + 1 };
        assert(sent == broadcast(c, msg));
        lemma_broadcast_msgs(c, msg);
    } else {
        assert(co_ == co);
        assert(sent == Set::<Packet>::empty());
    }
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
        implies msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r })) by {
        assert(sent.contains(p));
        assert(p.msg is Prepare && p.src == me(c));
    }
    // coord_ok: the Accepts of C.view stay at or below (C.v_n, C.k), strictly when a Prepare is out
    assert forall|p: Packet| #[trigger] s_.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co_.view implies {
        &&& p.msg->Accept_vn <= co_.vn
        &&& p.msg->Accept_k <= co_.k
        &&& (co_.phase is P2a ==> !(p.msg->Accept_vn == co_.vn && p.msg->Accept_k == co_.k))
    } by {
        assert(s.network.contains(p));
        assert(p.msg->Accept_vn <= co.vn && p.msg->Accept_k <= co.k);
    }
    if co_.phase is P2b {
        lemma_accept_in_net_mono(s, s_, Bal { v: co.view, k: co.k }, co.vn, co.rset);
    }
    assert(coord_ok(cfg, s_, r));
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

} // verus!
