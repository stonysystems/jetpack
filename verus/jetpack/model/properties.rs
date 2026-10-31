//! The properties `top.rs` states (definitions only, trusted): well-formedness of a
//! configuration, the pseudocode §0's replica invariants, RecoveredAgreement, FastCommitDurability
//! (paper C1 Case 3 with the GC rule), Principle 2 as a log property.
use crate::model::client::*;
use crate::model::replica::*;
use crate::model::system::*;
use crate::model::types::*;
use vstd::prelude::*;

verus! {

/// A well-formed configuration: a nonempty replica set (sets are finite), every view's proposer
/// a replica.
pub open spec fn WellFormed(cfg: Config) -> bool {
    &&& cfg.replicas.len() >= 1
    &&& forall|v: int| cfg.replicas.contains(#[trigger] (cfg.proposer)(v))
}

// ---------------------------------------------------------------------------------------------
// 1. the pseudocode §0 "Invariants on every Jetpack replica R"
// ---------------------------------------------------------------------------------------------

/// R.last_normal_view <= R.new_view; R.mode = Recovery <==> R.new_view > R.last_normal_view.
pub open spec fn ReplicaInvariants(cfg: Config, s: SystemState) -> bool {
    forall|r: int| #[trigger] cfg.replicas.contains(r) ==> {
        &&& s.replicas[r].lnv <= s.replicas[r].nv
        &&& (s.replicas[r].mode is Recovery <==> s.replicas[r].nv > s.replicas[r].lnv)
    }
}

/// Over one step: neither view ever decreases, and the pool changes only while R is Normal:
/// once R.new_view > R.last_normal_view = w, R.pool[w] is frozen (no acks, GC frozen) until
/// last_normal_view advances (and then pool[w] is never read again).
pub open spec fn ReplicaStepInvariants(cfg: Config, s: SystemState, s_: SystemState) -> bool {
    forall|r: int| #[trigger] cfg.replicas.contains(r) ==> {
        &&& s_.replicas[r].lnv >= s.replicas[r].lnv
        &&& s_.replicas[r].nv >= s.replicas[r].nv
        &&& (s_.replicas[r].pool != s.replicas[r].pool
            ==> s.replicas[r].mode is Normal || s_.replicas[r].lnv > s.replicas[r].lnv)
    }
}

// ---------------------------------------------------------------------------------------------
// 2. RecoveredAgreement
// ---------------------------------------------------------------------------------------------

/// Two Recovered entries, in any replicas' logs, that recover the same fast-path view carry the
/// same set.
pub open spec fn RecoveredAgreement(cfg: Config, s: SystemState) -> bool {
    forall|r1: int, j1: int, r2: int, j2: int|
        cfg.replicas.contains(r1) && cfg.replicas.contains(r2)
        && 0 <= j1 < s.replicas[r1].olog.len() && 0 <= j2 < s.replicas[r2].olog.len()
        && #[trigger] s.replicas[r1].olog[j1] is Recovered && #[trigger] s.replicas[r2].olog[j2] is Recovered
        && s.replicas[r1].olog[j1]->Recovered_vn == s.replicas[r2].olog[j2]->Recovered_vn
        ==> s.replicas[r1].olog[j1]->Recovered_cmds == s.replicas[r2].olog[j2]->Recovered_cmds
}

// ---------------------------------------------------------------------------------------------
// 3. FastCommitDurability
// ---------------------------------------------------------------------------------------------

/// Replica r ack'd c in fast-path view w (N16).
pub open spec fn acked(s: SystemState, r: int, w: int, c: int) -> bool {
    exists|p: Packet| #[trigger] s.network.contains(p) && p.src == (Addr::Replica { id: r }) && p.msg == (Msg::FastAck { view: w, cmd: c })
}

/// c was fast-committed in view w (N2-N3, Principle 1): a superquorum of replicas(w), containing
/// every proposer of w, each ack'd c while its last normal view was w and it was Normal.
pub open spec fn fast_committed(cfg: Config, s: SystemState, w: int, c: int) -> bool {
    exists|q: Set<int>| #[trigger] q.subset_of(cfg.replicas) && q.len() >= sq(cfg)
        && q.contains((cfg.proposer)(w))
        && forall|r: int| #[trigger] q.contains(r) ==> acked(s, r, w, c)
}

/// c is in the committed prefix of some replica's copy of the original log.
pub open spec fn committed_cmd(cfg: Config, s: SystemState, c: int) -> bool {
    exists|r: int, j: int| cfg.replicas.contains(r) && 0 <= j < s.replicas[r].committed
        && #[trigger] entry_cmds(s.replicas[r].olog[j]).contains(c)
}

