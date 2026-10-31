//! The properties from the invariant (not trusted): the pseudocode §0's replica invariants,
//! RecoveredAgreement (the recovery Paxos chooses one set per fast-path view),
//! FastCommitDurability (paper C1 Case 3 with the GC rule), Principle 2; each on every state of
//! a valid behavior.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use crate::proof::inductive::*;
use crate::proof::quorum::*;
use vstd::prelude::*;

verus! {

// ---------------------------------------------------------------------------------------------
// 1. the pseudocode §0 replica invariants
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_replica_invariants(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        ReplicaInvariants(cfg, s),
{
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies {
        &&& s.replicas[r].lnv <= s.replicas[r].nv
        &&& (s.replicas[r].mode is Recovery <==> s.replicas[r].nv > s.replicas[r].lnv)
    } by {
        assert(replica_wf(cfg, s, r));
    }
}

pub proof fn lemma_replica_invariants_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] ReplicaInvariants(cfg, b[i]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] ReplicaInvariants(cfg, b[i]) by {
        lemma_replica_invariants(cfg, b[i]);
    }
}

pub proof fn lemma_replica_step_invariants_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() - 1 ==> #[trigger] ReplicaStepInvariants(cfg, b[i], b[i + 1]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() - 1 implies #[trigger] ReplicaStepInvariants(cfg, b[i], b[i + 1]) by {
        lemma_behavior_step(cfg, b, i);
        lemma_next_step_invariants(cfg, b[i], b[i + 1]);
    }
}

// ---------------------------------------------------------------------------------------------
// 2. RecoveredAgreement
// ---------------------------------------------------------------------------------------------

/// A value chosen at a ballot and a vote at a higher ballot agree (TPTP's Lemma, p.8).
proof fn lemma_chosen_below(cfg: Config, s: SystemState, w: int, b1: Bal, q1: Set<int>, v1: Set<int>, r2: int, b2: Bal, v2: Set<int>)
    requires
        wf(cfg),
        inv(cfg, s),
        is_maj(cfg, q1),
        quorum_voted(s, q1, w, b1, v1),
        voted_for(s, r2, w, b2, v2),
        bal_lt(b1, b2),
    ensures
        v1 == v2,
{
    let vt2 = Vote { r: r2, vn: w, bal: b2, val: v2 };
    assert(s.votes.contains(vt2));
    assert(vote_ok(cfg, s, vt2));
    let r1 = lemma_maj_member(cfg, q1);
    assert(voted_for(s, r1, w, b1, v1));
    let vt1 = Vote { r: r1, vn: w, bal: b1, val: v1 };
    assert(s.votes.contains(vt1));
    assert(vote_ok(cfg, s, vt1));
    assert(wf_bal(b1));
    assert(none_other_choosable_at(cfg, s, w, b1, v2));
    let q = choose|q: Set<int>| #[trigger] is_maj(cfg, q)
        && forall|r: int| #[trigger] q.contains(r) ==> voted_for(s, r, w, b1, v2) || cannot_vote_at(s, r, w, b1);
    let a = lemma_maj_intersect(cfg, q, q1);
    assert(voted_for(s, a, w, b1, v1));
    assert(!did_not_vote_at(s, a, w, b1));
    assert(voted_for(s, a, w, b1, v2));
    let vta1 = Vote { r: a, vn: w, bal: b1, val: v1 };
    let vta2 = Vote { r: a, vn: w, bal: b1, val: v2 };
    assert(vote_ok(cfg, s, vta1));
    assert(vote_ok(cfg, s, vta2));
    let p1 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b1.v, vn: w, k: b1.k, rset: v1 });
    let p2 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b1.v, vn: w, k: b1.k, rset: v2 });
    assert(one_decree(s));
}

/// Two values chosen for the same fast-path view are equal (TPTP Theorem 1 in this setting).
pub proof fn lemma_chosen_unique(cfg: Config, s: SystemState, w: int, v1: Set<int>, v2: Set<int>)
    requires
        wf(cfg),
        inv(cfg, s),
        chosen(cfg, s, w, v1),
        chosen(cfg, s, w, v2),
    ensures
        v1 == v2,
{
    let (b1, q1) = choose|b: Bal, q: Set<int>| is_maj(cfg, q) && #[trigger] quorum_voted(s, q, w, b, v1);
    let (b2, q2) = choose|b: Bal, q: Set<int>| is_maj(cfg, q) && #[trigger] quorum_voted(s, q, w, b, v2);
    let r1 = lemma_maj_member(cfg, q1);
    let r2 = lemma_maj_member(cfg, q2);
    assert(voted_for(s, r1, w, b1, v1));
    assert(voted_for(s, r2, w, b2, v2));
    lemma_bal_total(b1, b2);
    if b1 == b2 {
        let vt1 = Vote { r: r1, vn: w, bal: b1, val: v1 };
        let vt2 = Vote { r: r2, vn: w, bal: b2, val: v2 };
        assert(vote_ok(cfg, s, vt1));
        assert(vote_ok(cfg, s, vt2));
        let p1 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b1.v, vn: w, k: b1.k, rset: v1 });
        let p2 = choose|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b2.v, vn: w, k: b2.k, rset: v2 });
        assert(one_decree(s));
    } else if bal_lt(b1, b2) {
        lemma_chosen_below(cfg, s, w, b1, q1, v1, r2, b2, v2);
    } else {
        lemma_chosen_below(cfg, s, w, b2, q2, v2, r1, b1, v1);
    }
}

