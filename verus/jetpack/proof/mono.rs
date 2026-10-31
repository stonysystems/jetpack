//! What a `mono` step preserves (not trusted): the stability of every notion of `defs.rs` under
//! growth of the network, the votes, the promises and the logs; the predicates of a replica
//! that did not move; and the assembly lemma that turns a step's local facts into `inv(s_)`.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use crate::proof::keep::*;
use vstd::prelude::*;

verus! {

// ---------------------------------------------------------------------------------------------
// Stability of the notions
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_committed_cmd_mono(cfg: Config, s: SystemState, s_: SystemState, c: int)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        committed_cmd(cfg, s, c),
    ensures
        committed_cmd(cfg, s_, c),
{
    let (r, j) = choose|r: int, j: int| cfg.replicas.contains(r) && 0 <= j < s.replicas[r].committed
        && #[trigger] entry_cmds(s.replicas[r].olog[j]).contains(c);
    assert(replica_wf(cfg, s, r));
    assert(replica_mono(s.replicas[r], s_.replicas[r]));
    assert(s_.replicas[r].olog[j] == s.replicas[r].olog[j]);
    assert(entry_cmds(s_.replicas[r].olog[j]).contains(c));
}

pub proof fn lemma_promise_mono(cfg: Config, s: SystemState, s_: SystemState, r: int, w: int)
    requires
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
    ensures
        bal_le(promise(s, r, w), promise(s_, r, w)),
{
    assert(replica_mono(s.replicas[r], s_.replicas[r]));
    assert(bal_le(promise_of(s.replicas[r], w), promise_of(s_.replicas[r], w)));
}

pub proof fn lemma_cannot_vote_at_mono(cfg: Config, s: SystemState, s_: SystemState, r: int, w: int, b: Bal)
    requires
        mono(cfg, s, s_),
        cfg.replicas.contains(r),
        cannot_vote_at(s, r, w, b),
    ensures
        cannot_vote_at(s_, r, w, b),
{
    lemma_promise_mono(cfg, s, s_, r, w);
    lemma_bal_lt_le_trans(b, promise(s, r, w), promise(s_, r, w));
    assert forall|val: Set<int>| !#[trigger] voted_for(s_, r, w, b, val) by {
        if voted_for(s_, r, w, b, val) {
            let vt = Vote { r: r, vn: w, bal: b, val: val };
            assert(s_.votes.contains(vt));
            if s.votes.contains(vt) {
                assert(voted_for(s, r, w, b, val));
                assert(false);
            } else {
                assert(bal_le(promise(s, r, w), b));
                lemma_bal_asym(b, promise(s, r, w));
                assert(false);
            }
        }
    }
}

pub proof fn lemma_noc_mono(cfg: Config, s: SystemState, s_: SystemState, w: int, b: Bal, val: Set<int>)
    requires
        mono(cfg, s, s_),
        none_other_choosable_at(cfg, s, w, b, val),
    ensures
        none_other_choosable_at(cfg, s_, w, b, val),
{
    let q = choose|q: Set<int>| #[trigger] is_maj(cfg, q)
        && forall|r: int| #[trigger] q.contains(r) ==> voted_for(s, r, w, b, val) || cannot_vote_at(s, r, w, b);
    assert forall|r: int| #[trigger] q.contains(r) implies voted_for(s_, r, w, b, val) || cannot_vote_at(s_, r, w, b) by {
        if voted_for(s, r, w, b, val) {
            assert(s_.votes.contains(Vote { r: r, vn: w, bal: b, val: val }));
        } else {
            lemma_cannot_vote_at_mono(cfg, s, s_, r, w, b);
        }
    }
    assert(is_maj(cfg, q));
}

pub proof fn lemma_safe_at_mono(cfg: Config, s: SystemState, s_: SystemState, w: int, b: Bal, val: Set<int>)
    requires
        mono(cfg, s, s_),
        safe_at(cfg, s, w, b, val),
    ensures
        safe_at(cfg, s_, w, b, val),
{
    assert forall|b2: Bal| wf_bal(b2) && bal_lt(b2, b) implies #[trigger] none_other_choosable_at(cfg, s_, w, b2, val) by {
        lemma_noc_mono(cfg, s, s_, w, b2, val);
    }
}

pub proof fn lemma_chosen_mono(cfg: Config, s: SystemState, s_: SystemState, w: int, val: Set<int>)
    requires
        mono(cfg, s, s_),
        chosen(cfg, s, w, val),
    ensures
        chosen(cfg, s_, w, val),
{
    let (b, q) = choose|b: Bal, q: Set<int>| is_maj(cfg, q) && #[trigger] quorum_voted(s, q, w, b, val);
    assert forall|r: int| #[trigger] q.contains(r) implies voted_for(s_, r, w, b, val) by {
        assert(voted_for(s, r, w, b, val));
        assert(s_.votes.contains(Vote { r: r, vn: w, bal: b, val: val }));
    }
    assert(quorum_voted(s_, q, w, b, val));
}

