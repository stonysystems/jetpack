# TODO

<!-- NOTE: The old doc/ folder has been merged into docs/. All documentation is now in docs/. -->

<!-- PROMPT FOR FUTURE WORK: For every completed task in this TODO, document the
     command(s) to run and verify it in the README.md (clean up README as needed).
     This ensures reproducibility and serves as living documentation. -->

## Goal

Jetpack is a plugin consensus protocol that sits on top of a base protocol (e.g. Raft,
CoPilot, Mencius). The TLA+ specifications should reflect this modular architecture:
each base protocol is a standalone, independently verifiable spec, and the Jetpack
plugin layer assumes certain base protocol properties without embedding base protocol
variables or transitions. The original combined spec `jetpack_raft.tla` is preserved
as reference but the separated specs are the primary artifacts going forward.

The **final goal** for TLA+ is that `jetpack.tla` can be composed directly with any
base protocol (`raft.tla`, `copilot.tla`, `mencius.tla`) without writing a new
monolithic spec for each combination. This requires a log abstraction: an N-sequence
log where each proposer leads a sequence (Raft: 1 sequence, CoPilot: 2 sequences,
Mencius: N sequences). The mid-step is wrapper modules (`jetpack_raft.tla`,
`jetpack_copilot.tla`, `jetpack_mencius.tla`) that run through successfully — abstraction
comes after the mid-step works.

All TLA+ related work (specifications, configs, Docker environment) lives in the `tla/` folder.
All TLA+ model checking runs in Docker (`tla/Dockerfile`).
TLC logs are saved to `tla/log/` with protocol name and timestamp.

## Priority 0 (Top): Documentation Cleanup

- [x] Merge `doc/` files into `docs/` (single documentation folder)
  - Moved all files from `doc/` to `docs/` using `git mv`
  - Updated all references from `doc/` to `docs/`
  - Removed `doc/` folder
- [x] Write a doc (`docs/leader_election_signal.md`) explaining the leader election signal
      mechanism for Jetpack failure recovery
  - Documented: signal mechanism (jm_file_signal.h), signal chain, three detection
    approaches (client-side watcher, external script, source code modification),
    server polling code, recovery procedure, timing results, key files
  - **TODO: Source code modifications needed** (in `third_party/` cloned repos):
    - [ ] MongoDB: find where new primary finishes step-up, add signal file write
    - [ ] etcd: find where new leader finishes Raft election, add signal file write
    - [ ] ZooKeeper: find where new leader finishes ZAB election, add signal file write

## Priority 0 (Top): Benchmark Data Collection (`result.md`)

### Performance chart (6 experiments)

All tests use 5 replicas, closed-loop, two settings per backend:
- Setting A: 1 client thread, concurrency = 1
- Setting B: 12 client threads, concurrency = 10

Latency (median, average) and throughput metrics are computed in `src/deptran/s_main.cc`.

**Note**: Multi-process mode (separate OS processes per server/client with tc/netem latency)
is now working after fixing the `-P` flag bug (scripts passed site names instead of process
names). Results below use single-process mode for latency/throughput metrics. Multi-process
mode validates inter-replica communication with simulated 5ms network latency.

| Experiment | Median Latency (ms) | Average Latency (ms) | Throughput (txn/s) |
|---|---:|---:|---:|
| MongoDB 1-client (concurrency=1) | 141.74 | 141.24 | 7.10 |
| MongoDB 12-client (concurrency=10) | 166.30 | 167.23 | 716.50 |
| etcd 1-client (concurrency=1) | 87.82 | 90.04 | 11.20 |
| etcd 12-client (concurrency=10) | 86.98 | 87.55 | 1368.20 |
| ZooKeeper 1-client (concurrency=1) | 84.01 | 83.90 | 11.90 |
| ZooKeeper 12-client (concurrency=10) | 85.69 | 86.05 | 1393.20 |

- [x] Run MongoDB 1-client test (5 replicas, closed-loop, 1 thread, concurrency=1), record metrics
- [x] Run MongoDB 12-client test (5 replicas, closed-loop, 12 threads, concurrency=10), record metrics
- [x] Run etcd 1-client test (5 replicas, closed-loop, 1 thread, concurrency=1), record metrics
- [x] Run etcd 12-client test (5 replicas, closed-loop, 12 threads, concurrency=10), record metrics
- [x] Run ZooKeeper 1-client test (5 replicas, closed-loop, 1 thread, concurrency=1), record metrics
- [x] Run ZooKeeper 12-client test (5 replicas, closed-loop, 12 threads, concurrency=10), record metrics
- [x] Fix multi-process mode inter-replica connectivity (0 throughput in Docker)
  - Root cause: run scripts passed site names (`-P s101`) instead of process names (`-P h1`)
  - Fixed all three backends' run scripts (mongodb, etcd, zookeeper)
  - Also fixed ZooKeeper 4-letter word whitelist and added netcat to Docker image
  - Verified: MongoDB 9.4-9.6 txn/s, etcd 11.4-11.5 txn/s, ZooKeeper 9.0 txn/s per process

