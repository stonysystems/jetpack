//! A Jetpack replica R and the coordinator C co-located with it (docs/pseudocode.md §0, §1
//! N12-N24, §2 L1-L54). Definitions only, trusted.
//!
//! Every action is a relation between the replica's state before (`s`) and after (`s_`), given
//! its constants `c`, the packets it receives (parameters), the parameters that resolve its
//! nondeterminism, and the exact set `sent` of packets it sends. The actions that also touch the
//! original protocol's log (L47, L53) are completed in `system.rs`. `s_ == ReplicaState { f: ..,
//! ..s }` lists the changed fields; every other field is unchanged. `FIDELITY.md` maps each line.
use crate::model::types::*;
use vstd::prelude::*;

verus! {

/// The coordinator's progress through L1-L49. `Idle`: not coordinating. `P1`: BeginRecovery
/// sent (L3). `P2a`: Prepare sent (L10). `P2b`: Accept sent (L30). `P3`: Recovered submitted
/// (L47). `Done`: FinishRecovery sent (L48). `Stopped`: L42.
pub enum Phase {
    Idle,
    P1,
    P2a,
    P2b,
    P3,
    Done,
    Stopped,
}

/// Coordinator C (the pseudocode §0): C.view, C.v_n, C.k, C.rset, and where it is.
pub struct Coord {
    pub phase: Phase,
    pub view: int,
    pub vn: int,
    pub k: int,
    pub rset: Set<int>,
}

/// Jetpack replica R (the pseudocode §0), with its copy of the original protocol's log.
pub struct ReplicaState {
    /// R.last_normal_view (= v_n, the current fast-path view).
    pub lnv: int,
    /// R.new_view (= v, the latest view whose recovery R joined).
    pub nv: int,
    /// R.mode.
    pub mode: Mode,
    /// R.pool[R.last_normal_view]: the cmds R ack'd while R.last_normal_view had its current
    /// value. the pseudocode reads only pool[last_normal_view] (L20 after learn(v_n) gives
    /// last_normal_view = v_n), so one set suffices; it is empty when last_normal_view advances
    /// (R never ack'd in the new view) (PROGRESS.md).
    pub pool: Set<int>,
    /// R.max_seen_ballot[w]; a view absent from the map is ⊥.
    pub msb: Map<int, int>,
    /// R.accepted[w]; a view absent from the map is ⊥.
    pub accepted: Map<int, Acc>,
    /// The coordinator co-located with R (T1).
    pub coord: Coord,
    /// R.olog: the original protocol's log as R has it (a prefix of the one original log,
    /// `system.rs`). Jetpack only reads it.
    pub olog: Seq<Entry>,
    /// The length of the committed (and executed, A3) prefix of R.olog.
    pub committed: int,
}

pub struct ReplicaConsts {
    pub me: int,
    pub replicas: Set<int>,
    pub proposer: spec_fn(int) -> int,
    pub conflicts: spec_fn(int, int) -> bool,
}

pub open spec fn c_maj(c: ReplicaConsts) -> int {
    (c.replicas.len() as int) / 2 + 1
}

pub open spec fn c_t(c: ReplicaConsts) -> int {
    c_maj(c) / 2 + 1
}

/// Initially (the pseudocode §0): R.last_normal_view = R.new_view = v_0, R.mode = Normal, all slots
/// empty / ⊥; no coordinator; an empty copy of the original log.
pub open spec fn replica_init() -> ReplicaState {
    ReplicaState {
        lnv: v0(),
        nv: v0(),
        mode: Mode::Normal,
        pool: Set::<int>::empty(),
        msb: Map::<int, int>::empty(),
        accepted: Map::<int, Acc>::empty(),
        coord: Coord { phase: Phase::Idle, view: bot(), vn: bot(), k: 0, rset: Set::<int>::empty() },
        olog: Seq::<Entry>::empty(),
        committed: 0,
    }
}

/// R.max_seen_ballot[w], ⊥ = −1 when unset.
pub open spec fn msb_of(s: ReplicaState, w: int) -> int {
    if s.msb.contains_key(w) {
        s.msb[w]
    } else {
        bot()
    }
}

/// R.pool[w]: R's pool if w is R's last normal view, else empty (R never ack'd in w).
pub open spec fn pool_of(s: ReplicaState, w: int) -> Set<int> {
    if s.lnv == w {
        s.pool
    } else {
        Set::<int>::empty()
    }
}

/// join(v) (the pseudocode §0): R.new_view ← v; R.mode ← Recovery; R.max_seen_ballot[w] ← ⊥ for every w;
/// R.accepted[·] is kept.
pub open spec fn join(s: ReplicaState, v: int) -> ReplicaState {
    ReplicaState { nv: v, mode: Mode::Recovery, msb: Map::<int, int>::empty(), ..s }
}

/// learn(u) (the pseudocode §0): if u > R.last_normal_view then if u >= R.new_view then
/// R.last_normal_view ← u; R.new_view ← u; R.mode ← Normal, else R.last_normal_view ← u.
/// When last_normal_view advances the pool of the new view is empty (R never ack'd in u).
pub open spec fn learn(s: ReplicaState, u: int) -> ReplicaState {
    if u > s.lnv {
        if u >= s.nv {
            ReplicaState { lnv: u, nv: u, mode: Mode::Normal, pool: Set::<int>::empty(), ..s }
        } else {
            ReplicaState { lnv: u, pool: Set::<int>::empty(), ..s }
        }
    } else {
        s
    }
}

/// The commands of the entries log[from..to].
pub open spec fn cmds_in(log: Seq<Entry>, from: int, to: int) -> Set<int>
    decreases to - from,
{
    if from >= to {
        Set::<int>::empty()
    } else {
        entry_cmds(log[from]).union(cmds_in(log, from + 1, to))
    }
}

/// Pending(R.olog) (the pseudocode §0): the commands of the entries R has not executed yet.
pub open spec fn pending_cmds(s: ReplicaState) -> Set<int> {
    cmds_in(s.olog, s.committed, s.olog.len() as int)
}

/// c conflicts with no cmd in `cmds` (N13).
pub open spec fn no_conflict(c: ReplicaConsts, cmd: int, cmds: Set<int>) -> bool {
    forall|d: int| #[trigger] cmds.contains(d) ==> !(c.conflicts)(cmd, d)
}

pub open spec fn me(c: ReplicaConsts) -> Addr {
    Addr::Replica { id: c.me }
}

/// One packet from this replica to `dst`.
pub open spec fn send_to(c: ReplicaConsts, dst: Addr, m: Msg) -> Set<Packet> {
    set![Packet { src: me(c), dst: dst, msg: m }]
}

/// The packet from `src` to replica `r` carrying `m`.
pub open spec fn to_replica(src: Addr, m: Msg, r: int) -> Packet {
    Packet { src: src, dst: Addr::Replica { id: r }, msg: m }
}

/// The replica a packet is addressed to.
pub open spec fn dst_replica(p: Packet) -> int {
    p.dst->Replica_id
}

/// One packet from `src` to every replica of `replicas` carrying `m` (replicas(v) for every v).
pub open spec fn to_replicas(replicas: Set<int>, src: Addr, m: Msg) -> Set<Packet> {
    replicas.map_by(|r: int| to_replica(src, m, r), |p: Packet| dst_replica(p))
}

/// One packet from this replica to every replica.
pub open spec fn broadcast(c: ReplicaConsts, m: Msg) -> Set<Packet> {
    to_replicas(c.replicas, me(c), m)
}

// ---------------------------------------------------------------------------------------------
// §1 normal path: the replica side (N12-N24)
// ---------------------------------------------------------------------------------------------

/// Jetpack replica R, on receiving FastCmd(v, c) (N12-N18). N15's result and N19-N20's
/// Propose(c) are the original protocol's: `system.rs` `AppendCmd` (PROGRESS.md).
pub open spec fn RecvFastCmd(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is FastCmd
    &&& {
        let v = pkt.msg->FastCmd_view;
        let cmd = pkt.msg->FastCmd_cmd;
        if v == s.lnv && s.mode is Normal && no_conflict(c, cmd, s.pool.union(pending_cmds(s))) {   // N12-N13
            &&& s_ == ReplicaState { pool: s.pool.insert(cmd), ..s }                                 // N14
            &&& sent == send_to(c, pkt.src, Msg::FastAck { view: v, cmd: cmd })                      // N16
        } else if v != s.lnv || s.mode is Recovery {                                                 // N17
            &&& s_ == s
            &&& sent == send_to(c, pkt.src, Msg::FastNack { lnv: s.lnv, mode: s.mode })              // N18
        } else {                                                                                     // a conflict alone gets no reply
            &&& s_ == s
            &&& sent == Set::<Packet>::empty()
        }
    }
}

/// Jetpack replica R, on observing the original path's reply for c, committed and executed:
/// c is in R's executed prefix (N21-N23). N22 (forward the result) is not modeled.
pub open spec fn ObserveCommitted(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, cmd: int, sent: Set<Packet>) -> bool {
    &&& exists|j: int| 0 <= j < s.committed && #[trigger] entry_cmds(s.olog[j]).contains(cmd)
    &&& s_ == (if s.mode is Normal { ReplicaState { pool: s.pool.remove(cmd), ..s } } else { s })  // N21
    &&& sent == broadcast(c, Msg::Evict { cmd: cmd })                                                // N23
}

/// Jetpack replica R, on an evict notice for c (N24).
pub open spec fn RecvEvict(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is Evict
    &&& s_ == (if s.mode is Normal { ReplicaState { pool: s.pool.remove(pkt.msg->Evict_cmd), ..s } } else { s })  // N24
    &&& sent == Set::<Packet>::empty()
}

// ---------------------------------------------------------------------------------------------
// §2 recovery: the replica side (L4-L8, L11-L22, L31-L40, L51-L54)
// ---------------------------------------------------------------------------------------------

/// Any Jetpack replica R, on receiving BeginRecovery(v) from coordinator C (L4-L8).
pub open spec fn RecvBeginRecovery(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is BeginRecovery
    &&& {
        let v = pkt.msg->BeginRecovery_view;
        if v >= s.nv && v > s.lnv {                                                                  // L4
            &&& s_ == (if v > s.nv { join(s, v) } else { s })                                        // L5
            &&& sent == send_to(c, pkt.src, Msg::BeginRecoveryOK { view: v, lnv: s.lnv })           // L6
        } else {                                                                                     // L7
            &&& s_ == s
            &&& sent == send_to(c, pkt.src, Msg::Nack { new_view: s.nv, lnv: s.lnv, k: None })      // L8
        }
    }
}

/// Step 1 of L11/L31 fails: stale view, or v_n already recovered.
pub open spec fn stale(s1: ReplicaState, v: int, vn: int) -> bool {
    v < s1.nv || s1.lnv > vn
}

/// L14/L34: join v if it is newer.
pub open spec fn join_if_newer(s1: ReplicaState, v: int) -> ReplicaState {
    if v > s1.nv {
        join(s1, v)
    } else {
        s1
    }
}

/// Any Jetpack replica R, on receiving Prepare(v, v_n, k) from coordinator C (L11-L22);
/// learn(v_n) ran first.
pub open spec fn RecvPrepare(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is Prepare
    &&& {
        let v = pkt.msg->Prepare_view;
        let vn = pkt.msg->Prepare_vn;
        let k = pkt.msg->Prepare_k;
        let s1 = learn(s, vn);
        if stale(s1, v, vn) {                                                                        // L11
            &&& s_ == s1
            &&& sent == send_to(c, pkt.src, Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None })    // L12
        } else {                                                                                     // L13
            let s2 = join_if_newer(s1, v);                                                           // L14
            if k > msb_of(s2, vn) {                                                                  // L15
                &&& s_ == ReplicaState { msb: s2.msb.insert(vn, k), ..s2 }                           // L16
                &&& sent == send_to(c, pkt.src, Msg::PrepareOK {
                    view: v, vn: vn, k: k,
                    body: if s2.accepted.contains_key(vn) {                                          // L17
                        PrepareOkBody::Accepted { acc: s2.accepted[vn] }                             // L18
                    } else {
                        PrepareOkBody::Pool { pool: pool_of(s2, vn) }                                // L20
                    },
                })
            } else {                                                                                 // L21
                &&& s_ == s2
                &&& sent == send_to(c, pkt.src, Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) })  // L22
            }
        }
    }
}

