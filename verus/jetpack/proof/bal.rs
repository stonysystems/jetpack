//! The lexicographic order on ballots (view, k) (not trusted).
use crate::model::types::*;
use vstd::prelude::*;

verus! {

pub proof fn lemma_bal_lt_trans(a: Bal, b: Bal, c: Bal)
    requires
        bal_lt(a, b),
        bal_lt(b, c),
    ensures
        bal_lt(a, c),
{
}

pub proof fn lemma_bal_le_trans(a: Bal, b: Bal, c: Bal)
    requires
        bal_le(a, b),
        bal_le(b, c),
    ensures
        bal_le(a, c),
{
}

pub proof fn lemma_bal_lt_le_trans(a: Bal, b: Bal, c: Bal)
    requires
        bal_lt(a, b),
        bal_le(b, c),
    ensures
        bal_lt(a, c),
{
}

pub proof fn lemma_bal_le_lt_trans(a: Bal, b: Bal, c: Bal)
    requires
        bal_le(a, b),
        bal_lt(b, c),
    ensures
        bal_lt(a, c),
{
}

/// Trichotomy.
pub proof fn lemma_bal_total(a: Bal, b: Bal)
    ensures
        bal_lt(a, b) || a == b || bal_lt(b, a),
{
}

/// Antisymmetry: not both a < b and b <= a.
pub proof fn lemma_bal_asym(a: Bal, b: Bal)
    requires
        bal_lt(a, b),
    ensures
        !bal_le(b, a),
{
}

} // verus!