/// An entry of a replica's copy is the entry of the one original log.
proof fn lemma_olog_entry(cfg: Config, s: SystemState, r: int, j: int)
    requires
        inv(cfg, s),
        cfg.replicas.contains(r),
        0 <= j < s.replicas[r].olog.len(),
    ensures
        j < s.log.len(),
        s.replicas[r].olog[j] == s.log[j],
{
    assert(replica_wf(cfg, s, r));
}

pub proof fn lemma_recovered_agreement(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        RecoveredAgreement(cfg, s),
{
    assert forall|r1: int, j1: int, r2: int, j2: int|
        cfg.replicas.contains(r1) && cfg.replicas.contains(r2)
        && 0 <= j1 < s.replicas[r1].olog.len() && 0 <= j2 < s.replicas[r2].olog.len()
        && #[trigger] s.replicas[r1].olog[j1] is Recovered && #[trigger] s.replicas[r2].olog[j2] is Recovered
        && s.replicas[r1].olog[j1]->Recovered_vn == s.replicas[r2].olog[j2]->Recovered_vn
        implies s.replicas[r1].olog[j1]->Recovered_cmds == s.replicas[r2].olog[j2]->Recovered_cmds by {
        lemma_olog_entry(cfg, s, r1, j1);
        lemma_olog_entry(cfg, s, r2, j2);
        let e1 = s.log[j1];
        let e2 = s.log[j2];
        assert(recovered_ok(cfg, s, e1));
        assert(recovered_ok(cfg, s, e2));
        lemma_chosen_unique(cfg, s, e1->Recovered_vn, e1->Recovered_cmds, e2->Recovered_cmds);
    }
}

pub proof fn lemma_recovered_agreement_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] RecoveredAgreement(cfg, b[i]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] RecoveredAgreement(cfg, b[i]) by {
        lemma_recovered_agreement(cfg, b[i]);
    }
}

// ---------------------------------------------------------------------------------------------
// 3. FastCommitDurability
// ---------------------------------------------------------------------------------------------

/// A recovery set that respects some majority's snapshots holds every fast-committed command
/// that is not committed on the original path: the superquorum of ackers meets the majority
/// in at least t replicas, each of whose snapshot holds the command (the GC rule), so L28
/// counts it in.
pub proof fn lemma_value_ok_durable(cfg: Config, s: SystemState, w: int, c: int, val: Set<int>)
    requires
        wf(cfg),
        inv(cfg, s),
        fast_committed(cfg, s, w, c),
        value_ok(cfg, s, w, val),
    ensures
        val.contains(c) || committed_cmd(cfg, s, c),
{
    let q = choose|q: Set<int>| #[trigger] q.subset_of(cfg.replicas) && q.len() >= sq(cfg)
        && q.contains((cfg.proposer)(w))
        && forall|r: int| #[trigger] q.contains(r) ==> acked(s, r, w, c);
    let (m, pools) = choose|m: Set<int>, pools: Map<int, Set<int>>| is_maj(cfg, m)
        && #[trigger] pools_reported(s, m, w, pools) && counts_into(cfg, m, pools, val);
    lemma_sq_maj_meet(cfg, q, m);
    let qm = q.intersect(m);
    if committed_cmd(cfg, s, c) {
    } else {
        assert forall|r: int| #[trigger] qm.contains(r) implies pools[r].contains(c) by {
            assert(q.contains(r) && m.contains(r));
            assert(cfg.replicas.contains(r));
            assert(acked(s, r, w, c));
            let pa = choose|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg == (Msg::FastAck { view: w, cmd: c });
            assert(pok_pool_from(s, r, w, pools[r]));
            let pp = choose|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r })
                && p.msg is PrepareOK && p.msg->PrepareOK_vn == w && p.msg->PrepareOK_body == (PrepareOkBody::Pool { pool: pools[r] });
            assert(poks_ok(cfg, s, r));
            assert(pok_ok(cfg, s, r, pp.msg->PrepareOK_view, w, pp.msg->PrepareOK_k, PrepareOkBody::Pool { pool: pools[r] }));
        }
        let f = m.filter(|r: int| pools[r].contains(c));
        assert forall|r: int| #[trigger] qm.contains(r) implies f.contains(r) by {
            assert(m.contains(r) && pools[r].contains(c));
        }
        assert(qm.subset_of(f));
        lemma_subset_len(qm, f);
        assert(pool_count(m, pools, c) == f.len() as int);
        assert(pool_count(m, pools, c) >= t(cfg));
        assert(val.contains(c));
    }
}