/// Whether R takes Accept(v, v_n, k, ·) (L31, L35), after learn(v_n) and L34.
pub open spec fn accept_taken(s: ReplicaState, v: int, vn: int, k: int) -> bool {
    let s1 = learn(s, vn);
    !stale(s1, v, vn) && k >= msb_of(join_if_newer(s1, v), vn)
}

/// Any Jetpack replica R, on receiving Accept(v, v_n, k, S) from coordinator C (L31-L40);
/// learn(v_n) ran first. The vote it casts is recorded by `system.rs` (`votes_cast`).
pub open spec fn RecvAccept(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is Accept
    &&& {
        let v = pkt.msg->Accept_view;
        let vn = pkt.msg->Accept_vn;
        let k = pkt.msg->Accept_k;
        let rset = pkt.msg->Accept_rset;
        let s1 = learn(s, vn);
        if stale(s1, v, vn) {                                                                        // L31
            &&& s_ == s1
            &&& sent == send_to(c, pkt.src, Msg::Nack { new_view: s1.nv, lnv: s1.lnv, k: None })    // L32
        } else {                                                                                     // L33
            let s2 = join_if_newer(s1, v);                                                           // L34
            if k >= msb_of(s2, vn) {                                                                 // L35
                &&& s_ == ReplicaState {
                    msb: s2.msb.insert(vn, k),                                                       // L36
                    accepted: s2.accepted.insert(vn, Acc { view: v, k: k, val: rset }),              // L37
                    ..s2
                }
                &&& sent == send_to(c, pkt.src, Msg::AcceptOK { view: v, vn: vn, k: k })             // L38
            } else {                                                                                 // L39
                &&& s_ == s2
                &&& sent == send_to(c, pkt.src, Msg::Nack { new_view: s2.nv, lnv: s2.lnv, k: Some(msb_of(s2, vn)) })  // L40
            }
        }
    }
}