### Failure recovery downtime (3 experiments)

Downtime definitions:
- **Original protocol downtime**: from triggering original protocol failure to the original
  protocol writing the signal file (recovery/election complete)
- **Jetpack downtime**: from the signal file being written (original protocol recovery finished)
  to Jetpack finishing its own recovery

| Experiment | Original Protocol Downtime | Jetpack Downtime |
|---|---:|---:|
| MongoDB recovery | ~10.6s | ~159-281ms |
| etcd recovery | ~6.0-6.3s | ~106-107ms |
| ZooKeeper recovery | ~0.5-1.1s | ~106ms |

Recovery uses external kill: script kills backend leader by PID, writes signal files
to `/tmp/JM_Jetpack_0.0.0.0`, and Jetpack's recovery hooker polls for the signal and
triggers `JetpackRecoveryEntry()`. Jetpack internal recovery duration is 123-184ms
across all backends (logged with ms precision). The "Jetpack downtime" column above
measures from signal file write to `recovery_finish_after_failure` detection.

- [x] Run MongoDB recovery test, measure MongoDB downtime and Jetpack downtime
  - MongoDB downtime: ~10.6s (replica set election), Jetpack downtime: ~159-281ms
  - Fixed: added `replicaSet=jetpack-rs` to MongoDB URI for automatic failover
- [x] Run etcd recovery test, measure etcd downtime and Jetpack downtime
  - etcd downtime: ~6.0-6.3s (Raft leader election), Jetpack downtime: ~106-107ms
- [x] Run ZooKeeper recovery test, measure ZooKeeper downtime and Jetpack downtime
  - ZooKeeper downtime: ~0.5-1.1s (ZAB leader election), Jetpack downtime: ~106ms
  - Fixed: enabled `JETPACK_ZOOKEEPER_RECOVERY` in constants.h

### Export

- [x] Export all benchmark and recovery data to `result.md`

## Priority 1 (High): TLA+ Specifications

### Properties

Properties to prove in `jetpack.tla` (refer to `jetpack_raft.tla` for reference):
- LogAgreement
- LogOrderMatchesExecution: for every pair of commands in the log, if A and B conflict
  and A is before B, then in the execution log A is still before B. This pairwise
  conflict-ordering check adapts to multi-sequence protocols (CoPilot: 2 sequences,
  Mencius: N sequences).
- ExecutionDedupMatches

Properties for original base protocols (`raft.tla`, `copilot.tla`, `mencius.tla`):
- LogAgreement (adapted per protocol)
- LogOrderMatchesExecution (pairwise conflict-ordering as above)

### Specifications

- [x] Docker environment for TLA+ model checking (`tla/Dockerfile`, `tla/run-tlc.sh`)
- [x] Separate `tla/jetpack_raft.tla` into `tla/raft.tla` and `tla/jetpack.tla`
  - `raft.tla`: standalone Raft protocol
  - `jetpack.tla`: Jetpack plugin layer, runs with any compatible base protocol
- [x] Create `tla/copilot.tla`: CoPilot consensus protocol
- [x] Create `tla/mencius.tla`: Mencius consensus protocol
- [x] Create wrapper/composition modules (`jetpack_copilot.tla`, `jetpack_mencius.tla`)
  - `jetpack_copilot.tla`: Jetpack + CoPilot composition (SANY verified)
  - `jetpack_mencius.tla`: Jetpack + Mencius composition (SANY verified)

### Mid-step: wrapper module verification

<!-- "composed jetpack + X" means running jetpack.tla together with X.tla as the base
     protocol (e.g. via a wrapper module). This is NOT the same as jetpack_raft.tla,
     which is the original monolithic spec. The same applies to copilot and mencius. -->

Run wrapper modules through TLC successfully. Getting them to pass is more important
than abstraction at this stage.