pub proof fn lemma_pok_pool_from_mono(s: SystemState, s_: SystemState, r: int, w: int, pool: Set<int>)
    requires
        s.network.subset_of(s_.network),
        pok_pool_from(s, r, w, pool),
    ensures
        pok_pool_from(s_, r, w, pool),
{
    let p = choose|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r })
        && p.msg is PrepareOK && p.msg->PrepareOK_vn == w && p.msg->PrepareOK_body == (PrepareOkBody::Pool { pool: pool });
    assert(s_.network.contains(p));
}

pub proof fn lemma_value_ok_mono(cfg: Config, s: SystemState, s_: SystemState, w: int, val: Set<int>)
    requires
        mono(cfg, s, s_),
        value_ok(cfg, s, w, val),
    ensures
        value_ok(cfg, s_, w, val),
{
    let (m, pools) = choose|m: Set<int>, pools: Map<int, Set<int>>| is_maj(cfg, m)
        && #[trigger] pools_reported(s, m, w, pools) && counts_into(cfg, m, pools, val);
    assert forall|r: int| #[trigger] m.contains(r) implies pok_pool_from(s_, r, w, pools[r]) by {
        lemma_pok_pool_from_mono(s, s_, r, w, pools[r]);
    }
    assert(pools_reported(s_, m, w, pools));
}

pub proof fn lemma_accept_in_net_mono(s: SystemState, s_: SystemState, b: Bal, w: int, val: Set<int>)
    requires
        s.network.subset_of(s_.network),
        accept_in_net(s, b, w, val),
    ensures
        accept_in_net(s_, b, w, val),
{
    let p = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b.v, vn: w, k: b.k, rset: val });
    assert(s_.network.contains(p));
}

pub proof fn lemma_acked_mono(s: SystemState, s_: SystemState, r: int, w: int, c: int)
    requires
        s.network.subset_of(s_.network),
        acked(s, r, w, c),
    ensures
        acked(s_, r, w, c),
{
    let p = choose|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg == (Msg::FastAck { view: w, cmd: c });
    assert(s_.network.contains(p));
}

pub proof fn lemma_fast_committed_mono(cfg: Config, s: SystemState, s_: SystemState, w: int, c: int)
    requires
        s.network.subset_of(s_.network),
        fast_committed(cfg, s, w, c),
    ensures
        fast_committed(cfg, s_, w, c),
{
    let q = choose|q: Set<int>| #[trigger] q.subset_of(cfg.replicas) && q.len() >= sq(cfg)
        && q.contains((cfg.proposer)(w))
        && forall|r: int| #[trigger] q.contains(r) ==> acked(s, r, w, c);
    assert forall|r: int| #[trigger] q.contains(r) implies acked(s_, r, w, c) by {
        lemma_acked_mono(s, s_, r, w, c);
    }
    assert(q.subset_of(cfg.replicas));
}

pub proof fn lemma_recovered_ok_mono(cfg: Config, s: SystemState, s_: SystemState, e: Entry)
    requires
        mono(cfg, s, s_),
        recovered_ok(cfg, s, e),
    ensures
        recovered_ok(cfg, s_, e),
{
    lemma_chosen_mono(cfg, s, s_, e->Recovered_vn, e->Recovered_cmds);
    lemma_value_ok_mono(cfg, s, s_, e->Recovered_vn, e->Recovered_cmds);
}

/// A packet's state-independent facts survive a `mono` step.
pub proof fn lemma_msg_ok_mono(cfg: Config, s: SystemState, s_: SystemState, p: Packet)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        msg_ok(cfg, s, p),
    ensures
        msg_ok(cfg, s_, p),
{
    match p.msg {
        Msg::Evict { cmd } => {
            lemma_committed_cmd_mono(cfg, s, s_, cmd);
        },
        Msg::Accept { view, vn, k, rset } => {
            lemma_safe_at_mono(cfg, s, s_, vn, Bal { v: view, k: k }, rset);
            lemma_value_ok_mono(cfg, s, s_, vn, rset);
        },
        Msg::AcceptOK { view, vn, k } => {
            let val = choose|val: Set<int>| #[trigger] voted_for(s, p.src->Replica_id, vn, Bal { v: view, k: k }, val);
            assert(s_.votes.contains(Vote { r: p.src->Replica_id, vn: vn, bal: Bal { v: view, k: k }, val: val }));
            assert(voted_for(s_, p.src->Replica_id, vn, Bal { v: view, k: k }, val));
        },
        Msg::FinishRecovery { view, vn, rset } => {
            lemma_chosen_mono(cfg, s, s_, vn, rset);
            lemma_value_ok_mono(cfg, s, s_, vn, rset);
        },
        _ => {},
    }
}

