//! W2 (not trusted): W1 continued by a new view and a full recovery. From s5: the original
//! protocol starts view 1 with proposer 0 (T1, L1-L3); replicas 0, 1, 2 join (L4-L6);
//! coordinator 0 learns v_n = 0 from replicas 0 and 1 and prepares (L9-L10); replicas 0, 1, 2
//! promise and report their pools {7} (L11-L20); the coordinator counts 7 in 2 >= t replies
//! and proposes {7} (L23-L30); replicas 0, 1, 2 accept (L31-L38); the coordinator submits
//! Recovered(v_0, {7}) (L47); replica 0 replicates and the entry commits (A1-A3); the
//! coordinator sends FinishRecovery (L48); replicas 0, 1, 2 return to Normal in view 1 (L51).
//! At the end replica 0 is Normal in view 1 and Recovered(v_0, {7}) is in its committed prefix:
//! 7 is recovered and committed.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::frame::*;
use crate::proof::replica_lemmas::*;
use crate::witness::steps::*;
use crate::witness::w_fast::*;
use vstd::prelude::*;

verus! {

pub open spec fn c0() -> ReplicaConsts {
    replica_consts(cfg3(), 0)
}

// Packets
pub open spec fn br(i: int) -> Packet {
    Packet { src: rep(0), dst: rep(i), msg: Msg::BeginRecovery { view: 1 } }
}

pub open spec fn brok(i: int) -> Packet {
    Packet { src: rep(i), dst: rep(0), msg: Msg::BeginRecoveryOK { view: 1, lnv: 0 } }
}

pub open spec fn prep(i: int) -> Packet {
    Packet { src: rep(0), dst: rep(i), msg: Msg::Prepare { view: 1, vn: 0, k: 0 } }
}

pub open spec fn pok_body() -> PrepareOkBody {
    PrepareOkBody::Pool { pool: set7() }
}

pub open spec fn pok(i: int) -> Packet {
    Packet { src: rep(i), dst: rep(0), msg: Msg::PrepareOK { view: 1, vn: 0, k: 0, body: pok_body() } }
}

pub open spec fn acc(i: int) -> Packet {
    Packet { src: rep(0), dst: rep(i), msg: Msg::Accept { view: 1, vn: 0, k: 0, rset: set7() } }
}

pub open spec fn accok(i: int) -> Packet {
    Packet { src: rep(i), dst: rep(0), msg: Msg::AcceptOK { view: 1, vn: 0, k: 0 } }
}

pub open spec fn fin(i: int) -> Packet {
    Packet { src: rep(0), dst: rep(i), msg: Msg::FinishRecovery { view: 1, vn: 0, rset: set7() } }
}

/// The Recovered entry of view 1 for v_0.
pub open spec fn rec() -> Entry {
    Entry::Recovered { view: 1, vn: 0, cmds: set7() }
}

// Coordinator records
pub open spec fn co(ph: Phase, vn: int, rset: Set<int>) -> Coord {
    Coord { phase: ph, view: 1, vn: vn, k: 0, rset: rset }
}

// Replica states along the way
/// Replica 0 after NewView(1): acked, coordinator in P1.
pub open spec fn r0_new() -> ReplicaState {
    ReplicaState { coord: fresh_coord(1), ..r_ack() }
}

/// After joining view 1.
pub open spec fn r_join(x: ReplicaState) -> ReplicaState {
    join(x, 1)
}

/// Replica 0 after L9-L10.
pub open spec fn r0_p2a() -> ReplicaState {
    ReplicaState { coord: Coord { phase: Phase::P2a, vn: 0, ..fresh_coord(1) }, ..learn(r_join(r0_new()), 0) }
}

/// After promising ballot 0 for v_0 (L16).
pub open spec fn r_prom(x: ReplicaState) -> ReplicaState {
    ReplicaState { msb: x.msb.insert(0, 0), ..x }
}

/// Replica 0 after L30.
pub open spec fn r0_p2b() -> ReplicaState {
    ReplicaState { coord: Coord { phase: Phase::P2b, rset: set7(), ..r_prom(r0_p2a()).coord }, ..r_prom(r0_p2a()) }
}

/// After accepting (1, 0, {7}) for v_0 (L36-L37).
pub open spec fn r_acc(x: ReplicaState) -> ReplicaState {
    ReplicaState { msb: x.msb.insert(0, 0), accepted: x.accepted.insert(0, Acc { view: 1, k: 0, val: set7() }), ..x }
}

/// Replica 0 after L47.
pub open spec fn r0_p3() -> ReplicaState {
    ReplicaState { coord: Coord { phase: Phase::P3, ..r_acc(r0_p2b()).coord }, ..r_acc(r0_p2b()) }
}

// ---------------------------------------------------------------------------------------------
// The states
// ---------------------------------------------------------------------------------------------

pub open spec fn s6() -> SystemState {
    after_new_view(cfg3(), s5(), 1)
}

pub open spec fn join_step(i: int) -> ReplicaStep {
    ReplicaStep::RecvBeginRecovery { pkt: br(i) }
}

pub open spec fn join_sent(i: int) -> Set<Packet> {
    send_to(replica_consts(cfg3(), i), rep(0), Msg::BeginRecoveryOK { view: 1, lnv: 0 })
}

pub open spec fn s7() -> SystemState {
    after_replica(cfg3(), s6(), 0, join_step(0), r_join(r0_new()), join_sent(0))
}

pub open spec fn s8() -> SystemState {
    after_replica(cfg3(), s7(), 1, join_step(1), r_join(r_ack()), join_sent(1))
}

pub open spec fn s9() -> SystemState {
    after_replica(cfg3(), s8(), 2, join_step(2), r_join(r_ack()), join_sent(2))
}

pub open spec fn lnvs01() -> Map<int, int> {
    Map::<int, int>::empty().insert(0, 0).insert(1, 0)
}

pub open spec fn beginok_step() -> ReplicaStep {
    ReplicaStep::CoordBeginOK { pkts: set![brok(0), brok(1)], m: set![0int, 1int], lnvs: lnvs01(), vn: 0 }
}

pub open spec fn s10() -> SystemState {
    after_replica(cfg3(), s9(), 0, beginok_step(), r0_p2a(), broadcast(c0(), Msg::Prepare { view: 1, vn: 0, k: 0 }))
}

pub open spec fn prep_step(i: int) -> ReplicaStep {
    ReplicaStep::RecvPrepare { pkt: prep(i) }
}

pub open spec fn prep_sent(i: int) -> Set<Packet> {
    send_to(replica_consts(cfg3(), i), rep(0), Msg::PrepareOK { view: 1, vn: 0, k: 0, body: pok_body() })
}

pub open spec fn s11() -> SystemState {
    after_replica(cfg3(), s10(), 0, prep_step(0), r_prom(r0_p2a()), prep_sent(0))
}

pub open spec fn s12() -> SystemState {
    after_replica(cfg3(), s11(), 1, prep_step(1), r_prom(r_join(r_ack())), prep_sent(1))
}

pub open spec fn s13() -> SystemState {
    after_replica(cfg3(), s12(), 2, prep_step(2), r_prom(r_join(r_ack())), prep_sent(2))
}

pub open spec fn bodies01() -> Map<int, PrepareOkBody> {
    Map::<int, PrepareOkBody>::empty().insert(0, pok_body()).insert(1, pok_body())
}

pub open spec fn prepok_step() -> ReplicaStep {
    ReplicaStep::CoordPrepareOK { pkts: set![pok(0), pok(1)], m: set![0int, 1int], bodies: bodies01(), rule: RsetRule::Count, rset: set7() }
}

pub open spec fn s14() -> SystemState {
    after_replica(cfg3(), s13(), 0, prepok_step(), r0_p2b(), broadcast(c0(), Msg::Accept { view: 1, vn: 0, k: 0, rset: set7() }))
}

pub open spec fn acc_step(i: int) -> ReplicaStep {
    ReplicaStep::RecvAccept { pkt: acc(i) }
}

pub open spec fn acc_sent(i: int) -> Set<Packet> {
    send_to(replica_consts(cfg3(), i), rep(0), Msg::AcceptOK { view: 1, vn: 0, k: 0 })
}

pub open spec fn s15() -> SystemState {
    after_replica(cfg3(), s14(), 0, acc_step(0), r_acc(r0_p2b()), acc_sent(0))
}

pub open spec fn s16() -> SystemState {
    after_replica(cfg3(), s15(), 1, acc_step(1), r_acc(r_prom(r_join(r_ack()))), acc_sent(1))
}

pub open spec fn s17() -> SystemState {
    after_replica(cfg3(), s16(), 2, acc_step(2), r_acc(r_prom(r_join(r_ack()))), acc_sent(2))
}

pub open spec fn accok_step() -> ReplicaStep {
    ReplicaStep::CoordAcceptOK { pkts: set![accok(0), accok(1)], m: set![0int, 1int] }
}

pub open spec fn s18() -> SystemState {
    after_replica(cfg3(), s17(), 0, accok_step(), r0_p3(), Set::<Packet>::empty())
}

pub open spec fn s19() -> SystemState {
    after_replicate(cfg3(), s18(), 0, 1)
}

pub open spec fn s20() -> SystemState {
    after_advance_commit(cfg3(), s19(), 1)
}

pub open spec fn s21() -> SystemState {
    after_replica_commit(cfg3(), s20(), 0, 1)
}

/// Replica 0 before L48: P3, log copy [Recovered], committed 1.
pub open spec fn r0_cmt() -> ReplicaState {
    ReplicaState { committed: 1, ..ReplicaState { olog: s18().log.subrange(0, 1), ..r0_p3() } }
}

pub open spec fn r0_done() -> ReplicaState {
    ReplicaState { coord: Coord { phase: Phase::Done, ..r0_cmt().coord }, ..r0_cmt() }
}

pub open spec fn s22() -> SystemState {
    after_replica(cfg3(), s21(), 0, ReplicaStep::CoordFinish, r0_done(), broadcast(c0(), Msg::FinishRecovery { view: 1, vn: 0, rset: set7() }))
}

pub open spec fn fin_step(i: int) -> ReplicaStep {
    ReplicaStep::RecvFinishRecovery { pkt: fin(i) }
}

pub open spec fn fin_sent(i: int) -> Set<Packet> {
    send_to(replica_consts(cfg3(), i), rep(0), Msg::FinishRecoveryOK { view: 1 })
}

pub open spec fn s23() -> SystemState {
    after_replica(cfg3(), s22(), 0, fin_step(0), learn(r0_done(), 1), fin_sent(0))
}

pub open spec fn s24() -> SystemState {
    after_replica(cfg3(), s23(), 1, fin_step(1), learn(r_acc(r_prom(r_join(r_ack()))), 1), fin_sent(1))
}

pub open spec fn s25() -> SystemState {
    after_replica(cfg3(), s24(), 2, fin_step(2), learn(r_acc(r_prom(r_join(r_ack()))), 1), fin_sent(2))
}

// ---------------------------------------------------------------------------------------------
// Facts about the replica states
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_r_join()
    ensures
        r_join(r0_new()) == (ReplicaState { nv: 1, mode: Mode::Recovery, msb: Map::<int, int>::empty(), ..r0_new() }),
        r_join(r_ack()) == (ReplicaState { nv: 1, mode: Mode::Recovery, msb: Map::<int, int>::empty(), ..r_ack() }),
        r_join(r0_new()).lnv == 0 && r_join(r0_new()).nv == 1 && r_join(r0_new()).coord == fresh_coord(1) && r_join(r0_new()).pool == set7(),
        r_join(r_ack()).lnv == 0 && r_join(r_ack()).nv == 1 && r_join(r_ack()).pool == set7(),
        learn(r_join(r0_new()), 0) == r_join(r0_new()),
        learn(r_join(r_ack()), 0) == r_join(r_ack()),
{
}

/// A replica that joined view 1 with pool {7} and no promise answers Prepare(1, 0, 0) with
/// PrepareOK(1, 0, 0, pool {7}) (L11-L20).
pub proof fn lemma_prep(s: SystemState, i: int, x: ReplicaState)
    requires
        cfg3().replicas.contains(i),
        s.replicas[i] == x,
        x.lnv == 0 && x.nv == 1 && x.pool == set7(),
        x.msb == Map::<int, int>::empty(),
        x.accepted == Map::<int, Acc>::empty(),
        s.network.contains(prep(i)),
    ensures
        Next(cfg3(), s, after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i))),
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).replicas[i] == r_prom(x),
        forall|q: int| q != i ==> #[trigger] after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).replicas[q] == s.replicas[q],
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).network == s.network.union(prep_sent(i)),
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).network.contains(pok(i)),
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).clients == s.clients,
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).base_view == s.base_view,
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).log == s.log,
        after_replica(cfg3(), s, i, prep_step(i), r_prom(x), prep_sent(i)).committed == s.committed,
        r_prom(x).lnv == 0 && r_prom(x).nv == 1 && r_prom(x).pool == set7() && r_prom(x).coord == x.coord,
        msb_of(r_prom(x), 0) == 0,
        r_prom(x).accepted == Map::<int, Acc>::empty(),
{
    lemma_cfg3();
    let c = replica_consts(cfg3(), i);
    let pkt = prep(i);
    let step = prep_step(i);
    assert(learn(x, 0) == x);
    assert(!stale(x, 1, 0));
    assert(join_if_newer(x, 1) == x);
    assert(msb_of(x, 0) == bot());
    assert(!x.accepted.contains_key(0));
    assert(pool_of(x, 0) == set7());
    assert(RecvPrepare(c, x, r_prom(x), pkt, prep_sent(i)));
    assert(ReplicaNext(c, s.replicas[i], r_prom(x), step, prep_sent(i)));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s.network.contains(p) && p.dst == rep(i) by {
        assert(p == pkt);
    }
    lemma_replica_step(cfg3(), s, i, step, r_prom(x), prep_sent(i));
    assert(step_appends(cfg3(), s, i, step) == Seq::<Entry>::empty());
    assert(s.log + Seq::<Entry>::empty() =~= s.log);
    lemma_send_to_msgs(c, rep(0), Msg::PrepareOK { view: 1, vn: 0, k: 0, body: pok_body() });
    assert(me(c) == rep(i));
    assert(prep_sent(i).contains(pok(i)));
    assert(msb_of(r_prom(x), 0) == 0);
}

