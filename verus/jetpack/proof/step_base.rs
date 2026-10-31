//! The original protocol's steps (not trusted): `NewView` (T1, L1-L3), `AppendCmd` (N11,
//! N19-N20, T2), `Replicate`, `AdvanceCommit`, `ReplicaCommit` (A1-A3) preserve `inv`.
use crate::model::client::*;
use crate::model::properties::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use crate::proof::defs::*;
use crate::proof::frame::*;
use crate::proof::keep::*;
use crate::proof::mono::*;
use crate::proof::replica_lemmas::*;
use vstd::prelude::*;

verus! {

/// `mono` for a step of the original protocol in which every replica is `replica_mono`.
pub proof fn lemma_base_mono(cfg: Config, s: SystemState, s_: SystemState)
    requires
        inv(cfg, s),
        s.network.subset_of(s_.network),
        s_.votes == s.votes,
        s_.replicas.dom() == s.replicas.dom(),
        s_.clients == s.clients,
        s.base_view <= s_.base_view,
        s.log.len() <= s_.log.len(),
        forall|j: int| 0 <= j < s.log.len() ==> #[trigger] s_.log[j] == s.log[j],
        s.committed <= s_.committed,
        forall|r: int| #[trigger] cfg.replicas.contains(r) ==> replica_mono(s.replicas[r], s_.replicas[r]),
    ensures
        mono(cfg, s, s_),
{
}

/// T1, L1-L3.
pub proof fn lemma_new_view_inv(cfg: Config, s: SystemState, s_: SystemState, v: int)
    requires
        wf(cfg),
        inv(cfg, s),
        NewView(cfg, s, s_, v),
    ensures
        inv(cfg, s_),
{
    let p = (cfg.proposer)(v);
    let c = replica_consts(cfg, p);
    let st = s.replicas[p];
    let st_ = s_.replicas[p];
    assert(s_.replicas.dom() =~= s.replicas.dom());
    assert(st_ == ReplicaState { coord: Coord { phase: Phase::P1, view: v, vn: bot(), k: 0, rset: Set::<int>::empty() }, ..st });
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies replica_mono(s.replicas[r], s_.replicas[r]) by {
        if r == p {
            lemma_replica_mono_refl(st);
            assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
                assert(promise_of(st_, w) == promise_of(st, w));
            }
        } else {
            assert(s_.replicas[r] == s.replicas[r]);
            lemma_replica_mono_refl(s.replicas[r]);
        }
    }
    lemma_base_mono(cfg, s, s_);
    let msg = Msg::BeginRecovery { view: v };
    lemma_broadcast_msgs(c, msg);
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) && r != p implies s_.replicas[r] == s.replicas[r] by {}
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && !s.network.contains(q)
        implies msg_ok(cfg, s_, q) && (q.src is Client || q.src == (Addr::Replica { id: p })) by {
        assert(broadcast(c, msg).contains(q));
        assert(q.msg == msg && q.src == me(c));
    }
    // the new coordinator: no message of view v exists yet
    assert(replica_wf(cfg, s, p));
    lemma_replica_wf_keep(cfg, s, s_, p);
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && q.msg is Accept && q.msg->Accept_view == v implies false by {
        assert(s.network.contains(q));
        assert(msg_ok(cfg, s, q));
    }
    assert(coord_ok(cfg, s_, p));
    lemma_accepted_ok_keep(cfg, s, s_, p);
    lemma_acks_ok_keep(cfg, s, s_, p);
    lemma_poks_ok_keep(cfg, s, s_, p);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, p);
}

/// N11, N19-N20 with T2.
pub proof fn lemma_append_cmd_inv(cfg: Config, s: SystemState, s_: SystemState, cmd: int)
    requires
        wf(cfg),
        inv(cfg, s),
        AppendCmd(cfg, s, s_, cmd),
    ensures
        inv(cfg, s_),
{
    let e = Entry::Cmd { view: s.base_view, cmd: cmd };
    assert(s_.log == s.log.push(e));
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies replica_mono(s.replicas[r], s_.replicas[r]) by {
        lemma_replica_mono_refl(s.replicas[r]);
    }
    lemma_base_mono(cfg, s, s_);
    lemma_wf_proposer(cfg, v0());
    let r0 = (cfg.proposer)(v0());
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && !s.network.contains(q)
        implies msg_ok(cfg, s_, q) && (q.src is Client || q.src == (Addr::Replica { id: r0 })) by {}
    lemma_preds_unchanged(cfg, s, s_, r0);
    if entry_view(e) != v0() {
        assert(exists|j: int| 0 <= j < s.committed && #[trigger] s.log[j] is Recovered && s.log[j]->Recovered_view == s.base_view);
        let j = choose|j: int| 0 <= j < s.committed && #[trigger] s.log[j] is Recovered && s.log[j]->Recovered_view == s.base_view;
        assert(0 <= j < s.log.len() && s.log[j] is Recovered && entry_view(s.log[j]) == entry_view(e));
    }
    lemma_log_ok_push(cfg, s, s_, e);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r0);
}