/// Any Jetpack replica R, on receiving FinishRecovery(v, S) from coordinator C: L51 and L54.
/// L52-L53 (the proposer's own Recovered(S)) is completed in `system.rs` (`finish_appends`).
pub open spec fn RecvFinishRecovery(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is FinishRecovery
    &&& s_ == learn(s, pkt.msg->FinishRecovery_view)                                                 // L51
    &&& sent == send_to(c, pkt.src, Msg::FinishRecoveryOK { view: pkt.msg->FinishRecovery_view })   // L54
}

// ---------------------------------------------------------------------------------------------
// §2 recovery: the coordinator side (L9-L10, L23-L30, L41-L49)
// ---------------------------------------------------------------------------------------------

/// The packet replica `r` sent to this coordinator carrying `m`.
pub open spec fn from_replica(c: ReplicaConsts, r: int, m: Msg) -> Packet {
    Packet { src: Addr::Replica { id: r }, dst: me(c), msg: m }
}

/// A set of at least maj distinct replicas.
pub open spec fn is_majority(c: ReplicaConsts, m: Set<int>) -> bool {
    m.subset_of(c.replicas) && m.len() >= c_maj(c)
}

/// Coordinator C, on receiving BeginRecoveryOK(C.view, ·) from maj(C.view) replicas (L9-L10):
/// `m` are the replicas, `lnvs[r]` what each reported, `vn` the largest. learn(·) ran on each
/// reply, which amounts to learn(vn) (learn is monotone, PROGRESS.md).
pub open spec fn CoordBeginOK(
    c: ReplicaConsts,
    s: ReplicaState,
    s_: ReplicaState,
    pkts: Set<Packet>,
    m: Set<int>,
    lnvs: Map<int, int>,
    vn: int,
    sent: Set<Packet>,
) -> bool {
    &&& s.coord.phase is P1
    &&& is_majority(c, m)
    &&& forall|r: int| #[trigger] m.contains(r)
        ==> pkts.contains(from_replica(c, r, Msg::BeginRecoveryOK { view: s.coord.view, lnv: lnvs[r] }))
    &&& forall|r: int| #[trigger] m.contains(r) ==> lnvs[r] <= vn                                    // L9: the largest
    &&& exists|r: int| #[trigger] m.contains(r) && lnvs[r] == vn
    &&& s_ == ReplicaState { coord: Coord { phase: Phase::P2a, vn: vn, ..s.coord }, ..learn(s, vn) }
    &&& sent == broadcast(c, Msg::Prepare { view: s.coord.view, vn: vn, k: s.coord.k })             // L10
}

