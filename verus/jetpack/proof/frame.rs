//! The frame of a node step (not trusted): what `ReplicaNodeStep` and `ClientNodeStep` say
//! about the system state around the stepping node; packet-set membership for `broadcast`,
//! `to_replicas` and `send_to`; `mono` from a replica's own monotonicity.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use crate::proof::replica_lemmas::*;
use vstd::prelude::*;

verus! {

// ---------------------------------------------------------------------------------------------
// Packet sets
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_to_replicas_contains(replicas: Set<int>, src: Addr, m: Msg, p: Packet)
    ensures
        to_replicas(replicas, src, m).contains(p) <==> replicas.contains(dst_replica(p)) && p == to_replica(src, m, dst_replica(p)),
{
}

pub proof fn lemma_to_replicas_has(replicas: Set<int>, src: Addr, m: Msg, r: int)
    requires
        replicas.contains(r),
    ensures
        to_replicas(replicas, src, m).contains(to_replica(src, m, r)),
{
    lemma_to_replicas_contains(replicas, src, m, to_replica(src, m, r));
}

/// Every packet of a broadcast carries the message and comes from this replica.
pub proof fn lemma_broadcast_msgs(c: ReplicaConsts, m: Msg)
    ensures
        forall|p: Packet| #[trigger] broadcast(c, m).contains(p) ==> p.msg == m && p.src == me(c),
{
    assert forall|p: Packet| #[trigger] broadcast(c, m).contains(p) implies p.msg == m && p.src == me(c) by {
        lemma_to_replicas_contains(c.replicas, me(c), m, p);
    }
}

pub proof fn lemma_broadcast_has(c: ReplicaConsts, m: Msg, r: int)
    requires
        c.replicas.contains(r),
    ensures
        broadcast(c, m).contains(Packet { src: me(c), dst: Addr::Replica { id: r }, msg: m }),
{
    lemma_to_replicas_has(c.replicas, me(c), m, r);
}

pub proof fn lemma_send_to_msgs(c: ReplicaConsts, dst: Addr, m: Msg)
    ensures
        forall|p: Packet| #[trigger] send_to(c, dst, m).contains(p) ==> p == (Packet { src: me(c), dst: dst, msg: m }),
        send_to(c, dst, m).contains(Packet { src: me(c), dst: dst, msg: m }),
{
}

// ---------------------------------------------------------------------------------------------
// The frame of a replica step
// ---------------------------------------------------------------------------------------------

/// What `ReplicaNodeStep` fixes outside the stepping replica's own transition.
pub proof fn lemma_replica_step_frame(cfg: Config, s: SystemState, s_: SystemState, r: int, step: ReplicaStep, sent: Set<Packet>)
    requires
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, step, sent),
    ensures
        cfg.replicas.contains(r),
        s_.replicas.dom() == s.replicas.dom(),
        forall|r2: int| #[trigger] cfg.replicas.contains(r2) && r2 != r ==> s_.replicas[r2] == s.replicas[r2],
        s_.clients == s.clients,
        s_.network == s.network.union(sent),
        s.network.subset_of(s_.network),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) ==> sent.contains(p),
        forall|p: Packet| #[trigger] sent.contains(p) ==> s_.network.contains(p),
        s_.base_view == s.base_view,
        s_.committed == s.committed,
        s_.log == s.log + step_appends(cfg, s, r, step),
        s.log.len() <= s_.log.len(),
        forall|j: int| 0 <= j < s.log.len() ==> #[trigger] s_.log[j] == s.log[j],
        s_.votes == s.votes.union(votes_cast(r, s.replicas[r], step)),
        s.votes.subset_of(s_.votes),
        forall|vt: Vote| #[trigger] s_.votes.contains(vt) && !s.votes.contains(vt) ==> votes_cast(r, s.replicas[r], step).contains(vt),
        forall|p: Packet| #[trigger] replica_received(step).contains(p) ==> s.network.contains(p) && p.dst == (Addr::Replica { id: r }),
        ReplicaNext(replica_consts(cfg, r), s.replicas[r], s_.replicas[r], step, sent),
        step_base_guard(cfg, s, r, step),
{
    assert(s_.replicas.dom() =~= s.replicas.dom());
    let app = step_appends(cfg, s, r, step);
    assert forall|j: int| 0 <= j < s.log.len() implies #[trigger] s_.log[j] == s.log[j] by {
        assert((s.log + app)[j] == s.log[j]);
    }
}

/// `mono` from the stepping replica's own monotonicity and its votes' ballots.
pub proof fn lemma_replica_step_mono(cfg: Config, s: SystemState, s_: SystemState, r: int, step: ReplicaStep, sent: Set<Packet>)
    requires
        inv(cfg, s),
        ReplicaNodeStep(cfg, s, s_, r, step, sent),
        replica_mono(s.replicas[r], s_.replicas[r]),
        forall|vt: Vote| #[trigger] votes_cast(r, s.replicas[r], step).contains(vt) ==> vt.r == r && bal_le(promise(s, r, vt.vn), vt.bal),
    ensures
        mono(cfg, s, s_),
{
    lemma_replica_step_frame(cfg, s, s_, r, step, sent);
    assert forall|r2: int| #[trigger] cfg.replicas.contains(r2) implies replica_mono(s.replicas[r2], s_.replicas[r2]) by {
        if r2 != r {
            lemma_replica_mono_refl(s.replicas[r2]);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The frame of a client step
// ---------------------------------------------------------------------------------------------

pub proof fn lemma_client_step_frame(cfg: Config, s: SystemState, s_: SystemState, k: int, step: ClientStep, sent: Set<Packet>)
    requires
        inv(cfg, s),
        ClientNodeStep(cfg, s, s_, k, step, sent),
    ensures
        cfg.clients.contains(k),
        s_.clients.dom() == s.clients.dom(),
        forall|k2: int| #[trigger] cfg.clients.contains(k2) && k2 != k ==> s_.clients[k2] == s.clients[k2],
        s_.replicas == s.replicas,
        s_.network == s.network.union(sent),
        s.network.subset_of(s_.network),
        forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) ==> sent.contains(p),
        s_.base_view == s.base_view,
        s_.committed == s.committed,
        s_.log == s.log,
        s_.votes == s.votes,
        forall|p: Packet| #[trigger] client_received(step).contains(p) ==> s.network.contains(p) && p.dst == (Addr::Client { id: k }),
        ClientNext(client_consts(cfg, k), s.clients[k], s_.clients[k], step, sent),
        mono(cfg, s, s_),
{
    assert(s_.clients.dom() =~= s.clients.dom());
    assert forall|r2: int| #[trigger] cfg.replicas.contains(r2) implies replica_mono(s.replicas[r2], s_.replicas[r2]) by {
        lemma_replica_mono_refl(s.replicas[r2]);
    }
}

} // verus!
