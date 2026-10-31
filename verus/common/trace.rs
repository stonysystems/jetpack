//! Behaviors: the one notion both a proof and a refutation are stated over.
//!
//! A proof shows that every behavior keeps a property; a refutation exhibits
//! one behavior that breaks it. Both use `is_behavior`, so a counterexample
//! cannot quietly rely on a weaker notion of "reachable" than the proof does.
use vstd::prelude::*;

verus! {

/// `tr` is a finite prefix of a behavior: it starts in an initial state and
/// every consecutive pair is a step. Stuttering is not a step here; a trace
/// that needs one simply omits it.
pub open spec fn is_behavior<S>(init: spec_fn(S) -> bool, next: spec_fn(S, S) -> bool, tr: Seq<S>) -> bool {
    &&& tr.len() >= 1
    &&& init(tr[0])
    &&& forall|i: int| 0 <= i < tr.len() - 1 ==> #[trigger] next(tr[i], tr[i + 1])
}

/// An inductive invariant holds in every state of every behavior.
pub proof fn lemma_invariant_holds_on_behavior<S>(
    init: spec_fn(S) -> bool,
    next: spec_fn(S, S) -> bool,
    inv: spec_fn(S) -> bool,
    tr: Seq<S>,
)
    requires
        is_behavior(init, next, tr),
        forall|s: S| init(s) ==> #[trigger] inv(s),
        forall|s: S, s_: S| inv(s) && #[trigger] next(s, s_) ==> inv(s_),
    ensures
        forall|i: int| 0 <= i < tr.len() ==> #[trigger] inv(tr[i]),
{
    assert forall|i: int| 0 <= i < tr.len() implies #[trigger] inv(tr[i]) by {
        lemma_invariant_holds_at(init, next, inv, tr, i);
    }
}

proof fn lemma_invariant_holds_at<S>(
    init: spec_fn(S) -> bool,
    next: spec_fn(S, S) -> bool,
    inv: spec_fn(S) -> bool,
    tr: Seq<S>,
    i: int,
)
    requires
        is_behavior(init, next, tr),
        forall|s: S| init(s) ==> #[trigger] inv(s),
        forall|s: S, s_: S| inv(s) && #[trigger] next(s, s_) ==> inv(s_),
        0 <= i < tr.len(),
    ensures
        inv(tr[i]),
    decreases i,
{
    if i > 0 {
        let j = i - 1;
        lemma_invariant_holds_at(init, next, inv, tr, j);
        assert(next(tr[j], tr[j + 1]));
    }
}

} // verus!