/// A replica that promised ballot 0 for v_0 in view 1 accepts (1, 0, {7}) (L31-L38).
pub proof fn lemma_accept(s: SystemState, i: int, x: ReplicaState)
    requires
        cfg3().replicas.contains(i),
        s.replicas[i] == x,
        x.lnv == 0 && x.nv == 1,
        msb_of(x, 0) == 0,
        s.network.contains(acc(i)),
    ensures
        Next(cfg3(), s, after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i))),
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).replicas[i] == r_acc(x),
        forall|q: int| q != i ==> #[trigger] after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).replicas[q] == s.replicas[q],
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).network == s.network.union(acc_sent(i)),
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).network.contains(accok(i)),
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).clients == s.clients,
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).base_view == s.base_view,
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).log == s.log,
        after_replica(cfg3(), s, i, acc_step(i), r_acc(x), acc_sent(i)).committed == s.committed,
        r_acc(x).lnv == 0 && r_acc(x).nv == 1 && r_acc(x).coord == x.coord && r_acc(x).pool == x.pool,
        r_acc(x).olog == x.olog && r_acc(x).committed == x.committed,
{
    lemma_cfg3();
    let c = replica_consts(cfg3(), i);
    let pkt = acc(i);
    let step = acc_step(i);
    assert(learn(x, 0) == x);
    assert(!stale(x, 1, 0));
    assert(join_if_newer(x, 1) == x);
    assert(RecvAccept(c, x, r_acc(x), pkt, acc_sent(i)));
    assert(ReplicaNext(c, s.replicas[i], r_acc(x), step, acc_sent(i)));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s.network.contains(p) && p.dst == rep(i) by {
        assert(p == pkt);
    }
    lemma_replica_step(cfg3(), s, i, step, r_acc(x), acc_sent(i));
    assert(step_appends(cfg3(), s, i, step) == Seq::<Entry>::empty());
    assert(s.log + Seq::<Entry>::empty() =~= s.log);
    lemma_send_to_msgs(c, rep(0), Msg::AcceptOK { view: 1, vn: 0, k: 0 });
    assert(me(c) == rep(i));
    assert(acc_sent(i).contains(accok(i)));
}