/// How C picks C.rset (L23-L29).
pub enum RsetRule {
    /// L23-L24: some reply carries an accepted triple; `r` is the replica whose triple has the
    /// largest (accepted_view, accepted_ballot).
    Adopt { r: int },
    /// L25-L29: no reply carries an accepted triple; count the pools.
    Count,
}

pub open spec fn pools_of(m: Set<int>, bodies: Map<int, PrepareOkBody>) -> Map<int, Set<int>> {
    Map::new(m, |r: int| bodies[r]->Pool_pool)
}

/// How many replicas of `m` reported `cmd` in their pool.
pub open spec fn pool_count(m: Set<int>, pools: Map<int, Set<int>>, cmd: int) -> int {
    m.filter(|r: int| pools[r].contains(cmd)).len() as int
}

/// L26-L29: `rset` is exactly the set of commands that appear in at least t of the replies
/// (a subset of the union of the finitely many pools, so a finite set exists).
pub open spec fn is_recover_set(c: ReplicaConsts, m: Set<int>, pools: Map<int, Set<int>>, rset: Set<int>) -> bool {
    forall|cmd: int| #[trigger] rset.contains(cmd) <==> pool_count(m, pools, cmd) >= c_t(c)
}

pub open spec fn rset_rule_ok(c: ReplicaConsts, m: Set<int>, bodies: Map<int, PrepareOkBody>, rule: RsetRule, rset: Set<int>) -> bool {
    match rule {
        RsetRule::Adopt { r } => {
            &&& m.contains(r)
            &&& bodies[r] is Accepted
            &&& forall|q: int| #[trigger] m.contains(q) && bodies[q] is Accepted
                ==> bal_le(acc_bal(bodies[q]->Accepted_acc), acc_bal(bodies[r]->Accepted_acc))   // L24: view first, then ballot
            &&& rset == bodies[r]->Accepted_acc.val
        },
        RsetRule::Count => {
            &&& forall|q: int| #[trigger] m.contains(q) ==> bodies[q] is Pool                         // L25
            &&& is_recover_set(c, m, pools_of(m, bodies), rset)                                      // L26-L29
        },
    }
}

