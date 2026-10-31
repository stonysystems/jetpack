//! Building blocks for witness behaviors (not trusted): the configuration, the initial state,
//! and for each kind of step the state after it, written with the model's own definitions, with
//! a lemma that the step is a `Next` step when the action's guards hold. A valid behavior is
//! extended one step at a time (`lemma_behavior_push`).
use crate::common::trace::is_behavior;
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use vstd::prelude::*;

verus! {

// ---------------------------------------------------------------------------------------------
// The configuration: replicas 0, 1, 2; client 0; replica 0 the proposer of every view; no two
// commands conflict. n = 3, maj = 2, t = 2, sq = 3.
// ---------------------------------------------------------------------------------------------

pub open spec fn cfg3() -> Config {
    Config {
        replicas: set![0int, 1int, 2int],
        clients: set![0int],
        proposer: |v: int| 0int,
        conflicts: |a: int, b: int| false,
    }
}

pub open spec fn rep(i: int) -> Addr {
    Addr::Replica { id: i }
}

pub open spec fn cli(k: int) -> Addr {
    Addr::Client { id: k }
}

pub proof fn lemma_cfg3()
    ensures
        WellFormed(cfg3()),
        cfg3().replicas.len() == 3,
        cfg3().clients.len() == 1,
        cfg3().replicas.contains(0) && cfg3().replicas.contains(1) && cfg3().replicas.contains(2),
        forall|r: int| #[trigger] cfg3().replicas.contains(r) ==> r == 0 || r == 1 || r == 2,
        cfg3().clients.contains(0),
        forall|v: int| #[trigger] (cfg3().proposer)(v) == 0,
        forall|a: int, b: int| !#[trigger] (cfg3().conflicts)(a, b),
        n(cfg3()) == 3,
        maj(cfg3()) == 2,
        t(cfg3()) == 2,
        sq(cfg3()) == 3,
        forall|r: int| c_maj(#[trigger] replica_consts(cfg3(), r)) == 2 && c_t(replica_consts(cfg3(), r)) == 2,
        forall|k: int| c_sq(#[trigger] client_consts(cfg3(), k)) == 3,
        set![0int, 1int].len() == 2,
        set![0int, 1int].subset_of(cfg3().replicas),
{
    assert(set![0int, 1int, 2int].len() == 3);
    assert(set![0int].len() == 1);
    assert(set![0int, 1int].len() == 2);
    assert forall|r: int| #[trigger] cfg3().replicas.contains(r) implies r == 0 || r == 1 || r == 2 by {}
    assert forall|v: int| #[trigger] (cfg3().proposer)(v) == 0 by {}
    assert forall|a: int, b: int| !#[trigger] (cfg3().conflicts)(a, b) by {}
    assert forall|v: int| cfg3().replicas.contains(#[trigger] (cfg3().proposer)(v)) by {}
    assert forall|x: int| #[trigger] set![0int, 1int].contains(x) implies cfg3().replicas.contains(x) by {}
}

// ---------------------------------------------------------------------------------------------
// The initial state and behaviors
// ---------------------------------------------------------------------------------------------

pub open spec fn init_state(cfg: Config) -> SystemState {
    SystemState {
        replicas: Map::<int, ReplicaState>::new(cfg.replicas, |r: int| replica_init()),
        clients: Map::<int, ClientState>::new(cfg.clients, |k: int| client_init()),
        network: Set::<Packet>::empty(),
        base_view: v0(),
        log: Seq::<Entry>::empty(),
        committed: 0,
        votes: Set::<Vote>::empty(),
    }
}

pub proof fn lemma_init_state(cfg: Config)
    ensures
        Init(cfg, init_state(cfg)),
        IsValidBehavior(cfg, seq![init_state(cfg)]),
        forall|r: int| cfg.replicas.contains(r) ==> #[trigger] init_state(cfg).replicas[r] == replica_init(),
        forall|k: int| cfg.clients.contains(k) ==> #[trigger] init_state(cfg).clients[k] == client_init(),
{
    let tr = seq![init_state(cfg)];
    let init = |s: SystemState| Init(cfg, s);
    let next = |s: SystemState, s_: SystemState| Next(cfg, s, s_);
    assert(tr[0] == init_state(cfg));
    assert(init(tr[0]));
    assert(is_behavior(init, next, tr));
}

/// A valid behavior extended by a `Next` step is a valid behavior.
pub proof fn lemma_behavior_push(cfg: Config, tr: Seq<SystemState>, s: SystemState)
    requires
        IsValidBehavior(cfg, tr),
        Next(cfg, tr.last(), s),
    ensures
        IsValidBehavior(cfg, tr.push(s)),
        tr.push(s).last() == s,
        tr.push(s).len() == tr.len() + 1,
        forall|i: int| 0 <= i < tr.len() ==> #[trigger] tr.push(s)[i] == tr[i],
{
    let init = |s0: SystemState| Init(cfg, s0);
    let next = |s0: SystemState, s1: SystemState| Next(cfg, s0, s1);
    let tr2 = tr.push(s);
    assert(is_behavior(init, next, tr));
    assert(tr2[0] == tr[0]);
    assert forall|i: int| 0 <= i < tr2.len() - 1 implies #[trigger] next(tr2[i], tr2[i + 1]) by {
        if i < tr.len() - 1 {
            assert(next(tr[i], tr[i + 1]));
            assert(tr2[i] == tr[i] && tr2[i + 1] == tr[i + 1]);
        } else {
            assert(tr2[i] == tr.last() && tr2[i + 1] == s);
        }
    }
    assert(is_behavior(init, next, tr2));
}

// ---------------------------------------------------------------------------------------------
// A replica step
// ---------------------------------------------------------------------------------------------

/// The state after replica `r` takes `step` to state `st_` sending `sent`.
pub open spec fn after_replica(cfg: Config, s: SystemState, r: int, step: ReplicaStep, st_: ReplicaState, sent: Set<Packet>) -> SystemState {
    SystemState {
        replicas: s.replicas.insert(r, st_),
        network: s.network.union(sent),
        log: s.log + step_appends(cfg, s, r, step),
        votes: s.votes.union(votes_cast(r, s.replicas[r], step)),
        ..s
    }
}

pub proof fn lemma_replica_step(cfg: Config, s: SystemState, r: int, step: ReplicaStep, st_: ReplicaState, sent: Set<Packet>)
    requires
        cfg.replicas.contains(r),
        forall|p: Packet| #[trigger] replica_received(step).contains(p) ==> s.network.contains(p) && p.dst == rep(r),
        ReplicaNext(replica_consts(cfg, r), s.replicas[r], st_, step, sent),
        step_base_guard(cfg, s, r, step),
    ensures
        Next(cfg, s, after_replica(cfg, s, r, step, st_, sent)),
        after_replica(cfg, s, r, step, st_, sent).replicas[r] == st_,
        forall|q: int| q != r ==> #[trigger] after_replica(cfg, s, r, step, st_, sent).replicas[q] == s.replicas[q],
        after_replica(cfg, s, r, step, st_, sent).network == s.network.union(sent),
        after_replica(cfg, s, r, step, st_, sent).clients == s.clients,
        after_replica(cfg, s, r, step, st_, sent).base_view == s.base_view,
        after_replica(cfg, s, r, step, st_, sent).log == s.log + step_appends(cfg, s, r, step),
        after_replica(cfg, s, r, step, st_, sent).committed == s.committed,
{
    let s_ = after_replica(cfg, s, r, step, st_, sent);
    assert(s_.replicas[r] == st_);
    assert(ReplicaNodeStep(cfg, s, s_, r, step, sent));
    assert(NextStep(cfg, s, s_, SysStep::Replica { r: r, step: step, sent: sent }));
}

// ---------------------------------------------------------------------------------------------
// A client step
// ---------------------------------------------------------------------------------------------

pub open spec fn after_client(cfg: Config, s: SystemState, k: int, step: ClientStep, st_: ClientState, sent: Set<Packet>) -> SystemState {
    SystemState { clients: s.clients.insert(k, st_), network: s.network.union(sent), ..s }
}

pub proof fn lemma_client_step(cfg: Config, s: SystemState, k: int, step: ClientStep, st_: ClientState, sent: Set<Packet>)
    requires
        cfg.clients.contains(k),
        forall|p: Packet| #[trigger] client_received(step).contains(p) ==> s.network.contains(p) && p.dst == cli(k),
        ClientNext(client_consts(cfg, k), s.clients[k], st_, step, sent),
    ensures
        Next(cfg, s, after_client(cfg, s, k, step, st_, sent)),
        after_client(cfg, s, k, step, st_, sent).clients[k] == st_,
        after_client(cfg, s, k, step, st_, sent).replicas == s.replicas,
        after_client(cfg, s, k, step, st_, sent).network == s.network.union(sent),
        after_client(cfg, s, k, step, st_, sent).base_view == s.base_view,
        after_client(cfg, s, k, step, st_, sent).log == s.log,
        after_client(cfg, s, k, step, st_, sent).committed == s.committed,
{
    let s_ = after_client(cfg, s, k, step, st_, sent);
    assert(s_.clients[k] == st_);
    assert(ClientNodeStep(cfg, s, s_, k, step, sent));
    assert(NextStep(cfg, s, s_, SysStep::Client { k: k, step: step, sent: sent }));
}

// ---------------------------------------------------------------------------------------------
// The original protocol's steps
// ---------------------------------------------------------------------------------------------

pub open spec fn fresh_coord(v: int) -> Coord {
    Coord { phase: Phase::P1, view: v, vn: bot(), k: 0, rset: Set::<int>::empty() }
}

pub open spec fn after_new_view(cfg: Config, s: SystemState, v: int) -> SystemState {
    let p = (cfg.proposer)(v);
    SystemState {
        base_view: v,
        replicas: s.replicas.insert(p, ReplicaState { coord: fresh_coord(v), ..s.replicas[p] }),
        network: s.network.union(broadcast(replica_consts(cfg, p), Msg::BeginRecovery { view: v })),
        ..s
    }
}

pub proof fn lemma_new_view(cfg: Config, s: SystemState, v: int)
    requires
        v > s.base_view,
        cfg.replicas.contains((cfg.proposer)(v)),
    ensures
        Next(cfg, s, after_new_view(cfg, s, v)),
        after_new_view(cfg, s, v).replicas[(cfg.proposer)(v)] == (ReplicaState { coord: fresh_coord(v), ..s.replicas[(cfg.proposer)(v)] }),
        forall|q: int| q != (cfg.proposer)(v) ==> #[trigger] after_new_view(cfg, s, v).replicas[q] == s.replicas[q],
        after_new_view(cfg, s, v).network == s.network.union(broadcast(replica_consts(cfg, (cfg.proposer)(v)), Msg::BeginRecovery { view: v })),
        after_new_view(cfg, s, v).clients == s.clients,
        after_new_view(cfg, s, v).base_view == v,
        after_new_view(cfg, s, v).log == s.log,
        after_new_view(cfg, s, v).committed == s.committed,
{
    let s_ = after_new_view(cfg, s, v);
    assert(NewView(cfg, s, s_, v));
    assert(NextStep(cfg, s, s_, SysStep::NewView { v: v }));
}

pub open spec fn after_replicate(cfg: Config, s: SystemState, r: int, m: int) -> SystemState {
    SystemState {
        replicas: s.replicas.insert(r, ReplicaState { olog: s.log.subrange(0, m), ..s.replicas[r] }),
        ..s
    }
}

pub proof fn lemma_replicate(cfg: Config, s: SystemState, r: int, m: int)
    requires
        cfg.replicas.contains(r),
        s.replicas[r].olog.len() <= m <= s.log.len(),
    ensures
        Next(cfg, s, after_replicate(cfg, s, r, m)),
        after_replicate(cfg, s, r, m).replicas[r] == (ReplicaState { olog: s.log.subrange(0, m), ..s.replicas[r] }),
        forall|q: int| q != r ==> #[trigger] after_replicate(cfg, s, r, m).replicas[q] == s.replicas[q],
        after_replicate(cfg, s, r, m).network == s.network,
        after_replicate(cfg, s, r, m).clients == s.clients,
        after_replicate(cfg, s, r, m).base_view == s.base_view,
        after_replicate(cfg, s, r, m).log == s.log,
        after_replicate(cfg, s, r, m).committed == s.committed,
{
    let s_ = after_replicate(cfg, s, r, m);
    assert(Replicate(cfg, s, s_, r, m));
    assert(NextStep(cfg, s, s_, SysStep::Replicate { r: r, m: m }));
}

pub open spec fn after_advance_commit(cfg: Config, s: SystemState, m: int) -> SystemState {
    SystemState { committed: m, ..s }
}

pub proof fn lemma_advance_commit(cfg: Config, s: SystemState, m: int)
    requires
        s.committed <= m <= s.log.len(),
    ensures
        Next(cfg, s, after_advance_commit(cfg, s, m)),
        after_advance_commit(cfg, s, m).replicas == s.replicas,
        after_advance_commit(cfg, s, m).network == s.network,
        after_advance_commit(cfg, s, m).clients == s.clients,
        after_advance_commit(cfg, s, m).base_view == s.base_view,
        after_advance_commit(cfg, s, m).log == s.log,
        after_advance_commit(cfg, s, m).committed == m,
{
    let s_ = after_advance_commit(cfg, s, m);
    assert(AdvanceCommit(cfg, s, s_, m));
    assert(NextStep(cfg, s, s_, SysStep::AdvanceCommit { m: m }));
}

pub open spec fn after_replica_commit(cfg: Config, s: SystemState, r: int, m: int) -> SystemState {
    SystemState { replicas: s.replicas.insert(r, ReplicaState { committed: m, ..s.replicas[r] }), ..s }
}

pub proof fn lemma_replica_commit(cfg: Config, s: SystemState, r: int, m: int)
    requires
        cfg.replicas.contains(r),
        s.replicas[r].committed <= m <= s.committed,
        m <= s.replicas[r].olog.len(),
    ensures
        Next(cfg, s, after_replica_commit(cfg, s, r, m)),
        after_replica_commit(cfg, s, r, m).replicas[r] == (ReplicaState { committed: m, ..s.replicas[r] }),
        forall|q: int| q != r ==> #[trigger] after_replica_commit(cfg, s, r, m).replicas[q] == s.replicas[q],
        after_replica_commit(cfg, s, r, m).network == s.network,
        after_replica_commit(cfg, s, r, m).clients == s.clients,
        after_replica_commit(cfg, s, r, m).base_view == s.base_view,
        after_replica_commit(cfg, s, r, m).log == s.log,
        after_replica_commit(cfg, s, r, m).committed == s.committed,
{
    let s_ = after_replica_commit(cfg, s, r, m);
    assert(ReplicaCommit(cfg, s, s_, r, m));
    assert(NextStep(cfg, s, s_, SysStep::ReplicaCommit { r: r, m: m }));
}

} // verus!