/// A replica in Recovery in view 1 with last normal view 0 handles FinishRecovery(1, 0, {7}):
/// learn(1) makes it Normal in view 1 (L51); it is not a proposer that still owes a Recovered
/// entry (L52), so nothing is appended; FinishRecoveryOK (L54).
pub proof fn lemma_finish(s: SystemState, i: int, x: ReplicaState)
    requires
        cfg3().replicas.contains(i),
        s.replicas[i] == x,
        x.lnv == 0 && x.nv == 1,
        s.network.contains(fin(i)),
        s.log == seq![rec()],
    ensures
        Next(cfg3(), s, after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i))),
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).replicas[i] == learn(x, 1),
        forall|q: int| q != i ==> #[trigger] after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).replicas[q] == s.replicas[q],
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).network == s.network.union(fin_sent(i)),
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).clients == s.clients,
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).base_view == s.base_view,
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).log == s.log,
        after_replica(cfg3(), s, i, fin_step(i), learn(x, 1), fin_sent(i)).committed == s.committed,
        learn(x, 1) == (ReplicaState { lnv: 1, nv: 1, mode: Mode::Normal, pool: Set::<int>::empty(), ..x }),
{
    lemma_cfg3();
    let c = replica_consts(cfg3(), i);
    let pkt = fin(i);
    let step = fin_step(i);
    assert(RecvFinishRecovery(c, x, learn(x, 1), pkt, fin_sent(i)));
    assert(ReplicaNext(c, s.replicas[i], learn(x, 1), step, fin_sent(i)));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s.network.contains(p) && p.dst == rep(i) by {
        assert(p == pkt);
    }
    lemma_replica_step(cfg3(), s, i, step, learn(x, 1), fin_sent(i));
    // L52: a Recovered entry of view 1 is already in the log, so no second one is appended
    assert(s.log[0] == rec());
    assert(s.log[0] is Recovered && s.log[0]->Recovered_view == 1);
    assert(has_recovered_in(s.log, 1));
    assert(finish_appends(cfg3(), s, i, pkt) == Seq::<Entry>::empty());
    assert(step_appends(cfg3(), s, i, step) == Seq::<Entry>::empty());
    assert(s.log + Seq::<Entry>::empty() =~= s.log);
}