/// If c was fast-committed in w then every Recovered entry that recovers w contains c, or c is
/// committed on the original path (paper C1 Case 3 with the GC rule: a replica removes an ack'd
/// command from its pool only once the original path committed it).
pub open spec fn FastCommitDurability(cfg: Config, s: SystemState) -> bool {
    forall|w: int, c: int, r: int, j: int|
        cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] s.replicas[r].olog[j] is Recovered && s.replicas[r].olog[j]->Recovered_vn == w
        && #[trigger] fast_committed(cfg, s, w, c)
        ==> s.replicas[r].olog[j]->Recovered_cmds.contains(c) || committed_cmd(cfg, s, c)
}

/// The same, for the fast commits the clients decided.
pub open spec fn ClientFastCommitDurability(cfg: Config, s: SystemState) -> bool {
    forall|k: int, fc: FastCommit, r: int, j: int|
        cfg.clients.contains(k) && #[trigger] s.clients[k].fast.contains(fc)
        && cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] s.replicas[r].olog[j] is Recovered && s.replicas[r].olog[j]->Recovered_vn == fc.view
        ==> s.replicas[r].olog[j]->Recovered_cmds.contains(fc.cmd) || committed_cmd(cfg, s, fc.cmd)
}

// ---------------------------------------------------------------------------------------------
// 5. Two schedules of the recovery audit, excluded
// ---------------------------------------------------------------------------------------------

/// JETPACK-001 excluded (L14 joins v before L16-L20 reply): a replica that answered a Prepare
/// for fast-path view w has new_view above w, so it is not Normal in w and never acks in w
/// again (N12).
pub open spec fn PrepareOkFreezes(cfg: Config, s: SystemState) -> bool {
    forall|p: Packet| #[trigger] s.network.contains(p) && p.msg is PrepareOK && p.src is Replica && cfg.replicas.contains(p.src->Replica_id) ==> {
        let st = s.replicas[p.src->Replica_id];
        &&& st.nv > p.msg->PrepareOK_vn
        &&& !(st.mode is Normal && st.lnv == p.msg->PrepareOK_vn)
    }
}

/// Over one step: a FastAck(w, c) is sent only by a replica that is Normal with last normal
/// view w (N12-N16). With `PrepareOkFreezes`: no replica acks in a view it answered a Prepare for.
pub open spec fn AcksOnlyWhenNormal(cfg: Config, s: SystemState, s_: SystemState) -> bool {
    forall|p: Packet| #[trigger] s_.network.contains(p) && !s.network.contains(p) && p.msg is FastAck ==> {
        &&& p.src is Replica
        &&& cfg.replicas.contains(p.src->Replica_id)
        &&& s.replicas[p.src->Replica_id].mode is Normal
        &&& s.replicas[p.src->Replica_id].lnv == p.msg->FastAck_view
    }
}

/// JETPACK-002 excluded (learn's second branch, the pseudocode §0 l.66): a replica in Recovery that
/// receives FinishRecovery(v, ·) for a view below its new_view stays in Recovery, in the same
/// new view.
pub open spec fn StaleFinishRecoveryKeepsRecovery(cfg: Config, s: SystemState, s_: SystemState) -> bool {
    forall|r: int, pkt: Packet, sent: Set<Packet>|
        cfg.replicas.contains(r) && #[trigger] ReplicaNodeStep(cfg, s, s_, r, ReplicaStep::RecvFinishRecovery { pkt }, sent)
        && s.replicas[r].mode is Recovery && pkt.msg->FinishRecovery_view < s.replicas[r].nv
        ==> s_.replicas[r].mode is Recovery && s_.replicas[r].nv == s.replicas[r].nv
}

// ---------------------------------------------------------------------------------------------
// 4. Principle 2 as a log property
// ---------------------------------------------------------------------------------------------

/// In every replica's copy of the original log, the first entry of every view other than v_0 is
/// a Recovered entry (T2: Recovered(S) is the proposer's first entry of v).
pub open spec fn Principle2(cfg: Config, s: SystemState) -> bool {
    forall|r: int, j: int|
        cfg.replicas.contains(r) && 0 <= j < s.replicas[r].olog.len()
        && #[trigger] entry_view(s.replicas[r].olog[j]) != v0()
        && (forall|i: int| 0 <= i < j ==> entry_view(#[trigger] s.replicas[r].olog[i]) != entry_view(s.replicas[r].olog[j]))
        ==> s.replicas[r].olog[j] is Recovered
}

} // verus!