/// A replica's copy of the original log grows (a longer prefix).
pub proof fn lemma_replicate_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, m: int)
    requires
        wf(cfg),
        inv(cfg, s),
        Replicate(cfg, s, s_, r, m),
    ensures
        inv(cfg, s_),
{
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(s_.replicas.dom() =~= s.replicas.dom());
    assert(st_ == ReplicaState { olog: s.log.subrange(0, m), ..st });
    assert(replica_wf(cfg, s, r));
    assert(st_.olog.len() == m);
    assert forall|j: int| 0 <= j < m implies #[trigger] st_.olog[j] == s.log[j] by {}
    assert forall|q: int| #[trigger] cfg.replicas.contains(q) implies replica_mono(s.replicas[q], s_.replicas[q]) by {
        if q == r {
            assert forall|j: int| 0 <= j < st.olog.len() implies #[trigger] st_.olog[j] == st.olog[j] by {
                assert(st.olog[j] == s.log[j]);
            }
            assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
                assert(promise_of(st_, w) == promise_of(st, w));
            }
        } else {
            assert(s_.replicas[q] == s.replicas[q]);
            lemma_replica_mono_refl(s.replicas[q]);
        }
    }
    lemma_base_mono(cfg, s, s_);
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && !s.network.contains(q)
        implies msg_ok(cfg, s_, q) && (q.src is Client || q.src == (Addr::Replica { id: r })) by {}
    assert(replica_wf(cfg, s_, r));
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

/// A1-A2: the original protocol commits a longer prefix.
pub proof fn lemma_advance_commit_inv(cfg: Config, s: SystemState, s_: SystemState, m: int)
    requires
        wf(cfg),
        inv(cfg, s),
        AdvanceCommit(cfg, s, s_, m),
    ensures
        inv(cfg, s_),
{
    assert forall|r: int| #[trigger] cfg.replicas.contains(r) implies replica_mono(s.replicas[r], s_.replicas[r]) by {
        lemma_replica_mono_refl(s.replicas[r]);
    }
    lemma_base_mono(cfg, s, s_);
    lemma_wf_proposer(cfg, v0());
    let r0 = (cfg.proposer)(v0());
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && !s.network.contains(q)
        implies msg_ok(cfg, s_, q) && (q.src is Client || q.src == (Addr::Replica { id: r0 })) by {}
    lemma_preds_unchanged(cfg, s, s_, r0);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r0);
}

/// A3: a replica executes a longer committed prefix of its copy.
pub proof fn lemma_replica_commit_inv(cfg: Config, s: SystemState, s_: SystemState, r: int, m: int)
    requires
        wf(cfg),
        inv(cfg, s),
        ReplicaCommit(cfg, s, s_, r, m),
    ensures
        inv(cfg, s_),
{
    let st = s.replicas[r];
    let st_ = s_.replicas[r];
    assert(s_.replicas.dom() =~= s.replicas.dom());
    assert(st_ == ReplicaState { committed: m, ..st });
    assert(replica_wf(cfg, s, r));
    assert forall|q: int| #[trigger] cfg.replicas.contains(q) implies replica_mono(s.replicas[q], s_.replicas[q]) by {
        if q == r {
            assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
                assert(promise_of(st_, w) == promise_of(st, w));
            }
        } else {
            assert(s_.replicas[q] == s.replicas[q]);
            lemma_replica_mono_refl(s.replicas[q]);
        }
    }
    lemma_base_mono(cfg, s, s_);
    assert forall|q: Packet| #[trigger] s_.network.contains(q) && !s.network.contains(q)
        implies msg_ok(cfg, s_, q) && (q.src is Client || q.src == (Addr::Replica { id: r })) by {}
    assert(replica_wf(cfg, s_, r));
    lemma_coord_ok_keep(cfg, s, s_, r);
    lemma_accepted_ok_keep(cfg, s, s_, r);
    lemma_acks_ok_keep(cfg, s, s_, r);
    lemma_poks_ok_keep(cfg, s, s_, r);
    lemma_log_ok_same(cfg, s, s_);
    lemma_one_decree_no_accept(s, s_);
    lemma_clients_unchanged(cfg, s, s_);
    lemma_inv_assemble(cfg, s, s_, r);
}

} // verus!
