//! Facts about one replica's transitions (not trusted): `learn`, `join`, the promise updates
//! of L16 and L36-L37, and `replica_mono` as a preorder.
use crate::model::replica::*;
use crate::model::types::*;
use crate::proof::bal::*;
use crate::proof::defs::*;
use vstd::prelude::*;

verus! {

pub proof fn lemma_replica_mono_refl(st: ReplicaState)
    ensures
        replica_mono(st, st),
{
}

pub proof fn lemma_replica_mono_trans(a: ReplicaState, b: ReplicaState, c: ReplicaState)
    requires
        replica_mono(a, b),
        replica_mono(b, c),
    ensures
        replica_mono(a, c),
{
    assert forall|j: int| 0 <= j < a.olog.len() implies #[trigger] c.olog[j] == a.olog[j] by {
        assert(b.olog[j] == a.olog[j]);
    }
    assert forall|w: int| bal_le(promise_of(a, w), #[trigger] promise_of(c, w)) by {
        lemma_bal_le_trans(promise_of(a, w), promise_of(b, w), promise_of(c, w));
    }
    assert forall|w: int| #[trigger] a.accepted.contains_key(w) implies {
        &&& c.accepted.contains_key(w)
        &&& (c.accepted[w] == a.accepted[w] || bal_le(promise_of(a, w), acc_bal(c.accepted[w])))
    } by {
        assert(b.accepted.contains_key(w));
        if c.accepted[w] == b.accepted[w] {
        } else {
            lemma_bal_le_trans(promise_of(a, w), promise_of(b, w), acc_bal(c.accepted[w]));
        }
    }
}

/// learn(u) (the pseudocode §0): what it changes, and that it only moves forward.
pub proof fn lemma_learn_facts(st: ReplicaState, u: int)
    ensures
        learn(st, u).lnv == (if u > st.lnv { u } else { st.lnv }),
        learn(st, u).nv == (if u > st.lnv && u >= st.nv { u } else { st.nv }),
        learn(st, u).mode == (if u > st.lnv && u >= st.nv { Mode::Normal } else { st.mode }),
        learn(st, u).pool == (if u > st.lnv { Set::<int>::empty() } else { st.pool }),
        learn(st, u).msb == st.msb,
        learn(st, u).accepted == st.accepted,
        learn(st, u).coord == st.coord,
        learn(st, u).olog == st.olog,
        learn(st, u).committed == st.committed,
        learn(st, u).lnv >= u,
        learn(st, u).lnv >= st.lnv,
        learn(st, u).nv >= st.nv,
        learn(st, u).lnv == st.lnv ==> learn(st, u) == st,
        forall|w: int| #[trigger] msb_of(learn(st, u), w) == msb_of(st, w),
        replica_mono(st, learn(st, u)),
{
    let st_ = learn(st, u);
    assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
        assert(msb_of(st_, w) == msb_of(st, w));
    }
}

/// learn(u) keeps the pseudocode §0's replica invariants when u is one of the original protocol's views
/// or ⊥ (then learn does nothing).
pub proof fn lemma_learn_wf(st: ReplicaState, u: int, base_view: int)
    requires
        v0() <= st.lnv <= st.nv <= base_view,
        st.mode is Recovery <==> st.nv > st.lnv,
        bot() <= u <= base_view,
    ensures
        v0() <= learn(st, u).lnv <= learn(st, u).nv <= base_view,
        learn(st, u).mode is Recovery <==> learn(st, u).nv > learn(st, u).lnv,
{
    lemma_learn_facts(st, u);
}

