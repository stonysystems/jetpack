//! The inductive invariant of the Jetpack the pseudocode model (not trusted).
//!
//! Three layers. (1) Well-formedness: the pseudocode §0's replica invariants, view bounds, the original
//! log's prefix structure. (2) The recovery Paxos, one instance per fast-path view w, ballots
//! (view, k) ordered lexicographically: the vocabulary of `Voting.tla` (`safe_at`,
//! `none_other_choosable_at`, `cannot_vote_at`) over the vote history, with a replica's promise
//! for w being (R.new_view, R.max_seen_ballot[w]). (3) Durability of fast commits: every
//! FastAck a replica sent is backed by its pool until the command commits; every PrepareOK
//! pool is a snapshot that keeps every ack'd, uncommitted command; every proposed recovery set
//! contains every command that at least t of a majority's snapshots hold (`value_ok`).
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use vstd::prelude::*;

verus! {

// ---------------------------------------------------------------------------------------------
// Well-formedness of the configuration, behind a wrapper
// ---------------------------------------------------------------------------------------------

#[verifier::opaque]
pub open spec fn wf(cfg: Config) -> bool {
    WellFormed(cfg)
}

pub proof fn lemma_wf(cfg: Config)
    requires
        WellFormed(cfg),
    ensures
        wf(cfg),
{
    reveal(wf);
}

pub proof fn lemma_wf_proposer(cfg: Config, v: int)
    requires
        wf(cfg),
    ensures
        cfg.replicas.contains((cfg.proposer)(v)),
{
    reveal(wf);
}

pub proof fn lemma_wf_n(cfg: Config)
    requires
        wf(cfg),
    ensures
        n(cfg) >= 1,
        maj(cfg) >= 1,
        t(cfg) >= 1,
        2 * maj(cfg) > n(cfg),
        sq(cfg) + maj(cfg) - n(cfg) == t(cfg),
{
    reveal(wf);
}

// ---------------------------------------------------------------------------------------------
// The recovery Paxos: promises, votes, `Voting.tla`'s notions
// ---------------------------------------------------------------------------------------------

/// R's promise for the recovery of w: (R.new_view, R.max_seen_ballot[w]). R takes
/// Prepare(v, w, k) iff (v, k) > promise (L11, L14-L15) and Accept(v, w, k, ·) iff (v, k) >=
/// promise (L31, L34-L35); both leave the promise at (v, k).
pub open spec fn promise_of(st: ReplicaState, w: int) -> Bal {
    Bal { v: st.nv, k: msb_of(st, w) }
}

pub open spec fn promise(s: SystemState, r: int, w: int) -> Bal {
    promise_of(s.replicas[r], w)
}

/// Replica r accepted `val` for w at ballot b (L37).
pub open spec fn voted_for(s: SystemState, r: int, w: int, b: Bal, val: Set<int>) -> bool {
    s.votes.contains(Vote { r: r, vn: w, bal: b, val: val })
}

pub open spec fn did_not_vote_at(s: SystemState, r: int, w: int, b: Bal) -> bool {
    forall|val: Set<int>| !#[trigger] voted_for(s, r, w, b, val)
}

/// r cast no vote for w at b and promised above b, so it never will (votes are at ballots >=
/// the promise, which only grows).
pub open spec fn cannot_vote_at(s: SystemState, r: int, w: int, b: Bal) -> bool {
    &&& bal_lt(b, promise(s, r, w))
    &&& did_not_vote_at(s, r, w, b)
}

/// maj(v) replicas (the pseudocode §0).
pub open spec fn is_maj(cfg: Config, q: Set<int>) -> bool {
    q.subset_of(cfg.replicas) && q.len() >= maj(cfg)
}

/// Every member of q voted for `val` for w at b.
pub open spec fn quorum_voted(s: SystemState, q: Set<int>, w: int, b: Bal, val: Set<int>) -> bool {
    forall|r: int| #[trigger] q.contains(r) ==> voted_for(s, r, w, b, val)
}

/// `NoneOtherChoosableAt`: some majority's members each voted for `val` at b or cannot vote at
/// b, so no other value can be chosen for w at b.
pub open spec fn none_other_choosable_at(cfg: Config, s: SystemState, w: int, b: Bal, val: Set<int>) -> bool {
    exists|q: Set<int>| #[trigger] is_maj(cfg, q)
        && forall|r: int| #[trigger] q.contains(r) ==> voted_for(s, r, w, b, val) || cannot_vote_at(s, r, w, b)
}

/// `SafeAt`: no value other than `val` is or can be chosen for w at a ballot below b.
pub open spec fn safe_at(cfg: Config, s: SystemState, w: int, b: Bal, val: Set<int>) -> bool {
    forall|b2: Bal| wf_bal(b2) && bal_lt(b2, b) ==> #[trigger] none_other_choosable_at(cfg, s, w, b2, val)
}

/// `val` is chosen for w: a majority voted for it at one ballot (L47's AcceptOK quorum).
pub open spec fn chosen(cfg: Config, s: SystemState, w: int, val: Set<int>) -> bool {
    exists|b: Bal, q: Set<int>| is_maj(cfg, q) && #[trigger] quorum_voted(s, q, w, b, val)
}

/// An Accept(b.v, w, b.k, val) is in the network.
pub open spec fn accept_in_net(s: SystemState, b: Bal, w: int, val: Set<int>) -> bool {
    exists|p: Packet| #[trigger] s.network.contains(p) && p.msg == (Msg::Accept { view: b.v, vn: w, k: b.k, rset: val })
}

// ---------------------------------------------------------------------------------------------
// Durability: PrepareOK snapshots and the recovery sets they bound
// ---------------------------------------------------------------------------------------------

/// Replica r sent a PrepareOK for w carrying `pool` (L20).
pub open spec fn pok_pool_from(s: SystemState, r: int, w: int, pool: Set<int>) -> bool {
    exists|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r })
        && p.msg is PrepareOK && p.msg->PrepareOK_vn == w && p.msg->PrepareOK_body == (PrepareOkBody::Pool { pool: pool })
}

