//! Shared by every zoo protocol. Each protocol crate root pulls this in with
//! `#[path = "../common/mod.rs"] pub mod common;`, so a protocol verifies on its
//! own and a half-written neighbour cannot break it.
pub mod quorum;
pub mod trace;
