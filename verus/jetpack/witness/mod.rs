//! Reachability witnesses over the model (not trusted): concrete valid behaviors of a
//! configuration of three replicas and one client. `steps.rs`: the building blocks (the state
//! after each kind of step and the lemma that it is a `Next` step). `w_fast.rs` (W1): a command
//! is fast-committed in v_0. `w_recovery.rs` (W2): W1 continued by a new view and a full
//! recovery that commits a Recovered entry holding the command.
pub mod steps;
pub mod w_fast;
pub mod w_recovery;