/// Every member of m sent a PrepareOK for w carrying pools[m].
pub open spec fn pools_reported(s: SystemState, m: Set<int>, w: int, pools: Map<int, Set<int>>) -> bool {
    forall|r: int| #[trigger] m.contains(r) ==> pok_pool_from(s, r, w, pools[r])
}

/// Every command that at least t of the members of m reported is in `val` (L27-L29).
pub open spec fn counts_into(cfg: Config, m: Set<int>, pools: Map<int, Set<int>>, val: Set<int>) -> bool {
    forall|c: int| #[trigger] pool_count(m, pools, c) >= t(cfg) ==> val.contains(c)
}

/// A recovery set for w that respects some majority's snapshots: whatever L26-L29 would have
/// recovered from them is in it. Adopting an accepted value (L24) keeps it, by induction.
pub open spec fn value_ok(cfg: Config, s: SystemState, w: int, val: Set<int>) -> bool {
    exists|m: Set<int>, pools: Map<int, Set<int>>| is_maj(cfg, m) && #[trigger] pools_reported(s, m, w, pools) && counts_into(cfg, m, pools, val)
}

// ---------------------------------------------------------------------------------------------
// The parts of the invariant
// ---------------------------------------------------------------------------------------------

/// the pseudocode §0's replica invariants, view bounds, and R.olog a prefix of the one original log with
/// R's committed prefix within the global one (A1-A3).
pub open spec fn replica_wf(cfg: Config, s: SystemState, r: int) -> bool {
    let st = s.replicas[r];
    &&& v0() <= st.lnv <= st.nv <= s.base_view
    &&& (st.mode is Recovery <==> st.nv > st.lnv)
    &&& 0 <= st.committed <= st.olog.len() <= s.log.len()
    &&& st.committed <= s.committed
    &&& forall|j: int| 0 <= j < st.olog.len() ==> #[trigger] st.olog[j] == s.log[j]
}

