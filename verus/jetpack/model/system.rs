//! The whole system: state, `Init`, `Next`, and the original protocol as an oracle
//! (docs/pseudocode.md §0 assumptions A1-A3, T1-T2, N11, N19-N20). Definitions only, trusted.
//!
//! The original protocol. One original log `log` exists; each replica's `olog` is a prefix of it
//! (A2: a committed command's position never changes) and each replica's `committed` is at most
//! the global `committed` (A1: committed commands are never lost; A3: executed = committed
//! prefix). The proposer of the current base view appends to `log` (N11, N19-N20), after its
//! Recovered(S) of that view is committed (T1-T2), except Recovered entries themselves (L47,
//! L53). `NewView(v)` is the original protocol electing the proposer of v: it starts a
//! coordinator (T1, L1-L3). Uncommitted tails never diverge in this oracle (PROGRESS.md).
//! The network is the set of every packet ever sent; a delivery reads a packet and leaves it.
use crate::common::trace::is_behavior;
use crate::model::client::*;
use crate::model::replica::*;
use crate::model::types::*;
use vstd::prelude::*;

verus! {

pub struct SystemState {
    /// Each replica's state; the domain is `Config::replicas`.
    pub replicas: Map<int, ReplicaState>,
    /// Each client's state; the domain is `Config::clients`.
    pub clients: Map<int, ClientState>,
    /// The network: every packet ever sent. Never shrinks.
    pub network: Set<Packet>,
    /// Oracle: the current view of the original protocol (the latest view it started).
    pub base_view: int,
    /// Oracle: the one original log.
    pub log: Seq<Entry>,
    /// Oracle: the length of the committed prefix of `log`.
    pub committed: int,
    /// Ghost: every vote of the recovery Paxos ever cast (L37). Read by no action.
    pub votes: Set<Vote>,
}

pub open spec fn replica_consts(cfg: Config, r: int) -> ReplicaConsts {
    ReplicaConsts { me: r, replicas: cfg.replicas, proposer: cfg.proposer, conflicts: cfg.conflicts }
}

pub open spec fn client_consts(cfg: Config, k: int) -> ClientConsts {
    ClientConsts { me: k, replicas: cfg.replicas, proposer: cfg.proposer }
}

/// the pseudocode §0 "Initially": every replica in v_0, Normal, all slots empty; the original log empty.
pub open spec fn Init(cfg: Config, s: SystemState) -> bool {
    &&& s.replicas == Map::<int, ReplicaState>::new(cfg.replicas, |r: int| replica_init())
    &&& s.clients == Map::<int, ClientState>::new(cfg.clients, |k: int| client_init())
    &&& s.network == Set::<Packet>::empty()
    &&& s.base_view == v0()
    &&& s.log == Seq::<Entry>::empty()
    &&& s.committed == 0
    &&& s.votes == Set::<Vote>::empty()
}

// ---------------------------------------------------------------------------------------------
// Replica steps, with their effect on the original log
// ---------------------------------------------------------------------------------------------

/// Whether `log` holds a Recovered entry of view `v` (L52: the proposer "has submitted a
/// Recovered(·) in v").
pub open spec fn has_recovered_in(log: Seq<Entry>, v: int) -> bool {
    exists|j: int| 0 <= j < log.len() && #[trigger] log[j] is Recovered && log[j]->Recovered_view == v
}

/// Ghost record of a replica step: the vote it casts (L37), from the step's own parameters.
pub open spec fn votes_cast(r: int, s: ReplicaState, step: ReplicaStep) -> Set<Vote> {
    match step {
        ReplicaStep::RecvAccept { pkt } => {
            let v = pkt.msg->Accept_view;
            let vn = pkt.msg->Accept_vn;
            let k = pkt.msg->Accept_k;
            if pkt.msg is Accept && accept_taken(s, v, vn, k) {
                set![Vote { r: r, vn: vn, bal: Bal { v: v, k: k }, val: pkt.msg->Accept_rset }]
            } else {
                Set::<Vote>::empty()
            }
        },
        _ => Set::<Vote>::empty(),
    }
}

/// L47: C submits Recovered(C.rset) to its own proposer, which appends it in the current view.
pub open spec fn accept_ok_appends(cfg: Config, s: SystemState, r: int) -> Seq<Entry> {
    seq![recovered_entry(s.replicas[r].coord)]
}

/// L52-L53: after learn(v), if R.new_view = v and R is the proposer of v and has not yet
/// submitted a Recovered(·) in v, R submits Recovered(S) to its original replica, which appends
/// it if v is still the current view (else the submission is lost with the deposed proposer).
pub open spec fn finish_appends(cfg: Config, s: SystemState, r: int, pkt: Packet) -> Seq<Entry> {
    let v = pkt.msg->FinishRecovery_view;
    let st = learn(s.replicas[r], v);
    if st.nv == v && (cfg.proposer)(v) == r && !has_recovered_in(s.log, v) && s.base_view == v {
        seq![Entry::Recovered { view: v, vn: pkt.msg->FinishRecovery_vn, cmds: pkt.msg->FinishRecovery_rset }]
    } else {
        Seq::<Entry>::empty()
    }
}

/// The entries a replica step appends to the original log.
pub open spec fn step_appends(cfg: Config, s: SystemState, r: int, step: ReplicaStep) -> Seq<Entry> {
    match step {
        ReplicaStep::CoordAcceptOK { pkts, m } => accept_ok_appends(cfg, s, r),
        ReplicaStep::RecvFinishRecovery { pkt } => finish_appends(cfg, s, r, pkt),
        _ => Seq::<Entry>::empty(),
    }
}

/// What the original protocol requires of a replica step that appends: L47's append goes
/// through C's proposer, which must be the proposer of the current view, in C.view.
pub open spec fn step_base_guard(cfg: Config, s: SystemState, r: int, step: ReplicaStep) -> bool {
    match step {
        ReplicaStep::CoordAcceptOK { pkts, m } => s.base_view == s.replicas[r].coord.view && (cfg.proposer)(s.base_view) == r,
        _ => true,
    }
}

/// A step of replica `r`: the packets it receives are in the network and addressed to it; it
/// takes `step`; its packets join the network; its vote joins the history; what it submits to
/// the original protocol joins the log.
pub open spec fn ReplicaNodeStep(cfg: Config, s: SystemState, s_: SystemState, r: int, step: ReplicaStep, sent: Set<Packet>) -> bool {
    &&& cfg.replicas.contains(r)
    &&& forall|pkt: Packet| #[trigger] replica_received(step).contains(pkt)
        ==> s.network.contains(pkt) && pkt.dst == (Addr::Replica { id: r })
    &&& ReplicaNext(replica_consts(cfg, r), s.replicas[r], s_.replicas[r], step, sent)
    &&& step_base_guard(cfg, s, r, step)
    &&& s_ == SystemState {
        replicas: s.replicas.insert(r, s_.replicas[r]),
        network: s.network.union(sent),
        log: s.log + step_appends(cfg, s, r, step),
        votes: s.votes.union(votes_cast(r, s.replicas[r], step)),
        ..s
    }
}

/// A step of client `k`.
pub open spec fn ClientNodeStep(cfg: Config, s: SystemState, s_: SystemState, k: int, step: ClientStep, sent: Set<Packet>) -> bool {
    &&& cfg.clients.contains(k)
    &&& forall|pkt: Packet| #[trigger] client_received(step).contains(pkt)
        ==> s.network.contains(pkt) && pkt.dst == (Addr::Client { id: k })
    &&& ClientNext(client_consts(cfg, k), s.clients[k], s_.clients[k], step, sent)
    &&& s_ == SystemState { clients: s.clients.insert(k, s_.clients[k]), network: s.network.union(sent), ..s }
}

// ---------------------------------------------------------------------------------------------
// The original protocol (oracle)
// ---------------------------------------------------------------------------------------------

/// The proposer of the current view may propose (T1-T2): v_0 needs no recovery; in any later
/// view its Recovered(S) must be committed first.
pub open spec fn can_propose(cfg: Config, s: SystemState) -> bool {
    ||| s.base_view == v0()
    ||| exists|j: int| 0 <= j < s.committed && #[trigger] s.log[j] is Recovered && s.log[j]->Recovered_view == s.base_view
}

/// The original protocol starts view v (elects its proposer): v is newer than every view so
/// far; the proposer's Jetpack replica becomes coordinator C for v (T1): C.view ← v, C.k ← 0
/// (L1-L2), BeginRecovery(v) to replicas(v) (L3).
pub open spec fn NewView(cfg: Config, s: SystemState, s_: SystemState, v: int) -> bool {
    let p = (cfg.proposer)(v);
    let c = replica_consts(cfg, p);
    &&& v > s.base_view
    &&& cfg.replicas.contains(p)
    &&& s_ == SystemState {
        base_view: v,
        replicas: s.replicas.insert(p, ReplicaState {
            coord: Coord { phase: Phase::P1, view: v, vn: bot(), k: 0, rset: Set::<int>::empty() },
            ..s.replicas[p]
        }),
        network: s.network.union(broadcast(c, Msg::BeginRecovery { view: v })),
        ..s
    }
}

/// The proposer of the current view appends command c (N11, N19-N20 Propose(c)), once it may
/// propose (T2).
pub open spec fn AppendCmd(cfg: Config, s: SystemState, s_: SystemState, cmd: int) -> bool {
    &&& can_propose(cfg, s)
    &&& s_ == SystemState { log: s.log.push(Entry::Cmd { view: s.base_view, cmd: cmd }), ..s }
}

/// Replica r's copy of the original log catches up to a longer prefix of it.
pub open spec fn Replicate(cfg: Config, s: SystemState, s_: SystemState, r: int, m: int) -> bool {
    &&& cfg.replicas.contains(r)
    &&& s.replicas[r].olog.len() <= m <= s.log.len()
    &&& s_ == SystemState {
        replicas: s.replicas.insert(r, ReplicaState { olog: s.log.subrange(0, m), ..s.replicas[r] }),
        ..s
    }
}

/// The original protocol commits a longer prefix of its log (A1, A2).
pub open spec fn AdvanceCommit(cfg: Config, s: SystemState, s_: SystemState, m: int) -> bool {
    &&& s.committed <= m <= s.log.len()
    &&& s_ == SystemState { committed: m, ..s }
}

/// Replica r learns that a longer prefix of its copy is committed, and executes it (A3).
pub open spec fn ReplicaCommit(cfg: Config, s: SystemState, s_: SystemState, r: int, m: int) -> bool {
    &&& cfg.replicas.contains(r)
    &&& s.replicas[r].committed <= m <= s.committed
    &&& m <= s.replicas[r].olog.len()
    &&& s_ == SystemState {
        replicas: s.replicas.insert(r, ReplicaState { committed: m, ..s.replicas[r] }),
        ..s
    }
}

// ---------------------------------------------------------------------------------------------
// Next
// ---------------------------------------------------------------------------------------------

#[allow(inconsistent_fields)]
pub enum SysStep {
    Replica { r: int, step: ReplicaStep, sent: Set<Packet> },
    Client { k: int, step: ClientStep, sent: Set<Packet> },
    NewView { v: int },
    AppendCmd { cmd: int },
    Replicate { r: int, m: int },
    AdvanceCommit { m: int },
    ReplicaCommit { r: int, m: int },
}

pub open spec fn NextStep(cfg: Config, s: SystemState, s_: SystemState, step: SysStep) -> bool {
    match step {
        SysStep::Replica { r, step, sent } => ReplicaNodeStep(cfg, s, s_, r, step, sent),
        SysStep::Client { k, step, sent } => ClientNodeStep(cfg, s, s_, k, step, sent),
        SysStep::NewView { v } => NewView(cfg, s, s_, v),
        SysStep::AppendCmd { cmd } => AppendCmd(cfg, s, s_, cmd),
        SysStep::Replicate { r, m } => Replicate(cfg, s, s_, r, m),
        SysStep::AdvanceCommit { m } => AdvanceCommit(cfg, s, s_, m),
        SysStep::ReplicaCommit { r, m } => ReplicaCommit(cfg, s, s_, r, m),
    }
}

pub open spec fn Next(cfg: Config, s: SystemState, s_: SystemState) -> bool {
    exists|step: SysStep| #[trigger] NextStep(cfg, s, s_, step)
}

/// The first state satisfies `Init`, every two consecutive states satisfy `Next`.
pub open spec fn IsValidBehavior(cfg: Config, tr: Seq<SystemState>) -> bool {
    is_behavior(|s: SystemState| Init(cfg, s), |s: SystemState, s_: SystemState| Next(cfg, s, s_), tr)
}

} // verus!
