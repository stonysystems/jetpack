# TODO

## Priority 1: TLA+ Specification Separation and Extension

- [ ] Separate `tla/jetpack_raft.tla` into `tla/raft.tla` and `tla/jetpack.tla`
  - `raft.tla`: standalone Raft protocol, independently model-checkable
  - `jetpack.tla`: Jetpack plugin layer, runs with any compatible base protocol
- [ ] Create `tla/copilot.tla`: CoPilot consensus protocol (standalone + Jetpack-compatible)
- [ ] Create `tla/mencius.tla`: Mencius consensus protocol (standalone + Jetpack-compatible)
- [ ] Docker environment for TLA+ model checking
- [ ] Verify all specs pass TLC model checking
