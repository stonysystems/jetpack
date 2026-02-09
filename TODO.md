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

## Priority 1 (High): TLA+ Specifications

- [x] Docker environment for TLA+ model checking (`tla/Dockerfile`, `tla/run-tlc.sh`)
- [x] Separate `tla/jetpack_raft.tla` into `tla/raft.tla` and `tla/jetpack.tla`
  - `raft.tla`: standalone Raft protocol
  - `jetpack.tla`: Jetpack plugin layer, runs with any compatible base protocol
- [x] Create `tla/copilot.tla`: CoPilot consensus protocol
- [x] Create `tla/mencius.tla`: Mencius consensus protocol
- [x] Create wrapper/composition modules (`jetpack_copilot.tla`, `jetpack_mencius.tla`)
  - `jetpack_copilot.tla`: Jetpack + CoPilot composition (SANY verified)
  - `jetpack_mencius.tla`: Jetpack + Mencius composition (SANY verified)

## Priority 1 (High): TLA+ Verification (via Docker)

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
<!-- "composed jetpack + X" means running jetpack.tla together with X.tla as the base
     protocol (e.g. via a wrapper module). This is NOT the same as jetpack_raft.tla,
     which is the original monolithic spec. The same applies to copilot and mencius. -->
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
- [ ] Review existing MongoDB integration (`src/deptran/mongodb/`)
- [ ] Verify/fix Jetpack calling MongoDB API for read/write commands
- [ ] Use async MongoDB API where available, sync API otherwise

#### Failure Recovery
- [ ] MongoDB hooker: detect when new MongoDB leader finishes recovery/election,
      write a signal file with the new term/view_id for Jetpack to read
- [ ] Jetpack hooker: monitor signal from MongoDB, trigger Jetpack failure recovery
      when MongoDB view change is detected

#### Testing (in Docker)
- [ ] Docker environment for MongoDB integration testing (create Dockerfile if needed)
- [ ] Single-process test: basic read/write through Jetpack + MongoDB
- [ ] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
- [ ] Failure recovery test: run normal procedure, kill MongoDB leader, let MongoDB
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      MongoDB and Jetpack

#### Documentation
- [ ] Write integration notes for anything interesting/noteworthy/suitable for the paper

### 2b. Jetpack + etcd (higher priority within this section)

Existing integration code: `src/deptran/etcd/`, `src/deptran/etcd_*.h`

#### Integration (without failure recovery)
- [x] Set up `third_party/` folder and clone etcd source
  - `third_party/etcd-cpp-apiv3` (v0.2.14): C++ client for etcd v3 API
  - `third_party/build_etcd.sh`: Build script
- [x] Review existing etcd integration (`src/deptran/etcd/`)
  - 11 files: frame, coordinator, server, commo, service, kv_handler, thread_pool
  - Integration is functionally complete for basic read/write path
  - Uses etcd-cpp-apiv3 with dual async (pplx) / sync API support
  - Failure recovery via file-based signaling (`jm_file_signal.h`)
  - Issues: hardcoded URIs, no server.cc, AWS-specific connection counts
  - Detailed review: `doc/etcd_integration_review.md`
- [x] Verify/fix Jetpack calling etcd API for read/write commands
  - Verified all etcd-cpp-apiv3 API calls (put/get/rmdir) match library signatures
  - Verified SimpleRWCommand parsing correctly extracts key/value from TPC commands
  - Verified async (pplx) and sync (std::thread) paths both signal completion correctly
  - Fixed: etcd URI now built from config hosts in recovery mode (was hardcoded)
  - Read results intentionally discarded (etcd serves as ordering/AB layer, not data store)
- [x] Use async etcd API where available, sync API otherwise
  - Already implemented: compile-time `JANUS_ETCD_HAS_PPLX` auto-detection via `__has_include`
  - Async path uses `pplx::task` with `.then()` continuations
  - Sync fallback uses `std::thread(...).detach()` per request

#### Failure Recovery
- [x] etcd hooker: detect when new etcd leader finishes recovery/election,
      write a signal file with the new term/view_id for Jetpack to read
  - Created `EtcdLeaderWatcher` (`src/deptran/etcd_leader_watcher.h`)
  - Watches `JetPack/leader` key in etcd for PUT events (leader changes)
  - Async path: uses `etcd::Watcher` callback API (when pplx available)
  - Sync fallback: polls key every 100ms via `etcd::SyncClient`
  - On leader change: calls `jm_signal::set_key("etcd", "primary_elected", host)`
  - Integrated into `KillEtcdPrimary()` in `s_main.cc` (non-simulation path)
- [x] Jetpack hooker: monitor signal from etcd, trigger Jetpack failure recovery
      when etcd view change is detected
  - Already implemented in `EtcdServer::Setup()` (`src/deptran/etcd/server.h`)
  - Non-leader replicas run coroutine polling for `etcd:primary_elected` signal
  - On signal: calls `JetpackRecoveryEntry()` to run 3-phase Paxos recovery