/// A vote's facts survive a `mono` step.
pub proof fn lemma_vote_ok_mono(cfg: Config, s: SystemState, s_: SystemState, vt: Vote)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        vote_ok(cfg, s, vt),
    ensures
        vote_ok(cfg, s_, vt),
{
    lemma_promise_mono(cfg, s, s_, vt.r, vt.vn);
    lemma_bal_le_trans(vt.bal, promise(s, vt.r, vt.vn), promise(s_, vt.r, vt.vn));
    lemma_safe_at_mono(cfg, s, s_, vt.vn, vt.bal, vt.val);
    lemma_accept_in_net_mono(s, s_, vt.bal, vt.vn, vt.val);
    assert(replica_mono(s.replicas[vt.r], s_.replicas[vt.r]));
    let a = s.replicas[vt.r];
    let b = s_.replicas[vt.r];
    assert(a.accepted.contains_key(vt.vn));
    if b.accepted[vt.vn] == a.accepted[vt.vn] {
    } else {
        assert(bal_le(promise_of(a, vt.vn), acc_bal(b.accepted[vt.vn])));
        lemma_bal_le_trans(vt.bal, promise_of(a, vt.vn), acc_bal(b.accepted[vt.vn]));
    }
}

// ---------------------------------------------------------------------------------------------
// The original log
// ---------------------------------------------------------------------------------------------

/// `log_ok` after a step that leaves the log as it was.
pub proof fn lemma_log_ok_same(cfg: Config, s: SystemState, s_: SystemState)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        s_.log == s.log,
        s_.committed <= s_.log.len(),
    ensures
        log_ok(cfg, s_),
{
    assert forall|j: int| 0 <= j < s_.log.len() && #[trigger] s_.log[j] is Recovered implies recovered_ok(cfg, s_, s_.log[j]) by {
        assert(s.log[j] is Recovered);
        lemma_recovered_ok_mono(cfg, s, s_, s.log[j]);
    }
}