/// Coordinator C at r (L1-L48): its view is one of the original protocol's and r is its
/// proposer; v_n is ⊥ until L9 and then a view below C.view (in P2a it may still be ⊥ after a
/// stale Nack took L46 in P1, DR-10; such a Prepare(v, ⊥, k) is Nacked by L11); every Accept of C.view in the
/// network is at or below C's current (v_n, k), and strictly below while a Prepare is
/// outstanding (so each (view, v_n, k) gets one Accept); C's own Accept is in the network from
/// P2b on; C.rset is chosen from P3 on.
pub open spec fn coord_ok(cfg: Config, s: SystemState, r: int) -> bool {
    let co = s.replicas[r].coord;
    ||| (co.phase is Idle && co.view == bot())
    ||| {
        &&& 0 <= co.view <= s.base_view
        &&& (cfg.proposer)(co.view) == r
        &&& co.k >= 0
        &&& (co.phase is P1 ==> co.vn == bot())
        &&& ((co.phase is P2a || co.phase is Stopped) ==> co.vn == bot() || 0 <= co.vn < co.view)
        &&& ((co.phase is P2b || co.phase is P3 || co.phase is Done) ==> 0 <= co.vn < co.view)
        &&& forall|p: Packet| #[trigger] s.network.contains(p) && p.msg is Accept && p.msg->Accept_view == co.view ==> {
            &&& p.msg->Accept_vn <= co.vn
            &&& p.msg->Accept_k <= co.k
            &&& (co.phase is P2a ==> !(p.msg->Accept_vn == co.vn && p.msg->Accept_k == co.k))
        }
        &&& ((co.phase is P2b || co.phase is P3 || co.phase is Done) ==> accept_in_net(s, Bal { v: co.view, k: co.k }, co.vn, co.rset))
        &&& ((co.phase is P3 || co.phase is Done) ==> chosen(cfg, s, co.vn, co.rset))
    }
}

/// R.accepted[w] is R's last vote for w (I3 of TPTP's A2 in this setting).
pub open spec fn accepted_ok(cfg: Config, s: SystemState, r: int) -> bool {
    forall|w: int| #[trigger] s.replicas[r].accepted.contains_key(w) ==> {
        let acc = s.replicas[r].accepted[w];
        &&& voted_for(s, r, w, acc_bal(acc), acc.val)
        &&& wf_bal(acc_bal(acc))
    }
}

/// Every FastAck(w, c) r sent: r's last normal view is at least w, and while it is w, c is
/// still in r's pool or committed on the original path (N14, N21, N24 remove only committed
/// commands).
pub open spec fn acks_ok(cfg: Config, s: SystemState, r: int) -> bool {
    forall|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is FastAck ==> {
        &&& s.replicas[r].lnv >= p.msg->FastAck_view
        &&& (s.replicas[r].lnv == p.msg->FastAck_view
            ==> s.replicas[r].pool.contains(p.msg->FastAck_cmd) || committed_cmd(cfg, s, p.msg->FastAck_cmd))
    }
}

/// A PrepareOK(v, w, k, body) r sent (L16-L20): r's promise for w is at least (v, k) and its
/// new_view at least v. If body is r's accepted triple: that triple is a vote below (v, k) and
/// no vote of r for w below (v, k) is above it. If body is a pool: r has no vote for w below
/// (v, k), and the pool holds every command r ack'd in w that is not committed (the snapshot;
/// r never acks in w again since new_view >= v > w).
pub open spec fn pok_ok(cfg: Config, s: SystemState, r: int, v: int, w: int, k: int, body: PrepareOkBody) -> bool {
    let b = Bal { v: v, k: k };
    &&& bal_le(b, promise(s, r, w))
    &&& s.replicas[r].nv >= v
    &&& match body {
        PrepareOkBody::Accepted { acc } => {
            &&& bal_lt(acc_bal(acc), b)
            &&& voted_for(s, r, w, acc_bal(acc), acc.val)
            &&& forall|vt: Vote| #[trigger] s.votes.contains(vt) && vt.r == r && vt.vn == w && bal_lt(vt.bal, b) ==> bal_le(vt.bal, acc_bal(acc))
        },
        PrepareOkBody::Pool { pool } => {
            &&& forall|vt: Vote| #[trigger] s.votes.contains(vt) && vt.r == r && vt.vn == w ==> bal_le(b, vt.bal)
            &&& forall|p2: Packet| #[trigger] s.network.contains(p2) && p2.src == (Addr::Replica { id: r }) && p2.msg is FastAck && p2.msg->FastAck_view == w
                ==> pool.contains(p2.msg->FastAck_cmd) || committed_cmd(cfg, s, p2.msg->FastAck_cmd)
        },
    }
}

pub open spec fn poks_ok(cfg: Config, s: SystemState, r: int) -> bool {
    forall|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg is PrepareOK
        ==> pok_ok(cfg, s, r, p.msg->PrepareOK_view, p.msg->PrepareOK_vn, p.msg->PrepareOK_k, p.msg->PrepareOK_body)
}