#### Testing (in Docker)
- [x] Docker environment for etcd integration testing (create Dockerfile if needed)
  - `docker/etcd/Dockerfile`: Multi-stage build (Ubuntu 22.04, Python 3.10 for WAF compatibility)
    - Stage 1: Builds etcd-cpp-apiv3 + Jetpack from source
    - Stage 2: Runtime image with etcd v3.5.17 server binary + Jetpack binaries
  - `docker/etcd/docker-compose.yml`: Orchestration for external etcd + Jetpack testing
  - `docker/etcd/run-etcd-test.sh`: Entrypoint script with modes: single, etcd-only, bash
  - `docker/etcd/test-etcd-setup.sh`: Infrastructure validation test (39 checks)
  - Uses existing config: `config/1c1s3r1p.yml` + `config/none_etcd.yml` + `config/rw_fixed.yml`
- [x] Single-process test: basic read/write through Jetpack + etcd
  - Implemented in `run-etcd-test.sh single` mode
  - Starts embedded etcd, verifies etcd R/W, launches 3 server replicas + 1 client
  - Uses `rw_fixed.yml` benchmark (100% writes to etcd via JetPack/KVTable/ prefix)
  - Validates: process exit codes, etcd key count, throughput in logs, no crashes
  - Servers start before client (1s stagger) for proper initialization
- [x] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
  - Implemented in `run-etcd-test.sh multi` mode
  - Config: `config/5c1s5r1p_etcd.yml` — 5 servers on separate loopback IPs (127.0.0.1-5)
  - Launches 5 server replicas + 5 clients with 2s stagger
  - Network latency via `tc`/`netem` on loopback (per-IP filtering, default 5ms +/- 2ms)
  - Configurable via `LATENCY_MS` and `LATENCY_JITTER` environment variables
  - Dockerfile updated with `iproute2` for `tc` support (requires `--privileged` or `NET_ADMIN`)
  - Validates: process exit codes, etcd key count, throughput, crash detection
  - Infrastructure validation: 53 checks pass (test-etcd-setup.sh)
- [x] Failure recovery test: run normal procedure, kill etcd leader, let etcd
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      etcd and Jetpack
  - Implemented in `run-etcd-test.sh recovery` mode
  - Creates 3-node etcd cluster on separate loopback IPs (127.0.0.1-3)
  - Config: `config/failover_etcd.yml` (run 5s, then soft-kill leader, wait 10s)
  - Jetpack uses `JETPACK_ETCD_RECOVERY` build flag to enable real recovery path
  - Recovery sequence: kill etcd primary → EtcdLeaderWatcher detects new leader →
    signals via jm_file_signal → EtcdServer recovery coroutine triggers
    JetpackRecoveryEntry() → 3-phase Paxos recovery
  - Validates: failover triggered, Jetpack recovery completed, recovery duration,
    etcd cluster survival (2/3 healthy), signal files created, no crashes
  - Helper functions: `start_etcd_cluster()`, `get_etcd_leader_ip()`,
    `kill_etcd_node()`, `wait_etcd_new_leader()`
  - Infrastructure validation: 68 checks pass (test-etcd-setup.sh)

#### Documentation
- [ ] Write integration notes for anything interesting/noteworthy/suitable for the paper

### 2c. Jetpack + ZooKeeper

No existing integration code. Needs to be implemented from scratch.

#### Integration (without failure recovery)
- [ ] Set up `third_party/` folder and clone ZooKeeper source
- [ ] Create `src/deptran/zookeeper/` integration module (frame, coordinator, server, commo, service)
- [ ] Implement Jetpack calling ZooKeeper API for read/write commands
- [ ] Use async ZooKeeper API where available, sync API otherwise

#### Failure Recovery
- [ ] ZooKeeper hooker: detect when new ZooKeeper leader finishes recovery/election,
      write a signal file with the new epoch/view_id for Jetpack to read
- [ ] Jetpack hooker: monitor signal from ZooKeeper, trigger Jetpack failure recovery
      when ZooKeeper view change is detected

#### Testing (in Docker)
- [ ] Docker environment for ZooKeeper integration testing (create Dockerfile if needed)
- [ ] Single-process test: basic read/write through Jetpack + ZooKeeper
- [ ] Multi-process test: 5 servers, 5 processes, simulated network latency between servers
- [ ] Failure recovery test: run normal procedure, kill ZooKeeper leader, let ZooKeeper
      leader-elect and trigger Jetpack leader-elect, measure recovery duration of both
      ZooKeeper and Jetpack

#### Documentation
- [ ] Write integration notes for anything interesting/noteworthy/suitable for the paper