// ---------------------------------------------------------------------------------------------
// The steps
// ---------------------------------------------------------------------------------------------

/// 6. The original protocol starts view 1 with proposer 0 (T1, L1-L3).
pub proof fn lemma_s6()
    ensures
        Next(cfg3(), s5(), s6()),
        s6().replicas[0] == r0_new(),
        s6().replicas[1] == r_ack(),
        s6().replicas[2] == r_ack(),
        s6().clients[0] == k_decided(),
        acks_in(s6()),
        s6().network.contains(br(0)) && s6().network.contains(br(1)) && s6().network.contains(br(2)),
        s6().base_view == 1,
        s6().log == Seq::<Entry>::empty(),
        s6().committed == 0,
{
    lemma_cfg3();
    lemma_s5();
    assert((cfg3().proposer)(1) == 0);
    lemma_new_view(cfg3(), s5(), 1);
    assert(replica_consts(cfg3(), (cfg3().proposer)(1)) == c0());
    let m = Msg::BeginRecovery { view: 1 };
    lemma_broadcast_has(c0(), m, 0);
    lemma_broadcast_has(c0(), m, 1);
    lemma_broadcast_has(c0(), m, 2);
    assert(me(c0()) == rep(0));
    assert(Packet { src: me(c0()), dst: rep(0), msg: m } == br(0));
    assert(Packet { src: me(c0()), dst: rep(1), msg: m } == br(1));
    assert(Packet { src: me(c0()), dst: rep(2), msg: m } == br(2));
}

/// Replica i, Normal in v_0 with new_view 0, joins view 1 on BeginRecovery(1) (L4-L6).
pub proof fn lemma_join_step(s: SystemState, i: int, x: ReplicaState)
    requires
        cfg3().replicas.contains(i),
        s.replicas[i] == x,
        x.lnv == 0 && x.nv == 0,
        s.network.contains(br(i)),
    ensures
        Next(cfg3(), s, after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i))),
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).replicas[i] == r_join(x),
        forall|q: int| q != i ==> #[trigger] after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).replicas[q] == s.replicas[q],
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).network == s.network.union(join_sent(i)),
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).network.contains(brok(i)),
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).clients == s.clients,
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).base_view == s.base_view,
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).log == s.log,
        after_replica(cfg3(), s, i, join_step(i), r_join(x), join_sent(i)).committed == s.committed,
{
    lemma_cfg3();
    let c = replica_consts(cfg3(), i);
    let pkt = br(i);
    let step = join_step(i);
    assert(RecvBeginRecovery(c, x, r_join(x), pkt, join_sent(i)));
    assert(ReplicaNext(c, s.replicas[i], r_join(x), step, join_sent(i)));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s.network.contains(p) && p.dst == rep(i) by {
        assert(p == pkt);
    }
    lemma_replica_step(cfg3(), s, i, step, r_join(x), join_sent(i));
    assert(step_appends(cfg3(), s, i, step) == Seq::<Entry>::empty());
    assert(s.log + Seq::<Entry>::empty() =~= s.log);
    lemma_send_to_msgs(c, rep(0), Msg::BeginRecoveryOK { view: 1, lnv: 0 });
    assert(me(c) == rep(i));
    assert(join_sent(i).contains(brok(i)));
}

/// 7-9. Replicas 0, 1, 2 join view 1.
pub proof fn lemma_s9()
    ensures
        Next(cfg3(), s6(), s7()),
        Next(cfg3(), s7(), s8()),
        Next(cfg3(), s8(), s9()),
        s9().replicas[0] == r_join(r0_new()),
        s9().replicas[1] == r_join(r_ack()),
        s9().replicas[2] == r_join(r_ack()),
        s9().clients[0] == k_decided(),
        acks_in(s9()),
        s9().network.contains(brok(0)) && s9().network.contains(brok(1)),
        s9().base_view == 1,
        s9().log == Seq::<Entry>::empty(),
        s9().committed == 0,
{
    lemma_cfg3();
    lemma_s6();
    lemma_join_step(s6(), 0, r0_new());
    assert(s7().network.contains(br(1)) && s7().network.contains(br(2)));
    lemma_join_step(s7(), 1, r_ack());
    assert(s8().network.contains(br(2)) && s8().network.contains(brok(0)));
    lemma_join_step(s8(), 2, r_ack());
    assert(s9().network.contains(brok(0)) && s9().network.contains(brok(1)));
}