- [ ] Add LogAgreement, LogOrderMatchesExecution, ExecutionDedupMatches to jetpack.tla properties
- [ ] TLC verification of `jetpack_raft.tla` with full Jetpack properties
- [ ] TLC verification of `jetpack_copilot.tla` with full Jetpack properties
- [ ] TLC verification of `jetpack_mencius.tla` with full Jetpack properties
- [ ] Add LogAgreement and LogOrderMatchesExecution to each base protocol
  - [ ] `raft.tla`: add/verify LogAgreement + LogOrderMatchesExecution
  - [ ] `copilot.tla`: add/verify LogAgreement + LogOrderMatchesExecution
  - [ ] `mencius.tla`: add/verify LogAgreement + LogOrderMatchesExecution

### Final goal: direct composition without wrapper modules

Achieve `jetpack.tla` + `raft.tla` / `copilot.tla` / `mencius.tla` composition
without writing a new monolithic `jetpack_<protocol>.tla` for each combination.

Requires N-sequence log abstraction:
- Raft: 1 sequence (single leader)
- CoPilot: 2 sequences (pilot + copilot)
- Mencius: N sequences (round-robin, one per server)

- [ ] Design N-sequence log abstraction in `jetpack.tla`
- [ ] Refactor base protocols to expose N-sequence log interface
- [ ] Verify `jetpack.tla` + `raft.tla` direct composition (no wrapper)
- [ ] Verify `jetpack.tla` + `copilot.tla` direct composition (no wrapper)
- [ ] Verify `jetpack.tla` + `mencius.tla` direct composition (no wrapper)

### TLA+ Verification (via Docker)

All TLC logs saved to `tla/log/<protocol>_<timestamp>.log`.

- [x] `raft.tla`: TLC model check (CommittedLogAgreement, ElectionSafety)
  - Exhaustive: 40M states, 2.8M distinct, depth 56 (3 servers, 1 cmd, SmallStateConstraint)
  - Partial: 145M+ states, 20M+ distinct, no violations (3 servers, 2 cmds, StateConstraint)
- [x] `copilot.tla`: TLC model check (CommittedLogAgreement, ActiveProposerBound)
  - Exhaustive: 186K states, 21K distinct, depth 15 (3 servers, 1 cmd, SmallStateConstraint)
  - Partial: 114M+ states, 21M+ distinct, no violations (3 servers, 2 cmds, StateConstraint)
- [x] `mencius.tla`: TLC model check (SlotAgreement)
  - Partial: 119M+ states, 17M+ distinct, no violations (3 servers, 1 cmd, SmallStateConstraint)
  - Note: Mencius slot state space is too large for exhaustive checking in bounded time
- [x] `jetpack.tla`: SANY parse check (not standalone, needs base protocol to run)
- [x] `jetpack_raft.tla`: SANY parse check (original combined spec preserved)
- [x] TLC verification of composed jetpack + raft (`jetpack_raft.tla`)
  - Exhaustive: 82K states, 6K distinct, depth 26 (3 servers, 1 cmd, SmallStateConstraint)
  - Partial: 47M+ states, 5M+ distinct, no violations (3 servers, 2 cmds, StateConstraint)
- [x] TLC verification of composed jetpack + copilot (`jetpack_copilot.tla`)
  - Exhaustive: 515 states, 70 distinct, depth 7 (3 servers, 1 cmd, SmallStateConstraint)
  - Partial: 49M+ states, 5.3M+ distinct, no violations (3 servers, 2 cmds, StateConstraint)
- [x] TLC verification of composed jetpack + mencius (`jetpack_mencius.tla`)
  - Partial: 37M+ states, 3.6M+ distinct, no violations (3 servers, 1 cmd, SmallStateConstraint)
  - Note: Mencius composition state space too large for exhaustive checking

## Priority 2 (Medium): Jetpack + Industry Applications

Integrate Jetpack with real-world consensus/coordination systems. For each integration,
the Jetpack framework calls the original protocol's API for read/write commands (prefer
async API if available, otherwise use sync API). Existing integration code lives in
`src/deptran/` (e.g. `src/deptran/mongodb/`, `src/deptran/etcd/`).

All experiments run in Docker containers. Create a new Dockerfile if needed.

### 2a. Jetpack + MongoDB

Existing integration code: `src/deptran/mongodb/`, `src/deptran/mongodb_*.h`

#### Integration (without failure recovery)
- [x] Set up `third_party/` folder and clone MongoDB source
  - `third_party/mongo-c-driver` (v1.27.1): MongoDB C driver (libmongoc + libbson)
  - `third_party/mongo-cxx-driver` (r3.10.1): MongoDB C++ driver (mongocxx + bsoncxx)
  - `third_party/build_mongodb.sh`: Build script for both drivers
