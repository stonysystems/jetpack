//! W1 (not trusted): command 7 is fast-committed in v_0. Six steps from `init_state(cfg3())`:
//! client 0 sends FastCmd(0, 7) to the three replicas (N1); each replica, Normal in v_0 with an
//! empty pool, acks (N12-N16); client 0 receives the three acks, a superquorum (sq = 3)
//! containing the proposer, and decides (N2-N5). Each step is proved to be a `Next` step.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::frame::*;
use crate::witness::steps::*;
use vstd::prelude::*;

verus! {

pub open spec fn set7() -> Set<int> {
    Set::<int>::empty().insert(7)
}

pub open spec fn fastcmd(i: int) -> Packet {
    Packet { src: cli(0), dst: rep(i), msg: Msg::FastCmd { view: 0, cmd: 7 } }
}

pub open spec fn fastack(i: int) -> Packet {
    Packet { src: rep(i), dst: cli(0), msg: Msg::FastAck { view: 0, cmd: 7 } }
}

/// A replica after acking 7 in v_0.
pub open spec fn r_ack() -> ReplicaState {
    ReplicaState { pool: set7(), ..replica_init() }
}

pub open spec fn fc7() -> FastCommit {
    FastCommit { view: 0, cmd: 7 }
}

/// The three FastCmds are in the network.
pub open spec fn cmds_in(s: SystemState) -> bool {
    s.network.contains(fastcmd(0)) && s.network.contains(fastcmd(1)) && s.network.contains(fastcmd(2))
}

/// The three FastAcks are in the network.
pub open spec fn acks_in(s: SystemState) -> bool {
    s.network.contains(fastack(0)) && s.network.contains(fastack(1)) && s.network.contains(fastack(2))
}

// ---------------------------------------------------------------------------------------------
// The states
// ---------------------------------------------------------------------------------------------

pub open spec fn s0() -> SystemState {
    init_state(cfg3())
}

pub open spec fn s1() -> SystemState {
    after_client(cfg3(), s0(), 0, ClientStep::SendFastCmd { cmd: 7 }, client_init(), to_replicas(cfg3().replicas, cli(0), Msg::FastCmd { view: 0, cmd: 7 }))
}

pub open spec fn ack_step(i: int) -> ReplicaStep {
    ReplicaStep::RecvFastCmd { pkt: fastcmd(i) }
}

pub open spec fn ack_sent(i: int) -> Set<Packet> {
    send_to(replica_consts(cfg3(), i), cli(0), Msg::FastAck { view: 0, cmd: 7 })
}

pub open spec fn s2() -> SystemState {
    after_replica(cfg3(), s1(), 0, ack_step(0), r_ack(), ack_sent(0))
}

pub open spec fn s3() -> SystemState {
    after_replica(cfg3(), s2(), 1, ack_step(1), r_ack(), ack_sent(1))
}

pub open spec fn s4() -> SystemState {
    after_replica(cfg3(), s3(), 2, ack_step(2), r_ack(), ack_sent(2))
}

pub open spec fn decide_step() -> ClientStep {
    ClientStep::FastCommit { pkts: set![fastack(0), fastack(1), fastack(2)], q: set![0int, 1int, 2int], cmd: 7 }
}

pub open spec fn k_decided() -> ClientState {
    ClientState { fast: Set::<FastCommit>::empty().insert(fc7()), ..client_init() }
}

pub open spec fn s5() -> SystemState {
    after_client(cfg3(), s4(), 0, decide_step(), k_decided(), Set::<Packet>::empty())
}

// ---------------------------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------------------------

/// 1. Client 0 sends FastCmd(0, 7) to replicas 0, 1, 2 (N1).
pub proof fn lemma_s1()
    ensures
        Next(cfg3(), s0(), s1()),
        s1().replicas[0] == replica_init(),
        s1().replicas[1] == replica_init(),
        s1().replicas[2] == replica_init(),
        s1().clients[0] == client_init(),
        cmds_in(s1()),
        s1().base_view == 0,
        s1().log == Seq::<Entry>::empty(),
        s1().committed == 0,
{
    lemma_cfg3();
    lemma_init_state(cfg3());
    let c = client_consts(cfg3(), 0);
    let m = Msg::FastCmd { view: 0, cmd: 7 };
    let sent = to_replicas(cfg3().replicas, cli(0), m);
    assert(s0().clients[0] == client_init());
    assert(client_addr(c) == cli(0));
    assert(ClientSendFastCmd(c, client_init(), client_init(), 7, sent));
    assert(ClientNext(c, s0().clients[0], client_init(), ClientStep::SendFastCmd { cmd: 7 }, sent));
    assert forall|p: Packet| #[trigger] client_received(ClientStep::SendFastCmd { cmd: 7 }).contains(p) implies s0().network.contains(p) && p.dst == cli(0) by {}
    lemma_client_step(cfg3(), s0(), 0, ClientStep::SendFastCmd { cmd: 7 }, client_init(), sent);
    lemma_to_replicas_has(cfg3().replicas, cli(0), m, 0);
    lemma_to_replicas_has(cfg3().replicas, cli(0), m, 1);
    lemma_to_replicas_has(cfg3().replicas, cli(0), m, 2);
    assert(to_replica(cli(0), m, 0) == fastcmd(0));
    assert(to_replica(cli(0), m, 1) == fastcmd(1));
    assert(to_replica(cli(0), m, 2) == fastcmd(2));
    assert(s1().replicas == s0().replicas);
}

/// Replica i, Normal in v_0 with an empty pool and nothing pending, acks FastCmd(0, 7)
/// (N12-N16).
pub proof fn lemma_ack(s: SystemState, i: int)
    requires
        cfg3().replicas.contains(i),
        s.replicas[i] == replica_init(),
        s.network.contains(fastcmd(i)),
    ensures
        Next(cfg3(), s, after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i))),
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).replicas[i] == r_ack(),
        forall|q: int| q != i ==> #[trigger] after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).replicas[q] == s.replicas[q],
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).network == s.network.union(ack_sent(i)),
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).network.contains(fastack(i)),
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).clients == s.clients,
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).base_view == s.base_view,
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).log == s.log,
        after_replica(cfg3(), s, i, ack_step(i), r_ack(), ack_sent(i)).committed == s.committed,
{
    lemma_cfg3();
    let c = replica_consts(cfg3(), i);
    let st = replica_init();
    let pkt = fastcmd(i);
    let step = ack_step(i);
    assert(no_conflict(c, 7, st.pool.union(pending_cmds(st)))) by {
        assert forall|d: int| #[trigger] st.pool.union(pending_cmds(st)).contains(d) implies !(c.conflicts)(7, d) by {
            assert(!(cfg3().conflicts)(7, d));
        }
    }
    assert(r_ack() == (ReplicaState { pool: st.pool.insert(7), ..st }));
    assert(RecvFastCmd(c, st, r_ack(), pkt, ack_sent(i)));
    assert(ReplicaNext(c, s.replicas[i], r_ack(), step, ack_sent(i)));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s.network.contains(p) && p.dst == rep(i) by {
        assert(p == pkt);
    }
    assert(step_base_guard(cfg3(), s, i, step));
    lemma_replica_step(cfg3(), s, i, step, r_ack(), ack_sent(i));
    assert(step_appends(cfg3(), s, i, step) == Seq::<Entry>::empty());
    assert(s.log + Seq::<Entry>::empty() =~= s.log);
    lemma_send_to_msgs(c, cli(0), Msg::FastAck { view: 0, cmd: 7 });
    assert(me(c) == rep(i));
    assert(ack_sent(i).contains(fastack(i)));
}