/// 10. Coordinator 0 has BeginRecoveryOK(1, 0) from replicas 0 and 1 (maj = 2): v_n = 0,
/// Prepare(1, 0, 0) to all (L9-L10).
pub proof fn lemma_s10()
    ensures
        Next(cfg3(), s9(), s10()),
        s10().replicas[0] == r0_p2a(),
        s10().replicas[1] == r_join(r_ack()),
        s10().replicas[2] == r_join(r_ack()),
        s10().clients[0] == k_decided(),
        acks_in(s10()),
        s10().network.contains(prep(0)) && s10().network.contains(prep(1)) && s10().network.contains(prep(2)),
        s10().base_view == 1,
        s10().log == Seq::<Entry>::empty(),
        s10().committed == 0,
        r0_p2a().lnv == 0 && r0_p2a().nv == 1 && r0_p2a().pool == set7(),
        r0_p2a().msb == Map::<int, int>::empty(),
        r0_p2a().accepted == Map::<int, Acc>::empty(),
        r0_p2a().coord == co(Phase::P2a, 0, Set::<int>::empty()),
{
    lemma_cfg3();
    lemma_s9();
    lemma_r_join();
    let x = r_join(r0_new());
    let m = set![0int, 1int];
    let pkts = set![brok(0), brok(1)];
    let step = beginok_step();
    let msg = Msg::Prepare { view: 1, vn: 0, k: 0 };
    let sent = broadcast(c0(), msg);
    assert(x.coord == fresh_coord(1));
    assert(x.coord.phase is P1);
    assert(is_majority(c0(), m));
    assert(lnvs01()[0] == 0 && lnvs01()[1] == 0);
    assert forall|r: int| #[trigger] m.contains(r) implies pkts.contains(from_replica(c0(), r, Msg::BeginRecoveryOK { view: x.coord.view, lnv: lnvs01()[r] })) by {
        assert(r == 0 || r == 1);
        assert(from_replica(c0(), r, Msg::BeginRecoveryOK { view: 1, lnv: 0 }) == brok(r));
    }
    assert forall|r: int| #[trigger] m.contains(r) implies lnvs01()[r] <= 0 by {
        assert(r == 0 || r == 1);
    }
    assert(m.contains(0) && lnvs01()[0] == 0);
    assert(r0_p2a() == (ReplicaState { coord: Coord { phase: Phase::P2a, vn: 0, ..x.coord }, ..learn(x, 0) }));
    assert(CoordBeginOK(c0(), x, r0_p2a(), pkts, m, lnvs01(), 0, sent));
    assert(ReplicaNext(c0(), s9().replicas[0], r0_p2a(), step, sent));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s9().network.contains(p) && p.dst == rep(0) by {
        assert(p == brok(0) || p == brok(1));
    }
    lemma_replica_step(cfg3(), s9(), 0, step, r0_p2a(), sent);
    assert(step_appends(cfg3(), s9(), 0, step) == Seq::<Entry>::empty());
    assert(s9().log + Seq::<Entry>::empty() =~= s9().log);
    lemma_broadcast_has(c0(), msg, 0);
    lemma_broadcast_has(c0(), msg, 1);
    lemma_broadcast_has(c0(), msg, 2);
    assert(me(c0()) == rep(0));
    assert(Packet { src: me(c0()), dst: rep(0), msg: msg } == prep(0));
    assert(Packet { src: me(c0()), dst: rep(1), msg: msg } == prep(1));
    assert(Packet { src: me(c0()), dst: rep(2), msg: msg } == prep(2));
}

/// 11-13. Replicas 0, 1, 2 promise and report pool {7} (L11-L20).
pub proof fn lemma_s13()
    ensures
        Next(cfg3(), s10(), s11()),
        Next(cfg3(), s11(), s12()),
        Next(cfg3(), s12(), s13()),
        s13().replicas[0] == r_prom(r0_p2a()),
        s13().replicas[1] == r_prom(r_join(r_ack())),
        s13().replicas[2] == r_prom(r_join(r_ack())),
        s13().clients[0] == k_decided(),
        acks_in(s13()),
        s13().network.contains(pok(0)) && s13().network.contains(pok(1)),
        s13().base_view == 1,
        s13().log == Seq::<Entry>::empty(),
        s13().committed == 0,
        r_prom(r0_p2a()).coord == co(Phase::P2a, 0, Set::<int>::empty()),
        r_prom(r0_p2a()).lnv == 0 && r_prom(r0_p2a()).nv == 1,
        msb_of(r_prom(r0_p2a()), 0) == 0,
        r_prom(r_join(r_ack())).lnv == 0 && r_prom(r_join(r_ack())).nv == 1,
        msb_of(r_prom(r_join(r_ack())), 0) == 0,
{
    lemma_cfg3();
    lemma_s10();
    lemma_r_join();
    lemma_prep(s10(), 0, r0_p2a());
    assert(s11().network.contains(prep(1)) && s11().network.contains(prep(2)));
    lemma_prep(s11(), 1, r_join(r_ack()));
    assert(s12().network.contains(prep(2)) && s12().network.contains(pok(0)));
    lemma_prep(s12(), 2, r_join(r_ack()));
    assert(s13().network.contains(pok(0)) && s13().network.contains(pok(1)));
}

