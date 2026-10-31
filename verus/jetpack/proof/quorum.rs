//! Quorum arithmetic for the pseudocode §0's sizes with constant membership (not trusted): majorities
//! intersect; every majority meets every superquorum in at least t replicas.
use crate::common::quorum::lemma_quorum_intersection;
use crate::model::types::*;
use crate::proof::defs::*;
use vstd::prelude::*;
use vstd::set_lib::*;

verus! {

/// Two majorities share a replica.
pub proof fn lemma_maj_intersect(cfg: Config, q1: Set<int>, q2: Set<int>) -> (r: int)
    requires
        wf(cfg),
        is_maj(cfg, q1),
        is_maj(cfg, q2),
    ensures
        q1.contains(r),
        q2.contains(r),
{
    lemma_wf_n(cfg);
    lemma_quorum_intersection(q1, q2, cfg.replicas);
    choose|r: int| #[trigger] q1.contains(r) && q2.contains(r)
}

/// A majority has a member.
pub proof fn lemma_maj_member(cfg: Config, q: Set<int>) -> (r: int)
    requires
        wf(cfg),
        is_maj(cfg, q),
    ensures
        q.contains(r),
{
    lemma_wf_n(cfg);
    lemma_set_empty_equivalency_len(q);
    choose|r: int| q.contains(r)
}

/// A superquorum and a majority share at least t replicas (the pseudocode §0 "why").
pub proof fn lemma_sq_maj_meet(cfg: Config, q: Set<int>, m: Set<int>)
    requires
        wf(cfg),
        q.subset_of(cfg.replicas),
        q.len() >= sq(cfg),
        is_maj(cfg, m),
    ensures
        q.intersect(m).len() >= t(cfg),
        q.intersect(m).subset_of(m),
{
    lemma_wf_n(cfg);
    lemma_set_intersect_union_lens(q, m);
    assert((q + m).subset_of(cfg.replicas));
    lemma_len_subset(q + m, cfg.replicas);
}

/// A subset of a finite set is no larger.
pub proof fn lemma_subset_len(a: Set<int>, b: Set<int>)
    requires
        a.subset_of(b),
    ensures
        a.len() <= b.len(),
{
    lemma_len_subset(a, b);
}

} // verus!
