//! The model of Jetpack the pseudocode (definitions only, trusted). `types.rs`: constants, views, ballots,
//! entries, messages; `replica.rs`: a Jetpack replica with its co-located coordinator (the pseudocode §0,
//! §1 N12-N24, §2 L4-L54); `client.rs`: a fast-path client (N1-N10); `system.rs`: the whole
//! system, the original protocol's oracle (T1-T2, N11, N19-N20, A1-A3), `Init`, `Next`;
//! `properties.rs`: the properties `top.rs` states.
pub mod types;
pub mod replica;
pub mod client;
pub mod system;
pub mod properties;