/// Coordinator C, on receiving PrepareOK(C.view, C.v_n, C.k, ·) from maj(C.v_n) replicas
/// (L23-L30): `m` are the replicas, `bodies[r]` what each sent.
pub open spec fn CoordPrepareOK(
    c: ReplicaConsts,
    s: ReplicaState,
    s_: ReplicaState,
    pkts: Set<Packet>,
    m: Set<int>,
    bodies: Map<int, PrepareOkBody>,
    rule: RsetRule,
    rset: Set<int>,
    sent: Set<Packet>,
) -> bool {
    &&& s.coord.phase is P2a
    &&& is_majority(c, m)
    &&& forall|r: int| #[trigger] m.contains(r)
        ==> pkts.contains(from_replica(c, r, Msg::PrepareOK { view: s.coord.view, vn: s.coord.vn, k: s.coord.k, body: bodies[r] }))
    &&& rset_rule_ok(c, m, bodies, rule, rset)
    &&& s_ == ReplicaState { coord: Coord { phase: Phase::P2b, rset: rset, ..s.coord }, ..s }
    &&& sent == broadcast(c, Msg::Accept { view: s.coord.view, vn: s.coord.vn, k: s.coord.k, rset: rset })  // L30
}

/// Coordinator C, on receiving AcceptOK(C.view, C.v_n, C.k) from maj(C.v_n) replicas (L47):
/// submit Recovered(C.rset) to C's own proposer. The entry is appended by `system.rs`
/// (`accept_ok_appends`); here C moves to P3.
pub open spec fn CoordAcceptOK(
    c: ReplicaConsts,
    s: ReplicaState,
    s_: ReplicaState,
    pkts: Set<Packet>,
    m: Set<int>,
    sent: Set<Packet>,
) -> bool {
    &&& s.coord.phase is P2b
    &&& is_majority(c, m)
    &&& forall|r: int| #[trigger] m.contains(r)
        ==> pkts.contains(from_replica(c, r, Msg::AcceptOK { view: s.coord.view, vn: s.coord.vn, k: s.coord.k }))
    &&& s_ == ReplicaState { coord: Coord { phase: Phase::P3, ..s.coord }, ..s }
    &&& sent == Set::<Packet>::empty()
}

