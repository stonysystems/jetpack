//! Quorum facts that more than one protocol needs.
use vstd::prelude::*;

verus! {

/// Two subsets of a finite universe whose sizes add up to more than the
/// universe's size share an element (inclusion-exclusion). Same argument as
/// `src/common/collections/sets.rs`'s `lemma_quorum_intersection`, restated
/// here because the zoo does not link against the main crate.
pub proof fn lemma_quorum_intersection<T>(a: Set<T>, b: Set<T>, u: Set<T>)
    requires
        a.subset_of(u),
        b.subset_of(u),
        a.len() + b.len() > u.len(),
    ensures
        exists|w: T| #![trigger a.contains(w)] #![trigger b.contains(w)] a.contains(w) && b.contains(w),
{
    vstd::set_lib::lemma_len_subset(a, u);
    vstd::set_lib::lemma_len_subset(b, u);
    assert((a + b).subset_of(u));
    vstd::set_lib::lemma_len_subset(a + b, u);
    vstd::set_lib::lemma_set_intersect_union_lens(a, b);
    if a.intersect(b).len() == 0 {
        assert(a.intersect(b) =~= Set::<T>::empty());
        assert(false);
    }
    let w = a.intersect(b).choose();
    assert(a.intersect(b).contains(w));
}

/// Majorities of the same finite universe intersect.
pub proof fn lemma_majorities_intersect<T>(a: Set<T>, b: Set<T>, u: Set<T>)
    requires
        a.subset_of(u),
        b.subset_of(u),
        2 * a.len() > u.len(),
        2 * b.len() > u.len(),
    ensures
        exists|w: T| #![trigger a.contains(w)] #![trigger b.contains(w)] a.contains(w) && b.contains(w),
{
    lemma_quorum_intersection(a, b, u);
}

} // verus!