/// A vote of the history: cast by a replica at a real ballot of a view above w, at or below its
/// promise, for a value safe at that ballot that some Accept proposed; the voter's accepted[w]
/// is at or above it.
pub open spec fn vote_ok(cfg: Config, s: SystemState, vt: Vote) -> bool {
    &&& cfg.replicas.contains(vt.r)
    &&& wf_bal(vt.bal)
    &&& 0 <= vt.vn < vt.bal.v
    &&& bal_le(vt.bal, promise(s, vt.r, vt.vn))
    &&& safe_at(cfg, s, vt.vn, vt.bal, vt.val)
    &&& accept_in_net(s, vt.bal, vt.vn, vt.val)
    &&& s.replicas[vt.r].accepted.contains_key(vt.vn)
    &&& bal_le(vt.bal, acc_bal(s.replicas[vt.r].accepted[vt.vn]))
}

/// A packet in the network: the facts that do not depend on the sender's current state.
pub open spec fn msg_ok(cfg: Config, s: SystemState, p: Packet) -> bool {
    match p.msg {
        Msg::FastCmd { view, cmd } => p.src is Client,
        Msg::FastAck { view, cmd } => {
            &&& p.src is Replica
            &&& cfg.replicas.contains(p.src->Replica_id)
            &&& v0() <= view <= s.base_view
        },
        Msg::FastNack { lnv, mode } => v0() <= lnv <= s.base_view,
        Msg::Evict { cmd } => committed_cmd(cfg, s, cmd),
        Msg::BeginRecovery { view } => v0() <= view <= s.base_view,
        Msg::BeginRecoveryOK { view, lnv } => v0() <= lnv < view <= s.base_view,
        Msg::Prepare { view, vn, k } => bot() <= vn < view <= s.base_view && k >= 0,
        Msg::PrepareOK { view, vn, k, body } => {
            &&& p.src is Replica
            &&& cfg.replicas.contains(p.src->Replica_id)
            &&& v0() <= vn < view <= s.base_view
            &&& k >= 0
        },
        Msg::Accept { view, vn, k, rset } => {
            &&& v0() <= vn < view <= s.base_view
            &&& k >= 0
            &&& p.src == (Addr::Replica { id: (cfg.proposer)(view) })
            &&& safe_at(cfg, s, vn, Bal { v: view, k: k }, rset)
            &&& value_ok(cfg, s, vn, rset)
        },
        Msg::AcceptOK { view, vn, k } => {
            &&& p.src is Replica
            &&& cfg.replicas.contains(p.src->Replica_id)
            &&& exists|val: Set<int>| #[trigger] voted_for(s, p.src->Replica_id, vn, Bal { v: view, k: k }, val)
        },
        Msg::Nack { new_view, lnv, k } => v0() <= lnv <= s.base_view,
        Msg::FinishRecovery { view, vn, rset } => {
            &&& v0() <= vn < view <= s.base_view
            &&& chosen(cfg, s, vn, rset)
            &&& value_ok(cfg, s, vn, rset)
        },
        Msg::FinishRecoveryOK { view } => true,
    }
}

/// One recovery set per (view, v_n, k) (Prepare's strict > with one coordinator per view).
pub open spec fn one_decree(s: SystemState) -> bool {
    forall|p1: Packet, p2: Packet|
        #[trigger] s.network.contains(p1) && #[trigger] s.network.contains(p2)
        && p1.msg is Accept && p2.msg is Accept
        && p1.msg->Accept_view == p2.msg->Accept_view && p1.msg->Accept_vn == p2.msg->Accept_vn && p1.msg->Accept_k == p2.msg->Accept_k
        ==> p1.msg->Accept_rset == p2.msg->Accept_rset
}

/// A Recovered entry of the original log: it recovers a view below its own, its set is chosen
/// by the recovery Paxos of that view and respects the snapshots.
pub open spec fn recovered_ok(cfg: Config, s: SystemState, e: Entry) -> bool {
    &&& v0() <= e->Recovered_vn < e->Recovered_view
    &&& chosen(cfg, s, e->Recovered_vn, e->Recovered_cmds)
    &&& value_ok(cfg, s, e->Recovered_vn, e->Recovered_cmds)
}