/// `log_ok` after a step that appends one entry of the current base view.
pub proof fn lemma_log_ok_push(cfg: Config, s: SystemState, s_: SystemState, e: Entry)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        s_.log == s.log.push(e),
        s_.committed <= s_.log.len(),
        entry_view(e) == s_.base_view,
        e is Cmd && entry_view(e) != v0() ==> exists|i: int| 0 <= i < s.log.len() && #[trigger] s.log[i] is Recovered && entry_view(s.log[i]) == entry_view(e),
        e is Recovered ==> recovered_ok(cfg, s_, e),
    ensures
        log_ok(cfg, s_),
{
    let n = s.log.len() as int;
    assert(s_.log.len() == n + 1);
    assert(s_.log[n] == e);
    assert forall|j: int| 0 <= j < s_.log.len() implies v0() <= entry_view(#[trigger] s_.log[j]) <= s_.base_view by {
        if j < n {
            assert(s_.log[j] == s.log[j]);
        }
    }
    assert forall|i: int, j: int| 0 <= i < j < s_.log.len() implies entry_view(#[trigger] s_.log[i]) <= entry_view(#[trigger] s_.log[j]) by {
        assert(s_.log[i] == s.log[i]);
        if j < n {
            assert(s_.log[j] == s.log[j]);
        } else {
            assert(entry_view(s.log[i]) <= s.base_view <= s_.base_view);
        }
    }
    assert forall|j: int| 0 <= j < s_.log.len() && #[trigger] s_.log[j] is Cmd && entry_view(s_.log[j]) != v0()
        implies exists|i: int| 0 <= i < j && #[trigger] s_.log[i] is Recovered && entry_view(s_.log[i]) == entry_view(s_.log[j]) by {
        if j < n {
            assert(s_.log[j] == s.log[j]);
            let i = choose|i: int| 0 <= i < j && #[trigger] s.log[i] is Recovered && entry_view(s.log[i]) == entry_view(s.log[j]);
            assert(s_.log[i] == s.log[i]);
            assert(s_.log[i] is Recovered && entry_view(s_.log[i]) == entry_view(s_.log[j]));
        } else {
            let i = choose|i: int| 0 <= i < s.log.len() && #[trigger] s.log[i] is Recovered && entry_view(s.log[i]) == entry_view(e);
            assert(s_.log[i] == s.log[i]);
            assert(s_.log[i] is Recovered && entry_view(s_.log[i]) == entry_view(s_.log[j]));
        }
    }
    assert forall|j: int| 0 <= j < s_.log.len() && #[trigger] s_.log[j] is Recovered implies recovered_ok(cfg, s_, s_.log[j]) by {
        if j < n {
            assert(s_.log[j] == s.log[j]);
            lemma_recovered_ok_mono(cfg, s, s_, s.log[j]);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------------------------

/// `inv(s_)` from a `mono` step in which only replica `r0` moved, given the facts about what is
/// new (packets, votes) and about `r0`, the log, the Accepts and the clients.
pub proof fn lemma_inv_assemble(cfg: Config, s: SystemState, s_: SystemState, r0: int)
    requires
        wf(cfg),
        inv(cfg, s),
        mono(cfg, s, s_),
        cfg.replicas.contains(r0),
        forall|r: int| #[trigger] cfg.replicas.contains(r) && r != r0 ==> s_.replicas[r] == s.replicas[r],
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p)
            ==> msg_ok(cfg, s_, p) && (p.src is Client || p.src == (Addr::Replica { id: r0 })),
        forall|vt: Vote| #[trigger] s_.votes.contains(vt) && !s.votes.contains(vt) ==> vote_ok(cfg, s_, vt) && vt.r == r0,
        replica_wf(cfg, s_, r0),
        coord_ok(cfg, s_, r0),
        accepted_ok(cfg, s_, r0),
        acks_ok(cfg, s_, r0),
        poks_ok(cfg, s_, r0),
        log_ok(cfg, s_),
        one_decree(s_),
        forall|k: int| #[trigger] cfg.clients.contains(k) ==> client_ok(cfg, s_, k),
    ensures
        inv(cfg, s_),
{
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies {
        &&& replica_wf(cfg, s_, r)
        &&& coord_ok(cfg, s_, r)
        &&& accepted_ok(cfg, s_, r)
        &&& acks_ok(cfg, s_, r)
        &&& poks_ok(cfg, s_, r)
    } by {
        if r != r0 {
            assert forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.msg is Accept
                implies p.msg->Accept_view != s.replicas[r].coord.view by {
                assert(msg_ok(cfg, s_, p));
                assert(p.src == (Addr::Replica { id: (cfg.proposer)(p.msg->Accept_view) }));
                assert(coord_ok(cfg, s, r));
                if s.replicas[r].coord.phase is Idle && s.replicas[r].coord.view == bot() {
                    assert(p.msg->Accept_view >= v0());
                } else {
                    assert((cfg.proposer)(s.replicas[r].coord.view) == r);
                }
            }
            lemma_preds_unchanged(cfg, s, s_, r);
        }
    }
    assert forall|vt: Vote| #[trigger] s_.votes.contains(vt) implies vote_ok(cfg, s_, vt) by {
        if s.votes.contains(vt) {
            lemma_vote_ok_mono(cfg, s, s_, vt);
        }
    }
    assert forall|p: Packet| #[trigger] s_.network.contains(p) implies msg_ok(cfg, s_, p) by {
        if s.network.contains(p) {
            lemma_msg_ok_mono(cfg, s, s_, p);
        }
    }
}

/// `one_decree` after a step that adds no Accept.
pub proof fn lemma_one_decree_no_accept(s: SystemState, s_: SystemState)
    requires
        one_decree(s),
        s.network.subset_of(s_.network),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) ==> !(p.msg is Accept),
    ensures
        one_decree(s_),
{
    assert forall|p1: Packet, p2: Packet|
        #[trigger] s_.network.contains(p1) && #[trigger] s_.network.contains(p2)
        && p1.msg is Accept && p2.msg is Accept
        && p1.msg->Accept_view == p2.msg->Accept_view && p1.msg->Accept_vn == p2.msg->Accept_vn && p1.msg->Accept_k == p2.msg->Accept_k
        implies p1.msg->Accept_rset == p2.msg->Accept_rset by {
        assert(s.network.contains(p1));
        assert(s.network.contains(p2));
    }
}

/// `client_ok` for every client after a step that leaves the clients as they were.
pub proof fn lemma_clients_unchanged(cfg: Config, s: SystemState, s_: SystemState)
    requires
        inv(cfg, s),
        mono(cfg, s, s_),
        s_.clients == s.clients,
    ensures
        forall|k: int| #[trigger] cfg.clients.contains(k) ==> client_ok(cfg, s_, k),
{
    assert forall|k: int| #[trigger] cfg.clients.contains(k) implies client_ok(cfg, s_, k) by {
        assert(client_ok(cfg, s, k));
        assert forall|fc: FastCommit| #[trigger] s_.clients[k].fast.contains(fc) implies fast_committed(cfg, s_, fc.view, fc.cmd) by {
            lemma_fast_committed_mono(cfg, s, s_, fc.view, fc.cmd);
        }
    }
}

} // verus!