/// The Recovered entry C submits (L47).
pub open spec fn recovered_entry(co: Coord) -> Entry {
    Entry::Recovered { view: co.view, vn: co.vn, cmds: co.rset }
}

/// When C's Recovered(C.rset) is committed on the original path (L48): send FinishRecovery.
/// L49's retransmissions send the same packets, which are already in the network.
pub open spec fn CoordFinish(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, sent: Set<Packet>) -> bool {
    &&& s.coord.phase is P3
    &&& exists|j: int| 0 <= j < s.committed && #[trigger] s.olog[j] == recovered_entry(s.coord)
    &&& s_ == ReplicaState { coord: Coord { phase: Phase::Done, ..s.coord }, ..s }
    &&& sent == broadcast(c, Msg::FinishRecovery { view: s.coord.view, vn: s.coord.vn, rset: s.coord.rset })  // L48
}

/// Coordinator C, on receiving Nack(new_view', last_normal_view', k') (L41-L46); learn(lnv')
/// ran first. Nacks answer BeginRecovery, Prepare and Accept, so C handles them while one of
/// those is outstanding (P1, P2a, P2b) (PROGRESS.md).
pub open spec fn CoordNack(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is Nack
    &&& (s.coord.phase is P1 || s.coord.phase is P2a || s.coord.phase is P2b)
    &&& {
        let nv_ = pkt.msg->Nack_new_view;
        let lnv_ = pkt.msg->Nack_lnv;
        let k_ = pkt.msg->Nack_k;
        let s1 = learn(s, lnv_);
        if nv_ > s.coord.view || lnv_ >= s.coord.view {                                              // L41
            &&& s_ == ReplicaState { coord: Coord { phase: Phase::Stopped, ..s.coord }, ..s1 }       // L42
            &&& sent == Set::<Packet>::empty()
        } else if lnv_ > s.coord.vn {                                                                // L43
            &&& s_ == ReplicaState { coord: Coord { phase: Phase::P2a, vn: lnv_, ..s.coord }, ..s1 }  // L44
            &&& sent == broadcast(c, Msg::Prepare { view: s.coord.view, vn: lnv_, k: s.coord.k })   // L44: go to L10
        } else if k_ is Some && k_->Some_0 >= s.coord.k {                                            // L45
            &&& s_ == ReplicaState { coord: Coord { phase: Phase::P2a, k: k_->Some_0 + 1, ..s.coord }, ..s1 }  // L46
            &&& sent == broadcast(c, Msg::Prepare { view: s.coord.view, vn: s.coord.vn, k: k_->Some_0 + 1 })  // L46: go to L10
        } else {
            &&& s_ == s1
            &&& sent == Set::<Packet>::empty()
        }
    }
}