/// The one original log: views of entries are within the base view and non-decreasing along
/// the log; a Cmd of a view other than v_0 is preceded by a Recovered of its view (T2); every
/// Recovered entry is `recovered_ok`.
pub open spec fn log_ok(cfg: Config, s: SystemState) -> bool {
    &&& 0 <= s.committed <= s.log.len()
    &&& forall|j: int| 0 <= j < s.log.len() ==> v0() <= entry_view(#[trigger] s.log[j]) <= s.base_view
    &&& forall|i: int, j: int| 0 <= i < j < s.log.len() ==> entry_view(#[trigger] s.log[i]) <= entry_view(#[trigger] s.log[j])
    &&& forall|j: int| 0 <= j < s.log.len() && #[trigger] s.log[j] is Cmd && entry_view(s.log[j]) != v0()
        ==> exists|i: int| 0 <= i < j && #[trigger] s.log[i] is Recovered && entry_view(s.log[i]) == entry_view(s.log[j])
    &&& forall|j: int| 0 <= j < s.log.len() && #[trigger] s.log[j] is Recovered ==> recovered_ok(cfg, s, s.log[j])
}

/// Client k: its view is one of the original protocol's; every fast commit it decided is one.
pub open spec fn client_ok(cfg: Config, s: SystemState, k: int) -> bool {
    &&& v0() <= s.clients[k].view <= s.base_view
    &&& forall|fc: FastCommit| #[trigger] s.clients[k].fast.contains(fc) ==> fast_committed(cfg, s, fc.view, fc.cmd)
}

/// The inductive invariant.
pub open spec fn inv(cfg: Config, s: SystemState) -> bool {
    &&& s.replicas.dom() == cfg.replicas
    &&& s.clients.dom() == cfg.clients
    &&& v0() <= s.base_view
    &&& log_ok(cfg, s)
    &&& forall|r: int| #[trigger] cfg.replicas.contains(r) ==> {
        &&& replica_wf(cfg, s, r)
        &&& coord_ok(cfg, s, r)
        &&& accepted_ok(cfg, s, r)
        &&& acks_ok(cfg, s, r)
        &&& poks_ok(cfg, s, r)
    }
    &&& forall|vt: Vote| #[trigger] s.votes.contains(vt) ==> vote_ok(cfg, s, vt)
    &&& forall|p: Packet| #[trigger] s.network.contains(p) ==> msg_ok(cfg, s, p)
    &&& one_decree(s)
    &&& forall|k: int| #[trigger] cfg.clients.contains(k) ==> client_ok(cfg, s, k)
}

// ---------------------------------------------------------------------------------------------
// What a step preserves about the past
// ---------------------------------------------------------------------------------------------

/// A replica's state only grows: views, committed prefix, log copy (as a prefix), promises
/// (lexicographically, for every w); accepted[w] is kept or replaced by a vote at or above the
/// old promise.
pub open spec fn replica_mono(a: ReplicaState, b: ReplicaState) -> bool {
    &&& a.lnv <= b.lnv
    &&& a.nv <= b.nv
    &&& a.committed <= b.committed
    &&& a.olog.len() <= b.olog.len()
    &&& forall|j: int| 0 <= j < a.olog.len() ==> #[trigger] b.olog[j] == a.olog[j]
    &&& forall|w: int| bal_le(promise_of(a, w), #[trigger] promise_of(b, w))
    &&& forall|w: int| #[trigger] a.accepted.contains_key(w) ==> {
        &&& b.accepted.contains_key(w)
        &&& (b.accepted[w] == a.accepted[w] || bal_le(promise_of(a, w), acc_bal(b.accepted[w])))
    }
}

/// Every step: the network, the vote history, the base view, the one log and its committed
/// prefix only grow; the domains stay; every replica is `replica_mono`; a new vote is cast by
/// a replica at a ballot at least its promise before the step.
pub open spec fn mono(cfg: Config, s: SystemState, s_: SystemState) -> bool {
    &&& s.network.subset_of(s_.network)
    &&& s.votes.subset_of(s_.votes)
    &&& s_.replicas.dom() == s.replicas.dom()
    &&& s_.clients.dom() == s.clients.dom()
    &&& s.base_view <= s_.base_view
    &&& s.log.len() <= s_.log.len()
    &&& forall|j: int| 0 <= j < s.log.len() ==> #[trigger] s_.log[j] == s.log[j]
    &&& s.committed <= s_.committed
    &&& forall|r: int| #[trigger] cfg.replicas.contains(r) ==> replica_mono(s.replicas[r], s_.replicas[r])
    &&& forall|vt: Vote| #[trigger] s_.votes.contains(vt) && !s.votes.contains(vt)
        ==> cfg.replicas.contains(vt.r) && bal_le(promise(s, vt.r, vt.vn), vt.bal)
}

} // verus!