pub proof fn lemma_fast_commit_durability(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        FastCommitDurability(cfg, s),
{
    assert forall|w: int, c: int, r: int, j: int|
        cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] s.replicas[r].olog[j] is Recovered && s.replicas[r].olog[j]->Recovered_vn == w
        && #[trigger] fast_committed(cfg, s, w, c)
        implies s.replicas[r].olog[j]->Recovered_cmds.contains(c) || committed_cmd(cfg, s, c) by {
        lemma_olog_entry(cfg, s, r, j);
        let e = s.log[j];
        assert(recovered_ok(cfg, s, e));
        lemma_value_ok_durable(cfg, s, w, c, e->Recovered_cmds);
    }
}

pub proof fn lemma_client_fast_commit_durability(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        ClientFastCommitDurability(cfg, s),
{
    assert forall|k: int, fc: FastCommit, r: int, j: int|
        cfg.clients.contains(k) && #[trigger] s.clients[k].fast.contains(fc)
        && cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] s.replicas[r].olog[j] is Recovered && s.replicas[r].olog[j]->Recovered_vn == fc.view
        implies s.replicas[r].olog[j]->Recovered_cmds.contains(fc.cmd) || committed_cmd(cfg, s, fc.cmd) by {
        assert(client_ok(cfg, s, k));
        assert(fast_committed(cfg, s, fc.view, fc.cmd));
        lemma_olog_entry(cfg, s, r, j);
        let e = s.log[j];
        assert(recovered_ok(cfg, s, e));
        lemma_value_ok_durable(cfg, s, fc.view, fc.cmd, e->Recovered_cmds);
    }
}

pub proof fn lemma_fast_commit_durability_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] FastCommitDurability(cfg, b[i]),
        forall|i: int| 0 <= i < b.len() ==> #[trigger] ClientFastCommitDurability(cfg, b[i]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] FastCommitDurability(cfg, b[i]) by {
        lemma_fast_commit_durability(cfg, b[i]);
    }
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] ClientFastCommitDurability(cfg, b[i]) by {
        lemma_client_fast_commit_durability(cfg, b[i]);
    }
}

// ---------------------------------------------------------------------------------------------
// 4. Principle 2
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_principle2(cfg: Config, s: SystemState)
    requires
        wf(cfg),
        inv(cfg, s),
    ensures
        Principle2(cfg, s),
{
    assert forall|r: int, j: int|
        cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] entry_view(s.replicas[r].olog[j]) != v0()
        && (forall|i: int| 0 <= i < j ==> entry_view(#[trigger] s.replicas[r].olog[i]) != entry_view(s.replicas[r].olog[j]))
        implies s.replicas[r].olog[j] is Recovered by {
        lemma_olog_entry(cfg, s, r, j);
        match s.log[j] {
            Entry::Recovered { view, vn, cmds } => {},
            Entry::Cmd { view, cmd } => {
                assert(s.log[j] is Cmd);
                let i = choose|i: int| 0 <= i < j && #[trigger] s.log[i] is Recovered && entry_view(s.log[i]) == entry_view(s.log[j]);
                lemma_olog_entry(cfg, s, r, i);
                assert(entry_view(s.replicas[r].olog[i]) == entry_view(s.replicas[r].olog[j]));
                assert(false);
            },
        }
    }
}

pub proof fn lemma_principle2_behavior(cfg: Config, b: Seq<SystemState>)
    requires
        WellFormed(cfg),
        IsValidBehavior(cfg, b),
    ensures
        forall|i: int| 0 <= i < b.len() ==> #[trigger] Principle2(cfg, b[i]),
{
    lemma_wf(cfg);
    lemma_behavior_inv(cfg, b);
    assert forall|i: int| 0 <= i < b.len() implies #[trigger] Principle2(cfg, b[i]) by {
        lemma_principle2(cfg, b[i]);
    }
}

} // verus!