// ---------------------------------------------------------------------------------------------
// One step of a replica
// ---------------------------------------------------------------------------------------------

pub enum ReplicaStep {
    RecvFastCmd { pkt: Packet },
    ObserveCommitted { cmd: int },
    RecvEvict { pkt: Packet },
    RecvBeginRecovery { pkt: Packet },
    RecvPrepare { pkt: Packet },
    RecvAccept { pkt: Packet },
    RecvFinishRecovery { pkt: Packet },
    CoordBeginOK { pkts: Set<Packet>, m: Set<int>, lnvs: Map<int, int>, vn: int },
    CoordPrepareOK { pkts: Set<Packet>, m: Set<int>, bodies: Map<int, PrepareOkBody>, rule: RsetRule, rset: Set<int> },
    CoordAcceptOK { pkts: Set<Packet>, m: Set<int> },
    CoordFinish,
    CoordNack { pkt: Packet },
}

pub open spec fn ReplicaNext(c: ReplicaConsts, s: ReplicaState, s_: ReplicaState, step: ReplicaStep, sent: Set<Packet>) -> bool {
    match step {
        ReplicaStep::RecvFastCmd { pkt } => RecvFastCmd(c, s, s_, pkt, sent),
        ReplicaStep::ObserveCommitted { cmd } => ObserveCommitted(c, s, s_, cmd, sent),
        ReplicaStep::RecvEvict { pkt } => RecvEvict(c, s, s_, pkt, sent),
        ReplicaStep::RecvBeginRecovery { pkt } => RecvBeginRecovery(c, s, s_, pkt, sent),
        ReplicaStep::RecvPrepare { pkt } => RecvPrepare(c, s, s_, pkt, sent),
        ReplicaStep::RecvAccept { pkt } => RecvAccept(c, s, s_, pkt, sent),
        ReplicaStep::RecvFinishRecovery { pkt } => RecvFinishRecovery(c, s, s_, pkt, sent),
        ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn } => CoordBeginOK(c, s, s_, pkts, m, lnvs, vn, sent),
        ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset } => CoordPrepareOK(c, s, s_, pkts, m, bodies, rule, rset, sent),
        ReplicaStep::CoordAcceptOK { pkts, m } => CoordAcceptOK(c, s, s_, pkts, m, sent),
        ReplicaStep::CoordFinish => CoordFinish(c, s, s_, sent),
        ReplicaStep::CoordNack { pkt } => CoordNack(c, s, s_, pkt, sent),
    }
}

/// The packets a replica step receives; the system checks they are in the network and
/// addressed to this replica.
pub open spec fn replica_received(step: ReplicaStep) -> Set<Packet> {
    match step {
        ReplicaStep::RecvFastCmd { pkt } => set![pkt],
        ReplicaStep::ObserveCommitted { cmd } => Set::<Packet>::empty(),
        ReplicaStep::RecvEvict { pkt } => set![pkt],
        ReplicaStep::RecvBeginRecovery { pkt } => set![pkt],
        ReplicaStep::RecvPrepare { pkt } => set![pkt],
        ReplicaStep::RecvAccept { pkt } => set![pkt],
        ReplicaStep::RecvFinishRecovery { pkt } => set![pkt],
        ReplicaStep::CoordBeginOK { pkts, m, lnvs, vn } => pkts,
        ReplicaStep::CoordPrepareOK { pkts, m, bodies, rule, rset } => pkts,
        ReplicaStep::CoordAcceptOK { pkts, m } => pkts,
        ReplicaStep::CoordFinish => Set::<Packet>::empty(),
        ReplicaStep::CoordNack { pkt } => set![pkt],
    }
}

} // verus!