/// 14. Coordinator 0 has PrepareOK(1, 0, 0, pool {7}) from replicas 0 and 1: no accepted
/// triple, 7 appears in 2 >= t replies, C.rset = {7}; Accept(1, 0, 0, {7}) to all (L23-L30).
pub proof fn lemma_s14()
    ensures
        Next(cfg3(), s13(), s14()),
        s14().replicas[0] == r0_p2b(),
        s14().replicas[1] == r_prom(r_join(r_ack())),
        s14().replicas[2] == r_prom(r_join(r_ack())),
        s14().clients[0] == k_decided(),
        acks_in(s14()),
        s14().network.contains(acc(0)) && s14().network.contains(acc(1)) && s14().network.contains(acc(2)),
        s14().base_view == 1,
        s14().log == Seq::<Entry>::empty(),
        s14().committed == 0,
        r0_p2b().coord == co(Phase::P2b, 0, set7()),
        r0_p2b().lnv == 0 && r0_p2b().nv == 1,
        msb_of(r0_p2b(), 0) == 0,
{
    lemma_cfg3();
    lemma_s13();
    let x = r_prom(r0_p2a());
    let m = set![0int, 1int];
    let pkts = set![pok(0), pok(1)];
    let bodies = bodies01();
    let step = prepok_step();
    let msg = Msg::Accept { view: 1, vn: 0, k: 0, rset: set7() };
    let sent = broadcast(c0(), msg);
    assert(x.coord.phase is P2a);
    assert(is_majority(c0(), m));
    assert(bodies[0] == pok_body() && bodies[1] == pok_body());
    assert forall|r: int| #[trigger] m.contains(r) implies pkts.contains(from_replica(c0(), r, Msg::PrepareOK { view: x.coord.view, vn: x.coord.vn, k: x.coord.k, body: bodies[r] })) by {
        assert(r == 0 || r == 1);
        assert(from_replica(c0(), r, Msg::PrepareOK { view: 1, vn: 0, k: 0, body: pok_body() }) == pok(r));
    }
    // L25-L29: {7} is exactly the set of commands in >= 2 of the 2 pools
    let pools = pools_of(m, bodies);
    assert(pools[0] == set7() && pools[1] == set7());
    assert forall|cmd: int| #[trigger] set7().contains(cmd) <==> pool_count(m, pools, cmd) >= c_t(c0()) by {
        let f = m.filter(|r: int| pools[r].contains(cmd));
        if cmd == 7 {
            assert(f =~= m);
            assert(pool_count(m, pools, cmd) == 2);
        } else {
            assert(f =~= Set::<int>::empty());
            assert(pool_count(m, pools, cmd) == 0);
        }
    }
    assert(is_recover_set(c0(), m, pools, set7()));
    assert forall|q: int| #[trigger] m.contains(q) implies bodies[q] is Pool by {
        assert(q == 0 || q == 1);
    }
    assert(rset_rule_ok(c0(), m, bodies, RsetRule::Count, set7()));
    assert(r0_p2b() == (ReplicaState { coord: Coord { phase: Phase::P2b, rset: set7(), ..x.coord }, ..x }));
    assert(CoordPrepareOK(c0(), x, r0_p2b(), pkts, m, bodies, RsetRule::Count, set7(), sent));
    assert(ReplicaNext(c0(), s13().replicas[0], r0_p2b(), step, sent));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s13().network.contains(p) && p.dst == rep(0) by {
        assert(p == pok(0) || p == pok(1));
    }
    lemma_replica_step(cfg3(), s13(), 0, step, r0_p2b(), sent);
    assert(step_appends(cfg3(), s13(), 0, step) == Seq::<Entry>::empty());
    assert(s13().log + Seq::<Entry>::empty() =~= s13().log);
    lemma_broadcast_has(c0(), msg, 0);
    lemma_broadcast_has(c0(), msg, 1);
    lemma_broadcast_has(c0(), msg, 2);
    assert(me(c0()) == rep(0));
    assert(Packet { src: me(c0()), dst: rep(0), msg: msg } == acc(0));
    assert(Packet { src: me(c0()), dst: rep(1), msg: msg } == acc(1));
    assert(Packet { src: me(c0()), dst: rep(2), msg: msg } == acc(2));
}

/// 15-17. Replicas 0, 1, 2 accept (L31-L38).
pub proof fn lemma_s17()
    ensures
        Next(cfg3(), s14(), s15()),
        Next(cfg3(), s15(), s16()),
        Next(cfg3(), s16(), s17()),
        s17().replicas[0] == r_acc(r0_p2b()),
        s17().replicas[1] == r_acc(r_prom(r_join(r_ack()))),
        s17().replicas[2] == r_acc(r_prom(r_join(r_ack()))),
        s17().clients[0] == k_decided(),
        acks_in(s17()),
        s17().network.contains(accok(0)) && s17().network.contains(accok(1)),
        s17().base_view == 1,
        s17().log == Seq::<Entry>::empty(),
        s17().committed == 0,
        r_acc(r0_p2b()).coord == co(Phase::P2b, 0, set7()),
        r_acc(r0_p2b()).lnv == 0 && r_acc(r0_p2b()).nv == 1,
        r_acc(r0_p2b()).olog == Seq::<Entry>::empty() && r_acc(r0_p2b()).committed == 0,
        r_acc(r_prom(r_join(r_ack()))).lnv == 0 && r_acc(r_prom(r_join(r_ack()))).nv == 1,
{
    lemma_cfg3();
    lemma_s14();
    lemma_s13();
    lemma_accept(s14(), 0, r0_p2b());
    assert(s15().network.contains(acc(1)) && s15().network.contains(acc(2)));
    lemma_accept(s15(), 1, r_prom(r_join(r_ack())));
    assert(s16().network.contains(acc(2)) && s16().network.contains(accok(0)));
    lemma_accept(s16(), 2, r_prom(r_join(r_ack())));
    assert(s17().network.contains(accok(0)) && s17().network.contains(accok(1)));
    lemma_r_join();
}

