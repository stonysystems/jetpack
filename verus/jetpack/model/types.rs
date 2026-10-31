//! Constants, views, quorum sizes, ballots, log entries, messages and packets of the Jetpack the pseudocode
//! model (docs/pseudocode.md §0). Definitions only, trusted.
//!
//! Views. the pseudocode §0: "a view is a record provided by the original protocol: v.id, v.replicas,
//! v.proposers ... the id determines the record uniquely". Membership is constant here (A6 and
//! reconfiguration are not modeled, PROGRESS.md), so the record of view `id` is
//! `View { id, proposers: proposers(cfg, id) }` with `proposers` a constant function of the
//! configuration: every node knows it, and states and messages carry the id (`view(cfg, id)` is
//! the record). The single-proposer case is modeled: `proposers(cfg, v) = {(cfg.proposer)(v)}`.
use vstd::prelude::*;

verus! {

/// ⊥: the null view, smaller than every view, and the null ballot (the pseudocode §0). View ids and ballots
/// are the integers >= 0.
pub open spec fn bot() -> int {
    -1
}

/// The initial view v_0 (the pseudocode §0 "Initially").
pub open spec fn v0() -> int {
    0
}

/// What every node knows from the start.
pub struct Config {
    /// replicas(v) for every view v: the membership never changes (A6 not modeled).
    pub replicas: Set<int>,
    /// The fast-path clients.
    pub clients: Set<int>,
    /// proposers(v) = {proposer(v)}: the one original-path proposer of view v (single-proposer
    /// case; Raft's leader of term v).
    pub proposer: spec_fn(int) -> int,
    /// Whether two commands conflict (the pseudocode §1 notes: same key, one of them a write).
    pub conflicts: spec_fn(int, int) -> bool,
}

/// The view record of id `id` (the pseudocode §0).
pub struct View {
    pub id: int,
    pub proposers: Set<int>,
}

pub open spec fn proposers(cfg: Config, v: int) -> Set<int> {
    set![(cfg.proposer)(v)]
}

pub open spec fn view(cfg: Config, id: int) -> View {
    View { id: id, proposers: proposers(cfg, id) }
}

/// n(v) = |v.replicas| (the pseudocode §0), the same for every view.
pub open spec fn n(cfg: Config) -> int {
    cfg.replicas.len() as int
}

/// maj(v) = ⌊n/2⌋ + 1 (the pseudocode §0).
pub open spec fn maj(cfg: Config) -> int {
    n(cfg) / 2 + 1
}

/// t(v) = ⌊maj/2⌋ + 1 (the pseudocode §0).
pub open spec fn t(cfg: Config) -> int {
    maj(cfg) / 2 + 1
}

/// sq(v) = n − maj + t (the pseudocode §0).
pub open spec fn sq(cfg: Config) -> int {
    n(cfg) - maj(cfg) + t(cfg)
}

pub enum Mode {
    Normal,
    Recovery,
}

/// An entry of the original protocol's log. `view` is the view in which the proposer appended
/// it (Raft: its term). `Recovered` records the fast-path view `vn` it recovers (the pseudocode L47, L53;
/// the model records vn in the entry so that properties can name it, PROGRESS.md).
pub enum Entry {
    Cmd { view: int, cmd: int },
    Recovered { view: int, vn: int, cmds: Set<int> },
}

pub open spec fn entry_view(e: Entry) -> int {
    match e {
        Entry::Cmd { view, cmd } => view,
        Entry::Recovered { view, vn, cmds } => view,
    }
}

/// The commands an entry carries: one for `Cmd`, the recovery set for `Recovered` (L50).
pub open spec fn entry_cmds(e: Entry) -> Set<int> {
    match e {
        Entry::Cmd { view, cmd } => set![cmd],
        Entry::Recovered { view, vn, cmds } => cmds,
    }
}

/// A ballot of the recovery Paxos for one fast-path view: the new view `v` first, then the
/// counter `k` within it (the pseudocode §0 "compare views first, then ballots"; §2 notes "equivalent to
/// comparing (view, k) lexicographically").
pub struct Bal {
    pub v: int,
    pub k: int,
}

pub open spec fn bal_lt(a: Bal, b: Bal) -> bool {
    a.v < b.v || (a.v == b.v && a.k < b.k)
}

pub open spec fn bal_le(a: Bal, b: Bal) -> bool {
    bal_lt(a, b) || a == b
}

/// A real ballot: a view id and a counter, both >= 0 (a promise may hold k = ⊥ = −1).
pub open spec fn wf_bal(b: Bal) -> bool {
    b.v >= 0 && b.k >= 0
}

/// R.accepted[w]: (accepted_view, accepted_ballot, accepted_value) (the pseudocode §0).
pub struct Acc {
    pub view: int,
    pub k: int,
    pub val: Set<int>,
}

pub open spec fn acc_bal(a: Acc) -> Bal {
    Bal { v: a.view, k: a.k }
}

/// What a PrepareOK carries: the accepted triple (L18) or the pool (L20).
pub enum PrepareOkBody {
    Accepted { acc: Acc },
    Pool { pool: Set<int> },
}

#[allow(inconsistent_fields)]
pub enum Msg {
    /// FastCmd(v, c) (N1).
    FastCmd { view: int, cmd: int },
    /// FastAck(v, c, r) (N16); the result r is not modeled (PROGRESS.md).
    FastAck { view: int, cmd: int },
    /// FastNack(R.last_normal_view, R.mode) (N18).
    FastNack { lnv: int, mode: Mode },
    /// The evict notice for c (N23).
    Evict { cmd: int },
    /// BeginRecovery(v) (L3).
    BeginRecovery { view: int },
    /// BeginRecoveryOK(v, R.last_normal_view) (L6).
    BeginRecoveryOK { view: int, lnv: int },
    /// Prepare(v, v_n, k) (L10).
    Prepare { view: int, vn: int, k: int },
    /// PrepareOK(v, v_n, k, R.accepted[v_n]) (L18) or PrepareOK(v, v_n, k, R.pool[v_n]) (L20).
    PrepareOK { view: int, vn: int, k: int, body: PrepareOkBody },
    /// Accept(v, v_n, k, S) (L30).
    Accept { view: int, vn: int, k: int, rset: Set<int> },
    /// AcceptOK(v, v_n, k) (L38).
    AcceptOK { view: int, vn: int, k: int },
    /// Nack(R.new_view, R.last_normal_view, k') with k' = ⊥ (L8, L12, L32) or
    /// k' = R.max_seen_ballot[v_n] (L22, L40).
    Nack { new_view: int, lnv: int, k: Option<int> },
    /// FinishRecovery(v, S) (L48). `vn` = C.v_n is added by the model so that the Recovered
    /// entry of L53 records the view it recovers; no guard reads it (PROGRESS.md).
    FinishRecovery { view: int, vn: int, rset: Set<int> },
    /// FinishRecoveryOK(v) (L54).
    FinishRecoveryOK { view: int },
}

pub enum Addr {
    Replica { id: int },
    Client { id: int },
}

/// A message in the network with its sender and its receiver.
pub struct Packet {
    pub src: Addr,
    pub dst: Addr,
    pub msg: Msg,
}

/// Ghost: replica `r` accepted value `val` for the recovery of fast-path view `vn` at ballot
/// `bal` (L37). The history of the recovery Paxos, written by `RecvAccept`, read by no action.
pub struct Vote {
    pub r: int,
    pub vn: int,
    pub bal: Bal,
    pub val: Set<int>,
}

} // verus!
