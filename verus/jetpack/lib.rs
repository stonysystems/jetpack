//! jetpack: the Jetpack consensus shim, three-phase recovery, as written in
//! `docs/pseudocode.md` (the pseudocode §0 notation, §1 normal path N1-N25, §2 recovery T1-T2,
//! L1-L54). Verify with
//!     ~/verus/verus --crate-type=lib verus/jetpack/lib.rs
//! (needs ~/.cargo/bin on PATH). Files: `README.md`; line map: `FIDELITY.md`; judgement calls
//! and status: `PROGRESS.md`.
//!
//! - `model/`: the model (definitions only, trusted);
//! - `proof/`: the inductive invariant and its preservation (not trusted);
//! - `top.rs`: the theorems the crate states (trusted).
#![allow(unused_imports)]
#![allow(non_snake_case)]
use vstd::prelude::*;

#[path = "../common/mod.rs"]
pub mod common;

pub mod model;
pub mod proof;
pub mod witness;
pub mod top;

verus! {
} // verus!