/// 18. Coordinator 0 has AcceptOK(1, 0, 0) from replicas 0 and 1: it submits Recovered(v_0,
/// {7}), which its proposer appends in view 1 (L47).
pub proof fn lemma_s18()
    ensures
        Next(cfg3(), s17(), s18()),
        s18().replicas[0] == r0_p3(),
        s18().replicas[1] == r_acc(r_prom(r_join(r_ack()))),
        s18().replicas[2] == r_acc(r_prom(r_join(r_ack()))),
        s18().clients[0] == k_decided(),
        acks_in(s18()),
        s18().base_view == 1,
        s18().log == seq![rec()],
        s18().committed == 0,
        r0_p3().coord == co(Phase::P3, 0, set7()),
        r0_p3().lnv == 0 && r0_p3().nv == 1,
        r0_p3().olog == Seq::<Entry>::empty() && r0_p3().committed == 0,
{
    lemma_cfg3();
    lemma_s17();
    let x = r_acc(r0_p2b());
    let m = set![0int, 1int];
    let pkts = set![accok(0), accok(1)];
    let step = accok_step();
    assert(x.coord.phase is P2b);
    assert(is_majority(c0(), m));
    assert forall|r: int| #[trigger] m.contains(r) implies pkts.contains(from_replica(c0(), r, Msg::AcceptOK { view: x.coord.view, vn: x.coord.vn, k: x.coord.k })) by {
        assert(r == 0 || r == 1);
        assert(from_replica(c0(), r, Msg::AcceptOK { view: 1, vn: 0, k: 0 }) == accok(r));
    }
    assert(r0_p3() == (ReplicaState { coord: Coord { phase: Phase::P3, ..x.coord }, ..x }));
    assert(CoordAcceptOK(c0(), x, r0_p3(), pkts, m, Set::<Packet>::empty()));
    assert(ReplicaNext(c0(), s17().replicas[0], r0_p3(), step, Set::<Packet>::empty()));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s17().network.contains(p) && p.dst == rep(0) by {
        assert(p == accok(0) || p == accok(1));
    }
    assert((cfg3().proposer)(1) == 0);
    assert(step_base_guard(cfg3(), s17(), 0, step));
    lemma_replica_step(cfg3(), s17(), 0, step, r0_p3(), Set::<Packet>::empty());
    assert(step_appends(cfg3(), s17(), 0, step) == seq![recovered_entry(x.coord)]);
    assert(recovered_entry(x.coord) == rec());
    assert(s17().log + seq![rec()] =~= seq![rec()]);
    assert(s18().network =~= s17().network);
}

/// 19-21. Replica 0 replicates the entry; the original protocol commits it; replica 0 executes
/// it (A1-A3).
pub proof fn lemma_s21()
    ensures
        Next(cfg3(), s18(), s19()),
        Next(cfg3(), s19(), s20()),
        Next(cfg3(), s20(), s21()),
        s21().replicas[0] == r0_cmt(),
        s21().replicas[1] == r_acc(r_prom(r_join(r_ack()))),
        s21().replicas[2] == r_acc(r_prom(r_join(r_ack()))),
        s21().clients[0] == k_decided(),
        acks_in(s21()),
        s21().base_view == 1,
        s21().log == seq![rec()],
        s21().committed == 1,
        r0_cmt().coord == co(Phase::P3, 0, set7()),
        r0_cmt().lnv == 0 && r0_cmt().nv == 1,
        r0_cmt().olog.len() == 1 && r0_cmt().olog[0] == rec() && r0_cmt().committed == 1,
{
    lemma_cfg3();
    lemma_s18();
    assert(s18().replicas[0].olog.len() == 0);
    assert(s18().log.len() == 1);
    lemma_replicate(cfg3(), s18(), 0, 1);
    assert(s19().replicas[0] == (ReplicaState { olog: s18().log.subrange(0, 1), ..r0_p3() }));
    assert(s19().replicas[0].olog.len() == 1);
    assert(s19().replicas[0].olog[0] == rec());
    lemma_advance_commit(cfg3(), s19(), 1);
    assert(s20().replicas[0] == s19().replicas[0]);
    assert(s20().replicas[0].committed == 0);
    lemma_replica_commit(cfg3(), s20(), 0, 1);
    assert(s21().replicas[0] == (ReplicaState { committed: 1, ..s20().replicas[0] }));
    assert(s21().replicas[0] == r0_cmt());
    assert(s21().replicas[1] == s18().replicas[1]);
    assert(s21().replicas[2] == s18().replicas[2]);
    assert(s21().network == s18().network);
    assert(s21().clients == s18().clients);
}

/// 22. Coordinator 0 sees its Recovered entry committed: FinishRecovery(1, 0, {7}) to all (L48).
pub proof fn lemma_s22()
    ensures
        Next(cfg3(), s21(), s22()),
        s22().replicas[0] == r0_done(),
        s22().replicas[1] == r_acc(r_prom(r_join(r_ack()))),
        s22().replicas[2] == r_acc(r_prom(r_join(r_ack()))),
        s22().clients[0] == k_decided(),
        acks_in(s22()),
        s22().network.contains(fin(0)) && s22().network.contains(fin(1)) && s22().network.contains(fin(2)),
        s22().base_view == 1,
        s22().log == seq![rec()],
        s22().committed == 1,
        r0_done().lnv == 0 && r0_done().nv == 1,
        r0_done().olog.len() == 1 && r0_done().olog[0] == rec() && r0_done().committed == 1,
{
    lemma_cfg3();
    lemma_s21();
    let x = r0_cmt();
    let step = ReplicaStep::CoordFinish;
    let msg = Msg::FinishRecovery { view: 1, vn: 0, rset: set7() };
    let sent = broadcast(c0(), msg);
    assert(x.coord.phase is P3);
    assert(recovered_entry(x.coord) == rec());
    assert(0 <= 0 < x.committed && x.olog[0] == recovered_entry(x.coord));
    assert(r0_done() == (ReplicaState { coord: Coord { phase: Phase::Done, ..x.coord }, ..x }));
    assert(CoordFinish(c0(), x, r0_done(), sent));
    assert(ReplicaNext(c0(), s21().replicas[0], r0_done(), step, sent));
    assert forall|p: Packet| #[trigger] replica_received(step).contains(p) implies s21().network.contains(p) && p.dst == rep(0) by {}
    lemma_replica_step(cfg3(), s21(), 0, step, r0_done(), sent);
    assert(step_appends(cfg3(), s21(), 0, step) == Seq::<Entry>::empty());
    assert(s21().log + Seq::<Entry>::empty() =~= s21().log);
    lemma_broadcast_has(c0(), msg, 0);
    lemma_broadcast_has(c0(), msg, 1);
    lemma_broadcast_has(c0(), msg, 2);
    assert(me(c0()) == rep(0));
    assert(Packet { src: me(c0()), dst: rep(0), msg: msg } == fin(0));
    assert(Packet { src: me(c0()), dst: rep(1), msg: msg } == fin(1));
    assert(Packet { src: me(c0()), dst: rep(2), msg: msg } == fin(2));
}