/// 2-4. Replicas 0, 1, 2 ack.
pub proof fn lemma_s4()
    ensures
        Next(cfg3(), s1(), s2()),
        Next(cfg3(), s2(), s3()),
        Next(cfg3(), s3(), s4()),
        s4().replicas[0] == r_ack(),
        s4().replicas[1] == r_ack(),
        s4().replicas[2] == r_ack(),
        s4().clients[0] == client_init(),
        cmds_in(s4()),
        acks_in(s4()),
        s4().base_view == 0,
        s4().log == Seq::<Entry>::empty(),
        s4().committed == 0,
{
    lemma_cfg3();
    lemma_s1();
    lemma_ack(s1(), 0);
    assert(s2().network.contains(fastcmd(1)) && s2().network.contains(fastcmd(2)));
    lemma_ack(s2(), 1);
    assert(s3().network.contains(fastcmd(2)) && s3().network.contains(fastack(0)));
    lemma_ack(s3(), 2);
    assert(s4().network.contains(fastack(0)) && s4().network.contains(fastack(1)));
    assert(cmds_in(s4()));
}

/// 5. Client 0 has FastAck(0, 7) from replicas 0, 1, 2: |Q| = 3 >= sq, proposer 0 in Q; 7 is
/// fast-committed (N2-N5).
pub proof fn lemma_s5()
    ensures
        Next(cfg3(), s4(), s5()),
        s5().replicas[0] == r_ack(),
        s5().replicas[1] == r_ack(),
        s5().replicas[2] == r_ack(),
        s5().clients[0] == k_decided(),
        cmds_in(s5()),
        acks_in(s5()),
        s5().base_view == 0,
        s5().log == Seq::<Entry>::empty(),
        s5().committed == 0,
        fast_committed(cfg3(), s5(), v0(), 7),
        s5().clients[0].fast.contains(fc7()),
{
    lemma_cfg3();
    lemma_s4();
    let c = client_consts(cfg3(), 0);
    let st = client_init();
    let q = set![0int, 1int, 2int];
    let pkts = set![fastack(0), fastack(1), fastack(2)];
    let step = decide_step();
    assert(client_addr(c) == cli(0));
    assert(q.subset_of(c.replicas));
    assert(q.len() == 3);
    assert(c_sq(c) == 3);
    assert(q.contains((c.proposer)(st.view)));
    assert forall|r: int| #[trigger] q.contains(r)
        implies pkts.contains(Packet { src: rep(r), dst: client_addr(c), msg: Msg::FastAck { view: st.view, cmd: 7 } }) by {
        assert(r == 0 || r == 1 || r == 2);
        assert(Packet { src: rep(r), dst: client_addr(c), msg: Msg::FastAck { view: st.view, cmd: 7 } } == fastack(r));
    }
    assert(k_decided() == (ClientState { fast: st.fast.insert(fc7()), ..st }));
    assert(ClientFastCommit(c, st, k_decided(), pkts, q, 7, Set::<Packet>::empty()));
    assert(ClientNext(c, s4().clients[0], k_decided(), step, Set::<Packet>::empty()));
    assert forall|p: Packet| #[trigger] client_received(step).contains(p) implies s4().network.contains(p) && p.dst == cli(0) by {
        assert(p == fastack(0) || p == fastack(1) || p == fastack(2));
    }
    lemma_client_step(cfg3(), s4(), 0, step, k_decided(), Set::<Packet>::empty());
    assert(s5().network =~= s4().network);
    // 7 is fast-committed in v_0
    assert forall|r: int| #[trigger] q.contains(r) implies acked(s5(), r, v0(), 7) by {
        assert(r == 0 || r == 1 || r == 2);
        assert(s5().network.contains(fastack(r)));
    }
    assert(q.len() >= sq(cfg3()));
    assert(q.contains((cfg3().proposer)(v0())));
    assert(fast_committed(cfg3(), s5(), v0(), 7));
}

/// The W1 behavior: s0 .. s5.
pub proof fn lemma_w1_behavior() -> (tr: Seq<SystemState>)
    ensures
        IsValidBehavior(cfg3(), tr),
        tr.len() == 6,
        tr.last() == s5(),
        tr[5] == s5(),
        fast_committed(cfg3(), tr.last(), v0(), 7),
        tr.last().clients[0].fast.contains(fc7()),
{
    lemma_cfg3();
    lemma_init_state(cfg3());
    lemma_s1();
    lemma_s4();
    lemma_s5();
    let tr0 = seq![s0()];
    assert(tr0.last() == s0());
    lemma_behavior_push(cfg3(), tr0, s1());
    let tr1 = tr0.push(s1());
    lemma_behavior_push(cfg3(), tr1, s2());
    let tr2 = tr1.push(s2());
    lemma_behavior_push(cfg3(), tr2, s3());
    let tr3 = tr2.push(s3());
    lemma_behavior_push(cfg3(), tr3, s4());
    let tr4 = tr3.push(s4());
    lemma_behavior_push(cfg3(), tr4, s5());
    let tr5 = tr4.push(s5());
    tr5
}

} // verus!