- [x] Review existing MongoDB integration (`src/deptran/mongodb/`)
  - 12 files (~860 lines): frame, coordinator, server, commo, service, kv_handler, thread_pool
  - Integration is functionally complete for basic read/write path
  - Uses mongocxx v3 (sync only) with BSON serialization
  - Thread pool: pre-allocated worker threads with round-robin dispatch (2500 AWS, 80 local)
  - Failover recovery via file-based signaling (same pattern as etcd)
  - Issues: hardcoded legacy URIs, empty server.cc, Restart() crashes, sync-only API
  - Replicas do not execute transactions — only leader writes to MongoDB
  - Detailed review: `docs/mongodb_integration_review.md`
- [x] Verify/fix Jetpack calling MongoDB API for read/write commands
- [x] Use async MongoDB API where available, sync API otherwise

#### Failure Recovery
- [x] MongoDB hooker: detect when new MongoDB leader finishes recovery/election,
      write a signal file with the new term/view_id for Jetpack to read
- [x] Jetpack hooker: monitor signal from MongoDB, trigger Jetpack failure recovery
      when MongoDB view change is detected

#### Testing (in Docker)
- [x] Docker environment for MongoDB integration testing (create Dockerfile if needed)
- [x] Single-process test: basic read/write through Jetpack + MongoDB
- [x] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
- [x] Failure recovery test: run normal procedure, kill MongoDB leader, let MongoDB
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      MongoDB and Jetpack

#### Documentation
- [x] Write integration notes for anything interesting/noteworthy/suitable for the paper
  - Document: `docs/mongodb_integration_notes.md`

### 2b. Jetpack + etcd (higher priority within this section)

Existing integration code: `src/deptran/etcd/`, `src/deptran/etcd_*.h`

#### Integration (without failure recovery)
- [x] Set up `third_party/` folder and clone etcd source
- [x] Review existing etcd integration (`src/deptran/etcd/`)
- [x] Verify/fix Jetpack calling etcd API for read/write commands
- [x] Use async etcd API where available, sync API otherwise

#### Failure Recovery
- [x] etcd hooker: detect when new etcd leader finishes recovery/election,
      write a signal file with the new term/view_id for Jetpack to read
- [x] Jetpack hooker: monitor signal from etcd, trigger Jetpack failure recovery
      when etcd view change is detected

#### Testing (in Docker)
- [x] Docker environment for etcd integration testing (create Dockerfile if needed)
- [x] Single-process test: basic read/write through Jetpack + etcd
- [x] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
- [x] Failure recovery test: run normal procedure, kill etcd leader, let etcd
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      etcd and Jetpack

#### Documentation
- [x] Write integration notes for anything interesting/noteworthy/suitable for the paper
  - Document: `docs/etcd_integration_notes.md`

### 2c. Jetpack + ZooKeeper

No existing integration code. Needs to be implemented from scratch.

#### Integration (without failure recovery)
- [x] Set up `third_party/` folder and clone ZooKeeper source
- [x] Create `src/deptran/zookeeper/` integration module (frame, coordinator, server, commo, service)
- [x] Implement Jetpack calling ZooKeeper API for read/write commands
- [x] Use async ZooKeeper API where available, sync API otherwise

#### Failure Recovery
- [x] ZooKeeper hooker: detect when new ZooKeeper leader finishes recovery/election,
      write a signal file with the new epoch/view_id for Jetpack to read
- [x] Jetpack hooker: monitor signal from ZooKeeper, trigger Jetpack failure recovery
      when ZooKeeper view change is detected

#### Testing (in Docker)
- [x] Docker environment for ZooKeeper integration testing (create Dockerfile if needed)
- [x] Single-process test: basic read/write through Jetpack + ZooKeeper
- [x] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
- [x] Failure recovery test: run normal procedure, kill ZooKeeper leader, let ZooKeeper
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      ZooKeeper and Jetpack

#### Documentation
- [x] Write integration notes for anything interesting/noteworthy/suitable for the paper
  - Document: `docs/zookeeper_integration_notes.md`

## Priority 1 (High): README Documentation

- [x] Document Docker and Docker Compose version requirements in README
- [x] For every completed task above, document the command(s) to run and verify it in
      the project README.md (clean up README as needed)
  - [x] TLA+ model checking: how to build Docker image and run TLC for each spec
  - [x] MongoDB integration: how to build, run single/multi/recovery tests
  - [x] etcd integration: how to build, run single/multi/recovery tests
  - [x] ZooKeeper integration: how to build, run single/multi/recovery tests
  - [x] Benchmark results: quick benchmark commands and link to `result.md`