/// 23-25. Replicas 0, 1, 2 handle FinishRecovery(1, 0, {7}): Normal in view 1 (L51-L54).
pub proof fn lemma_s25()
    ensures
        Next(cfg3(), s22(), s23()),
        Next(cfg3(), s23(), s24()),
        Next(cfg3(), s24(), s25()),
        s25().replicas[0] == learn(r0_done(), 1),
        s25().clients[0] == k_decided(),
        acks_in(s25()),
        s25().base_view == 1,
        s25().log == seq![rec()],
        s25().committed == 1,
        s25().replicas[0].mode is Normal,
        s25().replicas[0].lnv == 1 && s25().replicas[0].nv == 1,
        s25().replicas[0].committed == 1,
        s25().replicas[0].olog.len() == 1 && s25().replicas[0].olog[0] == rec(),
        s25().replicas[1].mode is Normal && s25().replicas[1].nv == 1,
        s25().replicas[2].mode is Normal && s25().replicas[2].nv == 1,
{
    lemma_cfg3();
    lemma_s22();
    lemma_s17();
    lemma_finish(s22(), 0, r0_done());
    assert(s23().network.contains(fin(1)) && s23().network.contains(fin(2)));
    lemma_finish(s23(), 1, r_acc(r_prom(r_join(r_ack()))));
    assert(s24().network.contains(fin(2)));
    lemma_finish(s24(), 2, r_acc(r_prom(r_join(r_ack()))));
    assert(s25().replicas[0] == learn(r0_done(), 1));
    assert(learn(r0_done(), 1).olog == r0_done().olog);
    assert(learn(r0_done(), 1).committed == 1);
}

/// The W2 behavior: s0 .. s25, continuing W1 (s0 .. s5).
pub proof fn lemma_w2_behavior() -> (tr: Seq<SystemState>)
    ensures
        IsValidBehavior(cfg3(), tr),
        tr.len() == 26,
        tr[5] == s5(),
        tr.last() == s25(),
        fast_committed(cfg3(), tr[5], v0(), 7),
        tr[5].clients[0].fast.contains(fc7()),
        fast_committed(cfg3(), tr.last(), v0(), 7),
        tr.last().clients[0].fast.contains(fc7()),
        tr.last().replicas[0].mode is Normal,
        tr.last().replicas[0].lnv == 1,
        tr.last().replicas[0].nv == 1,
        tr.last().replicas[0].committed == 1,
        tr.last().replicas[0].olog.len() == 1,
        tr.last().replicas[0].olog[0] is Recovered,
        tr.last().replicas[0].olog[0]->Recovered_vn == v0(),
        tr.last().replicas[0].olog[0]->Recovered_cmds.contains(7),
        committed_cmd(cfg3(), tr.last(), 7),
{
    lemma_cfg3();
    let tr5 = lemma_w1_behavior();
    lemma_s6();
    lemma_s9();
    lemma_s10();
    lemma_s13();
    lemma_s14();
    lemma_s17();
    lemma_s18();
    lemma_s21();
    lemma_s22();
    lemma_s25();
    lemma_behavior_push(cfg3(), tr5, s6());
    let tr6 = tr5.push(s6());
    lemma_behavior_push(cfg3(), tr6, s7());
    let tr7 = tr6.push(s7());
    lemma_behavior_push(cfg3(), tr7, s8());
    let tr8 = tr7.push(s8());
    lemma_behavior_push(cfg3(), tr8, s9());
    let tr9 = tr8.push(s9());
    lemma_behavior_push(cfg3(), tr9, s10());
    let tr10 = tr9.push(s10());
    lemma_behavior_push(cfg3(), tr10, s11());
    let tr11 = tr10.push(s11());
    lemma_behavior_push(cfg3(), tr11, s12());
    let tr12 = tr11.push(s12());
    lemma_behavior_push(cfg3(), tr12, s13());
    let tr13 = tr12.push(s13());
    lemma_behavior_push(cfg3(), tr13, s14());
    let tr14 = tr13.push(s14());
    lemma_behavior_push(cfg3(), tr14, s15());
    let tr15 = tr14.push(s15());
    lemma_behavior_push(cfg3(), tr15, s16());
    let tr16 = tr15.push(s16());
    lemma_behavior_push(cfg3(), tr16, s17());
    let tr17 = tr16.push(s17());
    lemma_behavior_push(cfg3(), tr17, s18());
    let tr18 = tr17.push(s18());
    lemma_behavior_push(cfg3(), tr18, s19());
    let tr19 = tr18.push(s19());
    lemma_behavior_push(cfg3(), tr19, s20());
    let tr20 = tr19.push(s20());
    lemma_behavior_push(cfg3(), tr20, s21());
    let tr21 = tr20.push(s21());
    lemma_behavior_push(cfg3(), tr21, s22());
    let tr22 = tr21.push(s22());
    lemma_behavior_push(cfg3(), tr22, s23());
    let tr23 = tr22.push(s23());
    lemma_behavior_push(cfg3(), tr23, s24());
    let tr24 = tr23.push(s24());
    lemma_behavior_push(cfg3(), tr24, s25());
    let tr25 = tr24.push(s25());
    assert(tr25[5] == s5());
    // the fast commit of W1 persists: the acks are still in the network
    assert forall|r: int| #[trigger] set![0int, 1int, 2int].contains(r) implies acked(s25(), r, v0(), 7) by {
        assert(r == 0 || r == 1 || r == 2);
        assert(s25().network.contains(fastack(r)));
    }
    assert(set![0int, 1int, 2int].len() >= sq(cfg3()));
    assert(set![0int, 1int, 2int].contains((cfg3().proposer)(v0())));
    assert(set![0int, 1int, 2int].subset_of(cfg3().replicas));
    assert(fast_committed(cfg3(), s25(), v0(), 7));
    // 7 is recovered and committed
    assert(s25().replicas[0].olog[0] == rec());
    assert(entry_cmds(s25().replicas[0].olog[0]).contains(7));
    assert(committed_cmd(cfg3(), s25(), 7));
    tr25
}

} // verus!
