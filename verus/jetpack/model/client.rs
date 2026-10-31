//! A fast-path client K (docs/pseudocode.md §1 N1-N10). Definitions only, trusted.
//! N4-N7 (results, waiting for the original path) and N11 (original-path commands) are not
//! modeled: N11 is the oracle's `AppendCmd` (`system.rs`), results are dropped (PROGRESS.md).
use crate::model::replica::to_replicas;
use crate::model::types::*;
use vstd::prelude::*;

verus! {

/// A fast commit K decided (N5): c in view `view`.
pub struct FastCommit {
    pub view: int,
    pub cmd: int,
}

pub struct ClientState {
    /// K.view: the fast-path view K believes is current; only moves forward (N8-N9).
    pub view: int,
    /// The fast commits K decided (N2-N5).
    pub fast: Set<FastCommit>,
}

pub struct ClientConsts {
    pub me: int,
    pub replicas: Set<int>,
    pub proposer: spec_fn(int) -> int,
}

pub open spec fn c_sq(c: ClientConsts) -> int {
    let n = c.replicas.len() as int;
    let maj = n / 2 + 1;
    let t = maj / 2 + 1;
    n - maj + t
}

pub open spec fn client_init() -> ClientState {
    ClientState { view: v0(), fast: Set::<FastCommit>::empty() }
}

pub open spec fn client_addr(c: ClientConsts) -> Addr {
    Addr::Client { id: c.me }
}

/// Client K, issuing fast-path command c: send FastCmd(K.view, c) to replicas(K.view) (N1);
/// a resend with the same id is the same action (N10).
pub open spec fn ClientSendFastCmd(c: ClientConsts, s: ClientState, s_: ClientState, cmd: int, sent: Set<Packet>) -> bool {
    &&& s_ == s
    &&& sent == to_replicas(c.replicas, client_addr(c), Msg::FastCmd { view: s.view, cmd: cmd })
}

/// Client K, on receiving FastAck(K.view, c, ·) from a set Q ⊆ replicas(K.view) with |Q| >= sq
/// and proposers(K.view) ⊆ Q (N2-N3): c is fast-committed (N5). N4 (equal results) is not
/// modeled.
pub open spec fn ClientFastCommit(c: ClientConsts, s: ClientState, s_: ClientState, pkts: Set<Packet>, q: Set<int>, cmd: int, sent: Set<Packet>) -> bool {
    &&& q.subset_of(c.replicas)
    &&& q.len() >= c_sq(c)                                                                           // N3
    &&& q.contains((c.proposer)(s.view))                                                             // N3: proposers(K.view) ⊆ Q
    &&& forall|r: int| #[trigger] q.contains(r)
        ==> pkts.contains(Packet { src: Addr::Replica { id: r }, dst: client_addr(c), msg: Msg::FastAck { view: s.view, cmd: cmd } })  // N2
    &&& s_ == ClientState { fast: s.fast.insert(FastCommit { view: s.view, cmd: cmd }), ..s }        // N5
    &&& sent == Set::<Packet>::empty()
}

/// Client K, on receiving FastNack(v', ·) (N8-N9).
pub open spec fn ClientRecvFastNack(c: ClientConsts, s: ClientState, s_: ClientState, pkt: Packet, sent: Set<Packet>) -> bool {
    &&& pkt.msg is FastNack
    &&& s_ == (if pkt.msg->FastNack_lnv > s.view { ClientState { view: pkt.msg->FastNack_lnv, ..s } } else { s })  // N8-N9
    &&& sent == Set::<Packet>::empty()
}

pub enum ClientStep {
    SendFastCmd { cmd: int },
    FastCommit { pkts: Set<Packet>, q: Set<int>, cmd: int },
    RecvFastNack { pkt: Packet },
}

pub open spec fn ClientNext(c: ClientConsts, s: ClientState, s_: ClientState, step: ClientStep, sent: Set<Packet>) -> bool {
    match step {
        ClientStep::SendFastCmd { cmd } => ClientSendFastCmd(c, s, s_, cmd, sent),
        ClientStep::FastCommit { pkts, q, cmd } => ClientFastCommit(c, s, s_, pkts, q, cmd, sent),
        ClientStep::RecvFastNack { pkt } => ClientRecvFastNack(c, s, s_, pkt, sent),
    }
}

pub open spec fn client_received(step: ClientStep) -> Set<Packet> {
    match step {
        ClientStep::SendFastCmd { cmd } => Set::<Packet>::empty(),
        ClientStep::FastCommit { pkts, q, cmd } => pkts,
        ClientStep::RecvFastNack { pkt } => set![pkt],
    }
}

} // verus!