/// join(v) (the pseudocode §0): what it changes; the promise for every w becomes (v, ⊥), above the old one.
pub proof fn lemma_join_facts(st: ReplicaState, v: int)
    requires
        v > st.nv,
    ensures
        join(st, v).lnv == st.lnv,
        join(st, v).nv == v,
        join(st, v).mode is Recovery,
        join(st, v).pool == st.pool,
        join(st, v).accepted == st.accepted,
        join(st, v).coord == st.coord,
        join(st, v).olog == st.olog,
        join(st, v).committed == st.committed,
        forall|w: int| msb_of(#[trigger] join(st, v), w) == bot(),
        forall|w: int| promise_of(#[trigger] join(st, v), w) == (Bal { v: v, k: bot() }),
        replica_mono(st, join(st, v)),
{
    let st_ = join(st, v);
    assert forall|w: int| msb_of(#[trigger] join(st, v), w) == bot() by {
        assert(!st_.msb.contains_key(w));
    }
    assert forall|w: int| bal_le(promise_of(st, w), #[trigger] promise_of(st_, w)) by {
        assert(promise_of(st_, w) == (Bal { v: v, k: bot() }));
        assert(bal_lt(promise_of(st, w), promise_of(st_, w)));
    }
}

/// `join_if_newer` after a passed step 1 (v >= R.new_view): R.new_view becomes v, and the pseudocode §0's
/// mode invariant is kept.
pub proof fn lemma_join_if_newer_facts(st: ReplicaState, v: int)
    requires
        v >= st.nv,
        st.lnv <= st.nv,
        st.mode is Recovery <==> st.nv > st.lnv,
    ensures
        join_if_newer(st, v).nv == v,
        join_if_newer(st, v).lnv == st.lnv,
        join_if_newer(st, v).pool == st.pool,
        join_if_newer(st, v).accepted == st.accepted,
        join_if_newer(st, v).coord == st.coord,
        join_if_newer(st, v).olog == st.olog,
        join_if_newer(st, v).committed == st.committed,
        join_if_newer(st, v).mode is Recovery <==> v > st.lnv,
        forall|w: int| #[trigger] msb_of(join_if_newer(st, v), w) == (if v > st.nv { bot() } else { msb_of(st, w) }),
        replica_mono(st, join_if_newer(st, v)),
{
    if v > st.nv {
        lemma_join_facts(st, v);
        assert(join_if_newer(st, v) == join(st, v));
    } else {
        assert(join_if_newer(st, v) == st);
        lemma_replica_mono_refl(st);
    }
}

/// L16: raising max_seen_ballot[w] to k >= the old value keeps the promises monotone.
pub proof fn lemma_msb_insert_mono(st: ReplicaState, w: int, k: int)
    requires
        k >= msb_of(st, w),
    ensures
        replica_mono(st, ReplicaState { msb: st.msb.insert(w, k), ..st }),
        msb_of(ReplicaState { msb: st.msb.insert(w, k), ..st }, w) == k,
        forall|w2: int| w2 != w ==> #[trigger] msb_of(ReplicaState { msb: st.msb.insert(w, k), ..st }, w2) == msb_of(st, w2),
{
    let st_ = ReplicaState { msb: st.msb.insert(w, k), ..st };
    assert forall|w2: int| bal_le(promise_of(st, w2), #[trigger] promise_of(st_, w2)) by {
        if w2 == w {
            assert(msb_of(st_, w) == k);
        } else {
            assert(msb_of(st_, w2) == msb_of(st, w2));
        }
    }
}

/// L36-L37: taking Accept(v, w, k, val) at R.new_view = v with k >= max_seen_ballot[w].
pub proof fn lemma_accept_insert_mono(st: ReplicaState, w: int, k: int, v: int, val: Set<int>)
    requires
        k >= msb_of(st, w),
        st.nv == v,
    ensures
        replica_mono(st, ReplicaState { msb: st.msb.insert(w, k), accepted: st.accepted.insert(w, Acc { view: v, k: k, val: val }), ..st }),
        promise_of(ReplicaState { msb: st.msb.insert(w, k), accepted: st.accepted.insert(w, Acc { view: v, k: k, val: val }), ..st }, w) == (Bal { v: v, k: k }),
        forall|w2: int| w2 != w ==> #[trigger] msb_of(ReplicaState { msb: st.msb.insert(w, k), accepted: st.accepted.insert(w, Acc { view: v, k: k, val: val }), ..st }, w2) == msb_of(st, w2),
{
    let st_ = ReplicaState { msb: st.msb.insert(w, k), accepted: st.accepted.insert(w, Acc { view: v, k: k, val: val }), ..st };
    assert forall|w2: int| bal_le(promise_of(st, w2), #[trigger] promise_of(st_, w2)) by {
        if w2 == w {
            assert(msb_of(st_, w) == k);
        } else {
            assert(msb_of(st_, w2) == msb_of(st, w2));
        }
    }
    assert forall|w2: int| #[trigger] st.accepted.contains_key(w2) implies {
        &&& st_.accepted.contains_key(w2)
        &&& (st_.accepted[w2] == st.accepted[w2] || bal_le(promise_of(st, w2), acc_bal(st_.accepted[w2])))
    } by {
        if w2 == w {
            assert(st_.accepted[w2] == (Acc { view: v, k: k, val: val }));
            assert(bal_le(promise_of(st, w), Bal { v: v, k: k }));
        } else {
            assert(st_.accepted[w2] == st.accepted[w2]);
        }
    }
}

} // verus!
