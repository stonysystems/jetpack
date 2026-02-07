# TODO

<!-- NOTE: doc/TODO.md is obsolete and must be ignored. Do NOT read or reference it. -->

## Goal

Jetpack is a plugin consensus protocol that sits on top of a base protocol (e.g. Raft,
CoPilot, Mencius). The TLA+ specifications should reflect this modular architecture:
each base protocol is a standalone, independently verifiable spec, and the Jetpack
plugin layer assumes certain base protocol properties without embedding base protocol
variables or transitions. The original combined spec `jetpack_raft.tla` is preserved
as reference but the separated specs are the primary artifacts going forward.

All TLA+ related work (specifications, configs, Docker environment) lives in the `tla/` folder.
All TLA+ model checking runs in Docker (`tla/Dockerfile`).

## TLA+ Specifications

- [x] Docker environment for TLA+ model checking (`tla/Dockerfile`, `tla/run-tlc.sh`)
- [x] Separate `tla/jetpack_raft.tla` into `tla/raft.tla` and `tla/jetpack.tla`
  - `raft.tla`: standalone Raft protocol
  - `jetpack.tla`: Jetpack plugin layer, runs with any compatible base protocol
- [x] Create `tla/copilot.tla`: CoPilot consensus protocol
- [x] Create `tla/mencius.tla`: Mencius consensus protocol
- [ ] Create wrapper/composition modules (e.g. `jetpack_copilot.tla`, `jetpack_mencius.tla`)

## TLA+ Verification (via Docker)

- [ ] `raft.tla`: TLC model check (CommittedLogAgreement, ElectionSafety)
- [ ] `copilot.tla`: TLC model check (CommittedLogAgreement, ActiveProposerBound)
- [ ] `mencius.tla`: TLC model check (SlotAgreement)
- [ ] `jetpack.tla`: SANY parse check (not standalone, needs base protocol to run)
- [ ] `jetpack_raft.tla`: SANY parse check (original combined spec preserved)
- [ ] TLC verification of composed jetpack + raft
- [ ] TLC verification of composed jetpack + copilot
- [ ] TLC verification of composed jetpack + mencius
