# TODO

Phased roadmap for Jetpack development. Each phase has concrete tasks with acceptance criteria.

## Session Outcomes

- **Phase 1 (CURP)**: Complete implementation. Works at c1 with 1 RTT; known throughput issue at c50+.
- **Phase 2 (SwiftPaxos)**: **Real implementation with inter-replica ack exchange** (commit `8f136dd8`). Latency 42ms (1 RTT). Max CPU 99% on leader (was 88.6% simplified), all replicas busy 80-99%.
- **Phase 3 (EPaxos)**: **Real implementation with PreAccept/Commit broadcast** (commit `c167dc84`). Latency 41ms (1 RTT). Max CPU 82.8% (was 56.7% simplified), all replicas now do per-command work.
- **Phase 4 (Benchmark)**: Latency + throughput sweeps complete for 10 of 12 protocol configurations.

**Updated CPU at peak (60 clients c500):**

| Protocol | Max CPU | All-replica CPU | vs Simplified |
|---|---|---|---|
| Jetpack+Raft fp100 | 97.9% | varied | (unchanged, was already real) |
| Jetpack+Raft adaptive | 100% | varied | (unchanged, was already real) |
| SwiftPaxos | **99%** | 80-99% | was 88.6% (synthesized acks) |
| EPaxos | **82.8%** | 29-83% | was 56.7% (no broadcast) |
| Raft | 83.8% | 5-84% | (unchanged) |

SwiftPaxos and EPaxos now do actual distributed consensus work on all replicas per command.

**Scope reduction**: Failure recovery for SwiftPaxos (2.5) and EPaxos (3.5) is **not required**. SwiftPaxos batching (2.6) is **not required**. The recovery stubs that exist in the codebase are harmless no-ops and can be left in place.

Documentation produced:
- `docs/curp_vs_raft_vs_jetpack_experiment.md` — CURP results
- `docs/full_protocol_latency_2026-04-16.md` — Latency benchmarks
- `docs/full_protocol_throughput_2026-04-16.md` — Throughput benchmarks
- `docs/consensus_protocol_comparison_2026-04-16.md` — Consolidated comparison

## Open / Unsolved Items

### Recently completed (2026-04-16 follow-up)

- **Precise max-throughput bisection** — **Done** (commit `4d25d67f` infra + results in `docs/max_throughput_bisection_2026-04-16.md`). Peak ordering: EPaxos 19991 @ N100 > Raft 13984 @ N70 > SwiftPaxos 11968 @ N60 > Jetpack+Raft fp100 8998 @ N45 > Jetpack+Raft adaptive 7993 @ N40.
- **etcd backend benchmarked** — **Done** (`scripts/start_etcd_cluster.sh` spins up 5-node etcd cluster). c1 p50=83ms @ 3.8 cmd/s/host; c50 total 1478 cmd/s similar to Raft. etcd works end-to-end with the existing `none_etcd.yml` config.
- **CoPilot `verify(ins)` crash at c500 (OnAccept/OnFastAccept)** — **Fixed**. Late-arriving Accept for a freed slot now returns a valid reply instead of aborting. Matches the existing nullptr handling in OnPrepare/OnCommit.
- **client_worker.cc `verify(!coo->_inuse_)` race** — **Fixed**. `_inuse_ = false` now happens before `free_coordinators_.push_back(coo)` so a concurrent FindOrCreateCoordinator doesn't see a still-in-use coordinator.
- **CURP leader-skip optimization** — **Applied**. CURP spec RPC now skips the Raft leader (leader already has the cmd in its log via the slow-path dispatch, so a spec RPC is redundant and doubles leader load). CURP at c1 still works; c50+ still has a throughput ceiling tied to the leader's single pinned core but is no longer as pathological.

### Known bugs still open

1. **CURP throughput at c50+ is lower than Raft** (was 234→592 cmd/s at c=150; leader-skip helped but the fast-path speculative broadcast still competes with Raft dispatch on the leader's pinned core). To fully fix, the fast-path work would need to move off the pinned server core.
2. **CoPilot `munmap_chunk(): invalid pointer` at c500** — heap corruption on zoo0 during shutdown. Happens after the experiment completes (mid-10s measurement done), so doesn't invalidate throughput numbers, but crashes the process. Not fixed — requires a deeper investigation of the CoPilot coroutine lifecycle.
3. **Jetpack+CoPilot adaptive fails at c150+** — pre-existing.
4. **Mencius and Jetpack+Mencius fail at higher concurrency** — pre-existing scalability limit.

### Not tested (infrastructure blocker only)

- **ZooKeeper backend** (`none_zookeeper.yml`) — requires ZK daemon on each host. ZK source is in `third_party/zookeeper/` but not built as a runtime binary; java is only installed on zoo1/3/4, not zoo0/2. Setting this up is a one-time ops task (download tarball, install on all 5 hosts, configure zoo.cfg ensemble).

### Potential future work (not on current roadmap)

- Push EPaxos past N100 — it didn't hit the 99% stop in the current sweep (peak 19991 @ 98.99%). N=120 or 140 likely reveals its true ceiling.
- Implement EPaxos slow path (Accept phase when replicas disagree on deps).
- Implement SwiftPaxos hash-based conflict detection.
- Client-side dispatch rewrite to remove the ~200 cmd/s per-client cap (all protocols below saturation are client-limited, so true protocol ceilings are a lower bound).
- Contention workloads (Zipf, small key ranges) to stress the fast path's conflict handling.

## Status Summary (2026-04-16)

| Phase | Status | Commit(s) | Notes |
|---|---|---|---|
| 1.0-1.5 CURP | **Done** | `8644411b`, `a2a04030` | `-m 200` works at c1 (40.63ms 1 RTT) |
| 1.6 CURP comparative exp | **Partial** | `a2a04030` | Latency works; throughput has known bug at conc >= 50 |
| 2.0-2.1 SwiftPaxos scaffold + RPC | **Done** | `2ae8cc01` | Directory created, RPC stubs generated |
| 2.2-2.4 SwiftPaxos server + coordinator | **Done** | `2f3b0981`, `8f136dd8` | Full impl with inter-replica ack exchange: 42ms p50, 99% CPU, 12001 cmd/s |
| 2.5 SwiftPaxos recovery | **Dropped** | `0e470abb` | Not needed. Stubs remain in codebase as harmless no-ops |
| 2.6 SwiftPaxos batching | **Dropped** | | Not needed |
| 3.0-3.3 EPaxos (corrected) scaffold + server | **Done** | `95d3549a`, `c167dc84` | Full impl with PreAccept/Commit broadcast: 41ms p50, 82.8% CPU, 11992 cmd/s |
| 3.4 EPaxos Tarjan SCC execution | **Done** | `76b3fba5` | Verified: 5138 cmd/s local test, commands execute in dependency order |
| 3.5 EPaxos recovery | **Dropped** | `c4da883b` | Not needed. Stubs remain in codebase as harmless no-ops |
| 4.0 CPU monitor for all builds | **Done** | `dca242e4` | Removed `#ifdef AWS` guard |
| 4.1-4.3 Latency experiment (8 protocols) | **Done** | `1449a7db` | Results in `docs/full_protocol_latency_2026-04-16.md` |
| 4.4 Throughput sweep | **Done** | `89d53a58` | Coarse + bisect complete for 5 scalable protocols |
| 4.5 Full benchmark document | **Done** | `89d53a58` | See `docs/full_protocol_throughput_2026-04-16.md` |

**Latency at c1 (zoo cluster):**

| Protocol | p50 (ms) | Type |
|---|---|---|
| Raft | 79.59 | 2 RTT |
| Jetpack+Raft fp100 | 40.64 | 1 RTT ✓ |
| Jetpack+Raft adaptive | 40.59 | 1 RTT ✓ |
| CURP | 40.63 (intermittent, was N/A in 2026-04-16 run) | 1 RTT (known throughput bug) |
| SwiftPaxos | 40.51 | 1 RTT ✓ |
| EPaxos (corrected) | 40.42 | 1 RTT ✓ |
| CoPilot | 102.18 | 2+ RTT |
| Jetpack+CoPilot adaptive | 40.71 | 1 RTT ✓ |
| Mencius | 122.63 | 3 RTT (rotating leader) |
| Jetpack+Mencius adaptive | 40.70 | 1 RTT ✓ |

**Peak throughput across all tested concurrencies (c50, c150, c200, c300, c500):**

| Protocol | Peak (cmd/s) | @ conc | p50 at peak | Server CPU avg across 5 hosts |
|---|---|---|---|---|
| Raft | 5989.6 | c500 | 75.89 | 29.1% |
| Jetpack+Raft fp100 | 6004.3 | c300 | 42.03 | 54.6% |
| Jetpack+Raft adaptive | 6002.6 | c300 | 41.96 | 50.6% |
| SwiftPaxos | 6012.1 | c500 | 41.39 | 31.4% |
| EPaxos | 5996.1 | c300 | 41.23 | 16.6% |
| CoPilot | 4463.6 | c150 | 103.25 | 85.7% (fails at c500) |
| Jetpack+CoPilot adaptive | 1480.7 | c50 | 41.56 | 44.6% (fails at c150) |
| Mencius | 216.6 | c50 | low | 100% (fails at c150) |
| Jetpack+Mencius adaptive | fails at c50+ | — | — | — |
| CURP | n/a | — | — | Known bug at c50+ |

All 5 scalable protocols hit the same ~6000 cmd/s ceiling at c200 **because of a client-side bottleneck**. Each client worker caps at ~200 cmd/s. 30 clients × 200 = 6000. **Confirmed by running with 60 clients → throughput doubles to ~12000 cmd/s for all protocols.**

**True protocol peaks (60 clients at c500, with SwiftPaxos/EPaxos real impl):**

| Protocol | Tput (cmd/s) | Max CPU | p50 |
|---|---|---|---|
| Raft | 12006 | 83.8% | 84ms |
| Jetpack+Raft fp100 | 11996 | 97.9% | 42.85ms |
| Jetpack+Raft adaptive | 11975 | **100%** (saturated) | 44.61ms |
| SwiftPaxos | 12001 | **99%** | 42.09ms |
| EPaxos | 11992 | 82.8% | 41.43ms |

At 60 clients, **Jetpack+Raft adaptive and SwiftPaxos both hit CPU saturation** (100%/99%). All protocols now reflect real distributed consensus work. Jetpack's fast-path latency benefit is preserved at scale (42ms vs Raft's 84ms). See `docs/full_protocol_throughput_2026-04-16.md` for full analysis.

**Known issues:**
- CURP throughput collapses at conc >= 50 (p50 jumps to 1000+ms)
- Jetpack+CoPilot adaptive fails at conc >= 150
- Plain CoPilot fails at conc = 500

---

## Phase 1: CURP Integration (reuse Jetpack infrastructure, no recovery)

**Goal**: Implement CURP as a mode variant (`-m 200`) of the existing Jetpack+Raft path. CURP reuses the same coordinator, RPC, config system, and command pool as Jetpack — the only behavioral difference is how the **leader** checks for conflicts (Raft log instead of command pool) and that there is **no failure recovery**.

**Constraints**:
- `-m 200` (CURP mode) is only valid when `ab: raft`. CURP depends on scanning the Raft log on the leader, which doesn't apply to CoPilot, Mencius, MongoDB, etcd, or ZooKeeper.
- `-m 200` always attempts the fast path (100% attempt rate). No adaptive throttle, no probabilistic gating. This matches the CURP paper where the fast path is always attempted.
- No recovery: fast-path commands that haven't been committed by Raft are lost on leader failure.

**Design — how CURP differs from Jetpack on the fast path**:

```
                         Jetpack+Raft (-m 100)           CURP (-m 200)
Leader conflict check:   command_pool_.push_back(cmd)    scan uncommitted Raft log for key conflict
Non-leader check:        command_pool_.push_back(cmd)    command_pool_.push_back(cmd)  (same)
Fast-path attempt rate:  100% (fp100) or adaptive (101)  100% always (hardcoded)
Recovery on failure:     8-step Paxos recovery            none (fast-path cmds may be lost)
Coordinator:             CoordinatorRule                  CoordinatorRule  (same)
RPC:                     RuleSpeculativeExecute           RuleSpeculativeExecute  (same)
Config:                  rule_raft.yml -m 100             rule_raft.yml -m 200
```

**Rationale for leader checking the log**: In CURP, the leader is the orderer — it has the canonical total order in its Raft log. Checking uncommitted log entries for key conflicts is more accurate than the command pool, because the log reflects the true serialization order. Non-leaders (witnesses) don't have the full uncommitted log, so they use the command pool as a local approximation — same as Jetpack.

**Mode flag summary after this phase**:

| `-m` | Name | Fast-path rate | Leader conflict check | Recovery | Protocol restriction |
|---|---|---|---|---|---|
| `0` | Original | 0% (no fast path) | N/A | N/A | Any |
| `100` | Jetpack+Raft fp100 | 100% | Command pool | Paxos recovery | Any |
| `101` | Jetpack+Raft adaptive | Adaptive (throttled) | Command pool | Paxos recovery | Any |
| `200` | CURP | 100% (hardcoded) | Raft log (uncommitted) | None | Raft only |

### 1.0 Add CURP mode constant and validation

**Files to modify:**
- `src/deptran/constants.h` — add:
  ```cpp
  #define CURP_MODE 200  // CURP: leader checks log, witnesses check command pool, no recovery
  ```
- `src/deptran/config.cc` (or wherever `-m` is parsed) — add validation:
  ```cpp
  if (jetpack_fastpath_attempt_rate_ == CURP_MODE) {
    verify(replica_proto_ == MODE_RAFT);  // CURP only works with Raft
  }
  ```

**Acceptance criteria:**
- [ ] `-m 200` with `rule_raft.yml` is accepted
- [ ] `-m 200` with `rule_copilot.yml` or any non-Raft protocol aborts with a clear error

### 1.1 Coordinator — 100% fast path, no throttle

**Files to modify:**
- `src/deptran/rule/coordinator.cc` — in `GotoNextPhase()`, add CURP branch at the top of the `INIT_END` case (before the existing throttle logic):
  ```cpp
  if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ == CURP_MODE) {
    go_to_fastpath_ = true;  // CURP: always attempt fast path, no throttle
  } else if (...existing Jetpack logic...) {
    ...
  }
  ```

**What this skips**: All the adaptive throttle logic (lines 71-128 of `rule/coordinator.cc`): the one-armed bandit, queue-depth ramp, CPU-based Mencius gating. CURP always goes fast path.

**Acceptance criteria:**
- [ ] With `-m 200`, every request attempts the fast path (verify via `Fastpath statistics attempted N successed M` where N = total requests)

### 1.2 Server — leader checks Raft log, non-leader checks command pool

**Files to modify:**
- `src/deptran/scheduler.h` — add method declaration:
  ```cpp
  bool ConflictWithUncommittedRaftLog(const shared_ptr<Marshallable>& cmd);
  ```
- `src/deptran/scheduler.cc` — in `OnRuleSpeculativeExecute()` (around line 520), add CURP branch:
  ```cpp
  if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ == CURP_MODE && is_leader) {
    // CURP leader: check Raft log for conflicts (not command pool)
    bool no_conflict = !rep_sched_->ConflictWithUncommittedRaftLog(cmd);
    *accepted = no_conflict;
    // Do NOT insert into command pool — leader doesn't need it for CURP
  } else {
    // Jetpack path (all replicas) or CURP non-leader (witness):
    // Check command pool as usual
    bool no_conflict = rep_sched_->command_pool_.push_back(cmd);
    *accepted = no_conflict;
  }
  ```
- `src/deptran/scheduler.cc` — implement `ConflictWithUncommittedRaftLog()`:
  ```cpp
  bool TxLogServer::ConflictWithUncommittedRaftLog(const shared_ptr<Marshallable>& cmd) {
    auto key = SimpleRWCommand::GetKey(cmd);
    auto* raft_svr = dynamic_cast<RaftServer*>(rep_sched_);
    // Scan uncommitted entries: commitIndex+1 to lastLogIndex
    for (uint64_t i = raft_svr->commitIndex + 1; i <= raft_svr->lastLogIndex; i++) {
      auto instance = raft_svr->GetRaftInstance(i);
      if (instance && instance->log_) {
        auto log_key = SimpleRWCommand::GetKey(instance->log_);
        if (log_key == key) return true;  // conflict found
      }
    }
    return false;  // no conflict
  }
  ```

**Key detail**: The leader does NOT insert commands into the command pool. The leader's conflict check is purely against the Raft log. Only non-leaders (witnesses) use the command pool.

**Reference**: The existing `command_pool_.push_back()` is at `scheduler.cc:522-527`. The Raft log access pattern follows `raft/server.cc:480-520` where instances are iterated for commit processing.

**Acceptance criteria:**
- [ ] Leader returns `accepted=true` when no uncommitted Raft entry has the same key
- [ ] Leader returns `accepted=false` when an uncommitted Raft entry conflicts
- [ ] Non-leader behavior is unchanged from Jetpack (command pool check)

### 1.3 Skip recovery for CURP mode

**Files to modify:**
- `src/deptran/s_main.cc` — in the section that launches the `JetpackRecoveryLoop` thread, add guard:
  ```cpp
  if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ != CURP_MODE) {
    // Launch Jetpack recovery thread (not needed for CURP)
    ...
  }
  ```
- `src/deptran/raft/coordinator.cc` — in `Submit()`, skip the Jetpack recovery status check for CURP:
  ```cpp
  if (!is_recovery_cmd
      && Config::GetConfig()->jetpack_fastpath_attempt_rate_ != CURP_MODE
      && svr_->jetpack_status_ == TxLogServer::JetpackStatus::RECOVERY) {
    // Reject — Jetpack recovery in progress (not applicable for CURP)
    ...
  }
  ```

**Acceptance criteria:**
- [ ] No `JetpackRecoveryLoop` thread is spawned when `-m 200`
- [ ] Leader election in Raft does NOT trigger Jetpack recovery when `-m 200`

### 1.4 Command pool GC for CURP non-leaders

**Design**: Non-leaders (witnesses) still use the command pool, so it needs garbage collection when Raft commits. The leader doesn't use the command pool so no GC needed there. The existing `RuleCommandPoolGC()` path already handles this — it calls `command_pool_.remove(cmd)` after Raft commit. For CURP, this path should only run on non-leaders.

**Files to modify:**
- `src/deptran/raft/server.cc` — at the `RuleCommandPoolGC(cmd)` call site (line ~514), add CURP guard:
  ```cpp
  if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ == CURP_MODE) {
    if (!IsLeader()) {
      RuleCommandPoolGC(next_instance->log_);  // non-leader: GC command pool
    }
    // leader: no command pool to clean
  } else {
    RuleCommandPoolGC(next_instance->log_);  // Jetpack: all replicas GC
  }
  ```

**Acceptance criteria:**
- [ ] Non-leader command pools are garbage collected after Raft commit
- [ ] Leader has empty command pool throughout the run
- [ ] No unbounded memory growth during sustained experiments

### 1.5 Config file and experiment integration

**Files to create:**
- `config/none_curp.yml`:
  ```yaml
  mode:
    cc: rule
    ab: raft
    batch: false
    retry: 20
    ongoing: 1
  ```
  (Identical to `rule_raft.yml`. The CURP behavior is activated by `-m 200`, not a separate config.)

**Files to modify:**
- `scripts/experiment_defs.sh` — add CURP to mode definitions:
  ```bash
  MODE_CURP="200"  # CURP: 100% fast path, leader checks log, no recovery
  ```
  Add `CURP_CONCS` array (same as `RAFT_CONCS` initially) and update `concs_array_for()`.

**Acceptance criteria:**
- [ ] `./scripts/run_single_exp.sh none_curp.yml 200 concurrent_1.yml curp-c1 ../results/curp-test` runs on the zoo cluster
- [ ] Results show 1 RTT latency (~40ms p50) for non-conflicting workloads (`rw_1000000`)

### 1.6 Comparative experiment — CURP vs Raft vs Jetpack+Raft

**Goal**: Run the same SwiftPaxos-style benchmark suite from `docs/raft_jetpack_swiftpaxos_experiment.md` with CURP added as a third protocol.

**Protocols to compare:**

| Label | Config | `-m` | Fast-path behavior |
|---|---|---|---|
| Raft (baseline) | `none_raft.yml` | `0` | No fast path (2 RTT) |
| CURP | `none_curp.yml` | `200` | Leader checks log, witnesses check pool (1 RTT) |
| Jetpack+Raft fp100 | `rule_raft.yml` | `100` | All replicas check pool (1 RTT) |
| Jetpack+Raft adaptive | `rule_raft.yml` | `101` | Adaptive throttle (1 RTT when attempted) |

**Experiments:**
1. **Latency** at `concurrent_1` — expect CURP and Jetpack both ~40ms (1 RTT)
2. **Max throughput** via adaptive concurrency sweep — expect similar ceiling (~6000 cmd/s on current cluster)
3. **Contention sweep** (Zipf 0.5-1.0) — CURP may behave differently under contention because the leader checks the log (ordered) rather than the command pool (unordered)
4. **Key range sweep** (1 to 1M) — show fast-path degradation as conflict rate increases

**Acceptance criteria:**
- [ ] Results documented in `docs/curp_vs_raft_vs_jetpack_experiment.md`
- [ ] CURP latency at low load matches Jetpack+Raft (~40ms p50, 1 RTT)
- [ ] CURP throughput at saturation is comparable to Raft and Jetpack+Raft
- [ ] CPU usage data collected per server per experiment point

### Summary of Phase 1 deliverables

| Task | Files modified | Lines changed (est.) |
|---|---|---|
| 1.0 Mode constant + validation | `constants.h`, `config.cc` | ~5 |
| 1.1 Coordinator — 100% fast path | `rule/coordinator.cc` | ~5 |
| 1.2 Server — leader log check | `scheduler.h`, `scheduler.cc` | ~25 |
| 1.3 Skip recovery | `s_main.cc`, `raft/coordinator.cc` | ~5 |
| 1.4 GC for non-leaders | `raft/server.cc` | ~5 |
| 1.5 Config + experiment integration | `config/none_curp.yml` (new), `experiment_defs.sh` | ~10 |
| 1.6 Experiments | `docs/curp_vs_raft_vs_jetpack_experiment.md` (new) | — |

**Total**: ~55 lines of logic changes + 1 new config file + 1 new results doc. No new source directories. CURP reuses the entire Jetpack+Raft code path with minimal branching.

---

## Phase 2: SwiftPaxos Integration

**Goal**: Implement SwiftPaxos (NSDI '24) as a new protocol (`ab: swiftpaxos`) in the Janus codebase. SwiftPaxos is a leaderless state-machine replication protocol that achieves 1 RTT (2 message delays) in the best case and 2 RTT (3 message delays) otherwise. Unlike CURP/Jetpack which layer a fast path on top of a leader-based protocol, SwiftPaxos is a standalone consensus protocol with its own ordering and recovery mechanism.

**Reference implementation**: https://github.com/imdea-software/swiftpaxos (Go, ~3000 lines core protocol)

**Key SwiftPaxos concepts**:
- **Leader-optimized leaderless protocol**: A designated leader assigns sequence numbers for ordering, but any replica can propose. The leader accelerates the fast path but is not required for correctness.
- **Fast quorum (FQ)**: 3N/4 replicas (e.g., 4 of 5). If FQ agrees with matching dependency hashes → commit in 1 RTT.
- **Slow quorum (SQ)**: N/2+1 majority. Fallback when dependencies conflict.
- **Per-key dependency tracking**: Each replica tracks per-key conflict info. A command's dependencies are the last conflicting commands on each key it touches.
- **Hash-based agreement**: Instead of comparing full dependency sets (EPaxos-style), replicas compare per-key hash digests. Matching hashes prove identical dependency sets without transmitting them.
- **Phases**: START → PRE_ACCEPT → ACCEPT → COMMIT. Fast path skips ACCEPT (1 RTT). Slow path goes through ACCEPT (2 RTT).

**Architecture decision**: SwiftPaxos is a fundamentally different protocol from Raft — it has its own ordering, dependency tracking, and recovery. It cannot reuse the Jetpack plugin layer or Raft infrastructure. It needs its own `src/deptran/swiftpaxos/` directory with dedicated frame, server, coordinator, commo, and service classes.

### 2.0 Scaffolding — register SwiftPaxos as a new protocol

**Files to create/modify:**
- `src/deptran/constants.h` — add `#define MODE_SWIFTPAXOS (0x8000)`
- `src/deptran/frame.cc` — add `{"swiftpaxos", MODE_SWIFTPAXOS}` to protocol name map
- `wscript` — add `src/deptran/swiftpaxos/*.cc` to the build
- `config/none_swiftpaxos.yml`:
  ```yaml
  mode:
    cc: none
    ab: swiftpaxos
    batch: false
    retry: 20
    ongoing: 1
  ```

**New directory `src/deptran/swiftpaxos/`:**
- `frame.h/cc` — `SwiftPaxosFrame : public Frame`
- `server.h/cc` — `SwiftPaxosServer : public TxLogServer` (main replica logic)
- `coordinator.h/cc` — `SwiftPaxosCoordinator : public Coordinator` (client-side)
- `commo.h/cc` — `SwiftPaxosCommo : public Communicator` (RPC broadcast)
- `service.h/cc` — `SwiftPaxosServiceImpl : public Service` (RPC handlers)

**Acceptance criteria:**
- [ ] `build/deptran_server -f config/none_swiftpaxos.yml ...` compiles and starts (no protocol logic yet)
- [ ] Frame resolves `"swiftpaxos"` → `MODE_SWIFTPAXOS` → `SwiftPaxosFrame`

### 2.1 RPC definitions — protocol messages

Define the SwiftPaxos-specific RPCs. These are new messages not shared with Raft or Jetpack.

**File to modify:** `src/deptran/rcc_rpc.rpc` — add new RPCs:

| RPC | Direction | Fields | Purpose |
|---|---|---|---|
| `SwiftFastAck` | Replica→All | `replica, ballot, cmd_id, dep[], checksum[], seqnum` | Fast path ACK with dependency set + hash |
| `SwiftLightSlowAck` | Replica→All | `replica, ballot, cmd_id` | Slow path ACK (minimal) |
| `SwiftNewLeader` | Replica→All | `replica, ballot` | Leader election |
| `SwiftNewLeaderAck` | Replica→Leader | `replica, ballot, cballot, cmd_ids[], phases[], cmds[], deps[]` | Recovery: report command state |
| `SwiftSync` | Leader→All | `replica, ballot, phases{}, cmds{}, deps{}` | Recovery: sync state |

**Reference**: See `/tmp/swiftpaxos/swift/defs.go` lines 53-170 for Go definitions.

**Acceptance criteria:**
- [ ] `bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc` generates stubs for all new RPCs
- [ ] Service can register handlers for all SwiftPaxos RPCs

### 2.2 Core data structures — command descriptors, quorums, hash logs

**Files to create/modify in `src/deptran/swiftpaxos/`:**

**Command descriptor** (per-command state machine):
```cpp
struct SwiftCmdDesc {
  enum Phase { START, PRE_ACCEPT, ACCEPT, COMMIT };
  Phase phase = START;
  shared_ptr<Marshallable> cmd;
  vector<CommandId> dep;          // dependency set
  vector<SHash> checksums;        // per-key hash digests
  bool slow_path = false;
  // Fast path: collects FQ matching acks
  // Slow path: collects SQ acks
};
```

**Per-key conflict tracker** (equivalent to Go `keyInfo`):
```cpp
struct KeyConflictInfo {
  // Track last write and last command per key
  // getConflictCmds(cmd) → returns commands that conflict with cmd
  unordered_map<uint64_t, shared_ptr<Marshallable>> last_writes;
};
```

**Hash log** (per-key, proves conflict-freedom):
```cpp
class HashLog {
  // Append(cmd, cmd_id) → returns current hash
  // Update(cmd_id, seqnum, hash) → advance stable point
  // Used to compare dependency sets without transmitting them
  SHash current_hash;
  int synced_seqnum = 0;
};
```

**Quorum system**:
```cpp
int FastQuorum(int n) { return 3 * n / 4 + 1; }  // FQ: 3/4 of replicas (4 of 5)
int SlowQuorum(int n) { return n / 2 + 1; }       // SQ: majority (3 of 5)
```

**Reference**: See `/tmp/swiftpaxos/swift/swift.go` lines 17-98 for Go structs, `/tmp/swiftpaxos/swift/key.go` for conflict tracking, `/tmp/swiftpaxos/swift/dpath.go` for hash logs.

**Acceptance criteria:**
- [ ] All data structures compile
- [ ] Hash computation produces deterministic results for same input

### 2.3 Server — proposal handling and fast/slow path logic

The core protocol logic. When a replica receives a proposal:

**Fast path flow (1 RTT)**:
1. Compute dependencies via per-key conflict tracking (`getConflictCmds`)
2. Compute per-key hash digest
3. If replica is in FQ: send `SwiftFastAck{dep, checksum, seqnum}` to all
4. Leader includes sequence number (`seqnum++`); non-leaders set `seqnum=0`
5. Collect FQ fast acks. Accept condition: `dep == leaderDep AND checksum == leaderChecksum`
6. If FQ matches → phase = COMMIT, deliver command

**Slow path flow (2 RTT)**:
1. Dependencies conflict (hashes differ between replicas)
2. Replica sends `SwiftLightSlowAck` instead of/in addition to fast ack
3. Wait for SQ (majority) to agree
4. Phase = ACCEPT → COMMIT with agreed dependencies

**Files to implement in `src/deptran/swiftpaxos/server.cc`:**
- `HandlePropose(cmd)` — entry point, compute deps, broadcast fast ack
- `HandleFastAck(msg)` — collect into FQ message set, check hash match
- `HandleLightSlowAck(msg)` — collect into SQ message set
- `FastAckFromLeader(msg)` — special handling for leader's ack (has seqnum)
- `Deliver(cmd_id)` — apply to state machine after commit
- `GetDepAndHashes(cmd)` — per-key dependency computation + hash

**Reference**: See `/tmp/swiftpaxos/swift/swift.go` lines 280-522 for the Go implementation.

**Acceptance criteria:**
- [ ] Non-conflicting commands commit in 1 RTT (fast path)
- [ ] Conflicting commands commit in 2 RTT (slow path)
- [ ] Dependency tracking is per-key and correct

### 2.4 Coordinator — client-side fast/slow path tracking

The client (coordinator) tracks both FQ and SQ message sets per command:

**Logic:**
1. Send `Propose(cmd)` to all replicas
2. Collect `SwiftFastAck` messages into `fastPathH` (FQ-sized message set)
3. Collect `SwiftLightSlowAck` messages into `slowPathH` (SQ-sized message set)
4. **Fast path commit**: FQ reached AND leader ack received AND all hashes match
5. **Slow path commit**: SQ reached (hashes may differ)
6. Return to client on whichever completes first

**Files to implement in `src/deptran/swiftpaxos/coordinator.cc`:**
- `Submit(cmd)` — broadcast propose, init FQ/SQ message sets
- `HandleFastAck(msg)` — add to fastPathH, check FQ threshold + hash match
- `HandleSlowAck(msg)` — add to slowPathH, check SQ threshold

**Reference**: See `/tmp/swiftpaxos/swift/client.go` lines 70-241.

**Acceptance criteria:**
- [ ] Client commits on FQ fast path when hashes match
- [ ] Client falls back to SQ slow path when hashes differ
- [ ] Latency metrics distinguish fast vs slow path commits

### 2.5 Recovery — leader election and state sync [DROPPED]

**Status**: Dropped — failure recovery for SwiftPaxos is not required for our scope. The RPC handler stubs remain in the codebase as harmless no-ops (commit `0e470abb`). The detailed design below is preserved for historical reference.

When a leader fails, the new leader runs recovery:

**Phase 1 — New leader election:**
- Increment ballot, broadcast `SwiftNewLeader{ballot}`
- All replicas enter RECOVERING status, stop normal processing

**Phase 2 — Collect state:**
- Each replica responds with `SwiftNewLeaderAck{cballot, cmd_ids[], phases[], cmds[], deps[]}`
- Reports all commands it knows about and their phases

**Phase 3 — Merge and sync:**
- New leader collects majority of acks
- Find highest `cballot` group → these commands are authoritative
- Merge: committed/accepted commands from highest cballot group win
- Broadcast `SwiftSync{phases, cmds, deps}` to all replicas

**Phase 4 — Apply sync:**
- Each replica applies synced state
- Topological sort by dependencies (deliver deps before dependents)
- Resume normal operation with new ballot

**Files to implement in `src/deptran/swiftpaxos/recovery.cc`:**
- `HandleNewLeader(msg)` — enter recovery, report state
- `HandleNewLeaderAck(msg)` — collect majority, merge state
- `HandleSync(msg)` — apply synced state, resume

**Reference**: See `/tmp/swiftpaxos/swift/recovery.go` lines 1-312.

**Acceptance criteria:**
- [ ] After leader kill, new leader recovers all committed commands
- [ ] No committed command is lost during recovery
- [ ] Recovery completes and replicas resume normal processing

### 2.6 Message batching (optimization) [DROPPED]

**Status**: Dropped — not required for our scope. The detailed design below is preserved for historical reference.

SwiftPaxos batches multiple acks into single messages to reduce network overhead:

- `MOptAcks`: combines multiple fast acks from the same replica into one message
- `MAcks`: combines fast + slow acks

**Reference**: See `/tmp/swiftpaxos/swift/batcher.go`.

This is an optimization that can be deferred — implement basic unbatched protocol first, then add batching for throughput.

**Acceptance criteria:**
- [ ] Batching reduces message count at high throughput
- [ ] No correctness change vs unbatched version

### 2.7 Config and experiment integration

**Files to create/modify:**
- `config/none_swiftpaxos.yml` — (created in 2.0)
- `config/30c1s5r5p-zoo.yml` or new topology for SwiftPaxos (may need quorum config)
- `scripts/experiment_defs.sh` — add `SWIFTPAXOS_CONCS` array

**Quorum configuration**: SwiftPaxos needs FQ and SQ defined. For 5 replicas: FQ=4, SQ=3. This may need a config file or command-line flag.

**Acceptance criteria:**
- [ ] SwiftPaxos runs on the zoo cluster with 5 replicas
- [ ] `run_single_exp.sh` works with `none_swiftpaxos.yml`

### 2.8 Comparative experiment — SwiftPaxos vs Raft vs CURP vs Jetpack+Raft

**Protocols to compare:**

| Protocol | Type | Fast path | Recovery | Leader required? |
|---|---|---|---|---|
| Raft | Leader-based | None (2 RTT) | Log-based | Yes |
| CURP | Leader-based + fast path | 1 RTT (witnesses) | None (Phase 1) | Yes |
| Jetpack+Raft | Plugin fast path on Raft | 1 RTT (command pool) | Paxos-based | Yes |
| SwiftPaxos | Leaderless with leader optimization | 1 RTT (hash agreement) | State-merge | Optional (improves perf) |

**Experiments:**
1. **Latency** at low load — all fast-path protocols should achieve ~40ms (1 RTT)
2. **Max throughput** — SwiftPaxos may differ since it's leaderless (less leader bottleneck)
3. **Contention sweep** — SwiftPaxos hash-based conflict detection vs Jetpack's command pool
4. **Failure recovery** — SwiftPaxos state-merge vs Jetpack Paxos recovery
5. **Varying cluster size** (3, 5, 7 replicas) — FQ scaling (3/4 quorum gets expensive)

**Acceptance criteria:**
- [ ] Results documented in `docs/swiftpaxos_comparative_experiment.md`
- [ ] SwiftPaxos achieves 1 RTT latency for non-conflicting workloads
- [ ] Recovery works correctly after leader kill

### Summary of Phase 2 deliverables

| Task | New files | Estimated lines |
|---|---|---|
| 2.0 Scaffolding | 10 files in `src/deptran/swiftpaxos/`, config | ~200 (stubs) |
| 2.1 RPC definitions | `rcc_rpc.rpc` modifications | ~50 |
| 2.2 Data structures | `server.h` (structs, hash log, quorum) | ~200 |
| 2.3 Server protocol | `server.cc` (propose, fast/slow path, deliver) | ~500 |
| 2.4 Coordinator | `coordinator.cc` (client-side FQ/SQ tracking) | ~200 |
| 2.5 Recovery | `recovery.cc` (leader election, state merge, sync) | ~300 |
| 2.6 Batching | `batcher.cc` (optional optimization) | ~150 |
| 2.7 Config integration | config files, experiment_defs.sh | ~20 |
| 2.8 Experiments | results doc | — |

**Total**: ~1600 lines new code. This is a full protocol implementation, not a mode variant. Most complex task is 2.3 (server protocol logic) and 2.5 (recovery).

**Key implementation risks:**
- SwiftPaxos reference is in Go; translating to C++ requires adapting concurrent message handling (Go channels → C++ coroutines/events)
- The hash log mechanism is non-trivial and must be exactly correct for fast-path safety
- Recovery correctness requires careful testing (TLA+ verification is ideal but out of scope for this phase)

---

## Phase 3: EPaxos Integration (corrected version)

**Goal**: Implement the corrected EPaxos from the SwiftPaxos repo (`/tmp/swiftpaxos/epaxos/`) as a new protocol (`ab: epaxos`) in the Janus codebase. EPaxos is a leaderless consensus protocol where every replica can propose, commands carry explicit dependency sets, and execution uses topological sorting via Tarjan's SCC algorithm.

**Reference implementation**: https://github.com/imdea-software/swiftpaxos/tree/master/epaxos (Go, ~3000 lines). This is the corrected version that fixes several bugs in the original EPaxos paper (SOSP '13).

**Corrections from original EPaxos** (documented in the reference code):
1. Fixed N=3 case
2. Added `vbal` variable (the original TLA+ spec was wrong)
3. Removed short commits (for N>7, propagating committed dependencies is necessary)
4. Must run with thriftiness on (recovery is incorrect otherwise)
5. When conflicts are transitive, skip waiting for prior commuting commands

**Key EPaxos concepts**:
- **Leaderless**: Any replica can propose. No designated leader (unlike SwiftPaxos which has a leader for sequence numbers).
- **Instance space**: 2D array `InstanceSpace[replica][instance]`. Each replica has its own instance sequence.
- **Dependencies**: Each instance has `Deps[N]` — one dependency per replica, pointing to the highest instance from that replica this command conflicts with.
- **Sequence numbers** (`Seq`): Used for execution ordering within SCCs. Not a global total order — just a local ordering hint.
- **Three phases**: PreAccept (fast), Accept (slow), Commit.
- **Fast path**: If all F+⌊(F+1)/2⌋ PreAccept replies agree on same Seq/Deps AND all deps committed AND initial ballot → commit in 1 RTT.
- **Slow path**: If Seq/Deps disagree → merge deps, run Accept phase with majority, commit in 2 RTT.
- **Execution**: Tarjan's SCC algorithm on the dependency graph. Commands in the same SCC are sorted by (Seq, replica, proposeTime) and executed together.
- **Recovery**: Prepare → collect instance state from majority → TryPreAccept optimization → Accept → Commit.

**EPaxos vs SwiftPaxos comparison**:

| Aspect | EPaxos | SwiftPaxos |
|---|---|---|
| Leader | None (any replica proposes) | Designated leader (assigns seqnum) |
| Ordering | Dependency graph + SCC | Leader sequence number |
| Fast path quorum | F + ⌊(F+1)/2⌋ (smaller than SwiftPaxos FQ) | 3N/4 |
| Fast path condition | All replies same Seq/Deps + all deps committed | All hashes match leader |
| Conflict detection | Explicit per-key Deps[N] array | Hash-based per-key digest |
| Execution | Tarjan's SCC + topological sort | Sequential by seqnum |
| Recovery | Prepare/TryPreAccept (complex, 6 subcases) | NewLeader/Sync (state merge) |
| Message size | Larger (carries Deps[N] + Seq) | Smaller (carries hash only) |

### 3.0 Scaffolding — register EPaxos as a new protocol

**Files to create/modify:**
- `src/deptran/constants.h` — add `#define MODE_EPAXOS_CORRECTED (0x8001)` (distinct from the existing `MODE_EPAXOS (0x80)` if any legacy code exists)
- `src/deptran/frame.cc` — add `{"epaxos_corrected", MODE_EPAXOS_CORRECTED}` to protocol name map
- `wscript` — add `src/deptran/epaxos_corrected/*.cc` to the build
- `config/none_epaxos_corrected.yml`:
  ```yaml
  mode:
    cc: none
    ab: epaxos_corrected
    batch: false
    retry: 20
    ongoing: 1
  ```

**New directory `src/deptran/epaxos_corrected/`:**
- `frame.h/cc` — `EPaxosCFrame : public Frame`
- `server.h/cc` — `EPaxosCServer : public TxLogServer` (main replica + instance space)
- `coordinator.h/cc` — `EPaxosCCoordinator : public Coordinator` (client-side)
- `commo.h/cc` — `EPaxosCCommo : public Communicator` (RPC broadcast)
- `service.h/cc` — `EPaxosCServiceImpl : public Service` (RPC handlers)
- `exec.h/cc` — `EPaxosCExec` (Tarjan's SCC execution engine)

**Acceptance criteria:**
- [ ] `build/deptran_server -f config/none_epaxos_corrected.yml ...` compiles and starts
- [ ] Frame resolves `"epaxos_corrected"` → `MODE_EPAXOS_CORRECTED` → `EPaxosCFrame`

### 3.1 RPC definitions — EPaxos protocol messages

**File to modify:** `src/deptran/rcc_rpc.rpc`

| RPC | Direction | Key Fields | Purpose |
|---|---|---|---|
| `EPaxosPreAccept` | Leader→FQ | `leader, replica, instance, ballot, cmds[], seq, deps[N]` | Fast path round 1 |
| `EPaxosPreAcceptReply` | FQ→Leader | `replica, instance, ballot, vbal, seq, deps[N], committed_deps[N], status` | Reply with local deps |
| `EPaxosPreAcceptOK` | FQ→Leader | `instance` | Shortcut reply when deps unchanged |
| `EPaxosAccept` | Leader→SQ | `leader, replica, instance, ballot, seq, deps[N]` | Slow path round 2 |
| `EPaxosAcceptReply` | SQ→Leader | `replica, instance, ballot` | Accept acknowledgment |
| `EPaxosCommit` | Leader→All | `leader, replica, instance, ballot, cmds[], seq, deps[N]` | Final commit broadcast |
| `EPaxosPrepare` | Recoverer→All | `leader, replica, instance, ballot` | Recovery phase 1 |
| `EPaxosPrepareReply` | All→Recoverer | `acceptor, replica, instance, ballot, vbal, status, cmds[], seq, deps[N]` | Report instance state |
| `EPaxosTryPreAccept` | Recoverer→All | `leader, replica, instance, ballot, cmds[], seq, deps[N]` | Recovery optimization |
| `EPaxosTryPreAcceptReply` | All→Recoverer | `acceptor, replica, instance, ballot, vbal, conflict_replica, conflict_instance, conflict_status` | Conflict report |

**Reference**: See `/tmp/swiftpaxos/epaxos/defs.go` lines 13-101.

**Acceptance criteria:**
- [ ] All 10 RPCs generate stubs via rpcgen
- [ ] Service registers handlers for all EPaxos RPCs

### 3.2 Core data structures — instance space, dependencies, conflict tracking

**Instance** (the core per-command state):
```cpp
struct EPaxosInstance {
  enum Status { NONE, PREACCEPTED, PREACCEPTED_EQ, ACCEPTED, COMMITTED, EXECUTED };
  vector<shared_ptr<Marshallable>> cmds;  // batched commands
  int32_t ballot = 0, vbal = 0;          // ballot and validated ballot
  Status status = NONE;
  int32_t seq = 0;                        // sequence number for execution ordering
  vector<int32_t> deps;                   // deps[N]: one dependency per replica
  // Tarjan's SCC fields
  int index = -1, lowlink = -1;
  int64_t propose_time = 0;
};
```

**Instance space**: 2D array indexed by `[replica_id][instance_number]`.

**LeaderBookkeeping** (per-command leader state during consensus):
```cpp
struct EPaxosLeaderBookkeeping {
  int pre_accept_oks = 0;
  int accept_oks = 0;
  int nacks = 0;
  bool all_equal = true;                  // all PreAccept replies had same Seq/Deps
  vector<int32_t> original_deps;          // initial dependencies
  vector<int32_t> committed_deps;         // committed deps per replica
  // Recovery fields
  vector<PrepareReply*> prepare_replies;
  bool preparing = false;
  bool trying_to_pre_accept = false;
  vector<bool> possible_quorum;
  int tpa_reps = 0;
  bool tpa_accepted = false;
};
```

**Per-key conflict tracker**:
```cpp
struct InstPair {
  int32_t last;        // last instance touching this key
  int32_t last_write;  // last write instance touching this key
};
// conflicts[replica][key] → InstPair
vector<unordered_map<key_t, InstPair>> conflicts;  // one map per replica
unordered_map<key_t, int32_t> max_seq_per_key;     // global max seq per key
```

**Quorum sizes** (for N replicas, F = ⌊(N-1)/2⌋ failures tolerated):
```cpp
int FastQuorumSize() { return f_ + (f_ + 1) / 2; }  // e.g., N=5, F=2 → FQ=3
int SlowQuorumSize() { return (n_ + 1) / 2; }        // e.g., N=5 → SQ=3
```

**Reference**: See `/tmp/swiftpaxos/epaxos/epaxos.go` lines 42-132.

**Acceptance criteria:**
- [ ] Instance space supports 2D indexing by [replica][instance]
- [ ] Dependency arrays are N-element (one per replica)
- [ ] Conflict tracker correctly identifies per-key read-write conflicts

### 3.3 Server — PreAccept, Accept, Commit (core protocol)

**PreAccept phase (fast path, 1 RTT if all agree)**:

1. `StartPhase1(cmds)` — leader creates new instance, computes initial Seq/Deps via `UpdateAttributes()`, broadcasts `EPaxosPreAccept` to FastQuorumSize()-1 replicas
2. `HandlePreAccept(msg)` — non-leader computes its own Seq/Deps. If matches leader's → reply `PreAcceptOK`. If differs → reply `PreAcceptReply` with its Seq/Deps.
3. `HandlePreAcceptReply(msg)` — leader collects replies:
   - **Fast commit**: all FQ replies agree (allEqual) AND all deps committed AND initial ballot → broadcast `Commit`
   - **Slow path**: FQ replies collected but disagreement → merge Seq/Deps, go to Accept phase

**Accept phase (slow path, 2 RTT total)**:

4. `BroadcastAccept(instance)` — broadcast merged Seq/Deps to SlowQuorumSize() replicas
5. `HandleAccept(msg)` — replica accepts if ballot ≥ local ballot, replies `AcceptReply`
6. `HandleAcceptReply(msg)` — leader collects majority → broadcast `Commit`

**Commit phase**:

7. `BroadcastCommit(instance)` — broadcast final Cmds/Seq/Deps to all replicas
8. `HandleCommit(msg)` — replica updates instance to COMMITTED, updates conflict table

**Key helper functions:**
- `UpdateAttributes(cmds, replica, instance)` — computes Seq/Deps from conflict table
- `UpdateConflicts(cmds, replica, instance)` — updates conflict table after accept
- `MergeAttributes(seq, deps, reply_seq, reply_deps)` — merges Seq/Deps from multiple replies (take max)

**Reference**: See `/tmp/swiftpaxos/epaxos/epaxos.go` lines 460-1113.

**Acceptance criteria:**
- [ ] Non-conflicting commands commit in 1 RTT (all PreAccept replies agree)
- [ ] Conflicting commands go to Accept phase and commit in 2 RTT
- [ ] Seq/Deps merge correctly takes max of all proposals

### 3.4 Execution engine — Tarjan's SCC algorithm

**Purpose**: EPaxos does not have a global total order. Commands are partially ordered by their dependency graph. Execution requires finding strongly connected components (SCCs) in the graph and executing them in topological order.

**Algorithm**:
1. When a command is COMMITTED, attempt execution
2. `FindSCC(replica, instance)` — run Tarjan's algorithm from this instance
3. For each dependency, recursively check if COMMITTED
4. If all dependencies are COMMITTED → SCC is ready to execute
5. Sort instances within SCC by (Seq, replica_id, propose_time)
6. Execute commands in sorted order, mark EXECUTED

**Files to implement in `src/deptran/epaxos_corrected/exec.cc`:**
- `ExecuteCommand(replica, instance)` — entry point
- `FindSCC(replica, instance)` — Tarjan's SCC detection
- `StrongConnect(instance)` — recursive DFS with index/lowlink

**Reference**: See `/tmp/swiftpaxos/epaxos/exec.go` lines 25-172. Tarjan's algorithm uses Index/Lowlink fields on each instance and a DFS stack with WHITE/GRAY/BLACK coloring.

**Acceptance criteria:**
- [ ] Commutative commands in the same SCC are executed in deterministic order across all replicas
- [ ] Execution respects dependency ordering (no command executes before its dependencies)
- [ ] All replicas produce the same execution order for the same set of committed commands

### 3.5 Recovery — Prepare, TryPreAccept [DROPPED]

**Status**: Dropped — failure recovery for EPaxos is not required for our scope. The RPC handler stubs remain in the codebase as harmless no-ops (commit `c4da883b`). The detailed design below is preserved for historical reference.

**When triggered**: Execution thread detects an instance stuck in non-COMMITTED state for >10 seconds (COMMIT_GRACE_PERIOD).

**Recovery protocol** (6 subcases from corrected TLA+ spec):

1. `StartRecovery(replica, instance)` — increment ballot, broadcast `EPaxosPrepare` to all
2. `HandlePrepare(msg)` — return current instance state (status, ballot, vbal, cmds, seq, deps)
3. `HandlePrepareReply(msg)` — collect majority of replies, then:
   - **Case 1**: If any reply says COMMITTED → done (already committed)
   - **Case 2**: If any reply says ACCEPTED → broadcast Accept with that value
   - **Case 3**: If PREACCEPTED + slow quorum agrees + leader not responded + allEqual → broadcast Accept
   - **Case 4**: Same conditions → try TryPreAccept optimization
   - **Case 5**: PREACCEPTED but conditions not met → retry with higher ballot
   - **Case 6**: NONE (nobody has seen it) → propose as new command

4. `HandleTryPreAccept(msg)` — check for conflicts via `FindPreAcceptConflicts()`:
   - No conflict → accept with PREACCEPTED
   - Conflict found → return conflict info (replica, instance, status)
5. `HandleTryPreAcceptReply(msg)` — collect replies:
   - If found accepted instance elsewhere → abandon, restart recovery
   - If quorum with no conflicts → Accept
   - If quorum with conflicts → defer recovery (prevent cycles)

**Defer mechanism**: Prevents recovery cycles when two instances depend on each other. Uses a defer map to track which instance deferred to which.

**Reference**: See `/tmp/swiftpaxos/epaxos/epaxos.go` lines 1121-1506.

**Acceptance criteria:**
- [ ] Recovery successfully commits stuck instances
- [ ] No committed command is lost during recovery
- [ ] TryPreAccept correctly detects conflicts with existing instances
- [ ] Defer mechanism prevents infinite recovery loops

### 3.6 Command batching

EPaxos supports batching multiple client proposals into a single instance:

- `HandlePropose()` — when batching enabled, collect `batchSize` proposals from channel before starting Phase 1
- Each instance's `cmds` field is a vector (not a single command)
- Conflict detection checks all keys across all commands in the batch
- Dependency merging accounts for batch semantics

**Reference**: See `/tmp/swiftpaxos/epaxos/epaxos.go` lines 724-748.

**Acceptance criteria:**
- [ ] Batching improves throughput at high load
- [ ] Correctness unchanged (dependencies computed correctly for batches)

### 3.7 Config and experiment integration

**Files to create/modify:**
- `config/none_epaxos_corrected.yml` — (created in 3.0)
- `scripts/experiment_defs.sh` — add `EPAXOS_CORRECTED_CONCS` array

**Note**: EPaxos is leaderless — there is no "leader" to configure. Any replica can propose. The topology config just needs N replicas with clients distributed evenly.

**Acceptance criteria:**
- [ ] EPaxos runs on the zoo cluster with 5 replicas
- [ ] Any replica can accept proposals (not just a designated leader)

### 3.8 Comparative experiment — full protocol suite

**Protocols to compare:**

| Protocol | Type | Leader | Fast path | Slow path | Execution |
|---|---|---|---|---|---|
| Raft | Leader-based | Required | None (2 RTT) | N/A | Sequential by log |
| CURP | Leader + fast path | Required | 1 RTT (log check) | 2 RTT (Raft) | Sequential by log |
| Jetpack+Raft | Plugin fast path | Required | 1 RTT (command pool) | 2 RTT (Raft) | Sequential by log |
| SwiftPaxos | Leader-optimized | Optional | 1 RTT (hash match, FQ=3N/4) | 2 RTT | Sequential by seqnum |
| EPaxos | Leaderless | None | 1 RTT (deps agree, FQ=F+⌊(F+1)/2⌋) | 2 RTT (Accept) | SCC topological sort |

**Experiments:**
1. **Latency** at low load — EPaxos fast path should also achieve ~1 RTT
2. **Max throughput** — EPaxos leaderless may have higher ceiling (no leader bottleneck)
3. **Contention sweep** — EPaxos explicit dependency tracking vs SwiftPaxos hashes vs Jetpack command pool
4. **Recovery comparison** — EPaxos Prepare/TryPreAccept vs SwiftPaxos state-merge vs Jetpack Paxos
5. **Slow path rate** — measure what fraction of commands take slow path under varying contention
6. **Execution latency** — EPaxos SCC overhead vs sequential execution in other protocols

**Acceptance criteria:**
- [ ] Results documented in `docs/full_protocol_comparison.md`
- [ ] EPaxos achieves 1 RTT for non-conflicting workloads
- [ ] EPaxos correctly handles conflicting workloads via slow path
- [ ] Tarjan execution produces deterministic results across replicas

### Summary of Phase 3 deliverables

| Task | New files | Estimated lines |
|---|---|---|
| 3.0 Scaffolding | 12 files in `src/deptran/epaxos_corrected/`, config | ~200 (stubs) |
| 3.1 RPC definitions | `rcc_rpc.rpc` modifications | ~80 (10 RPCs) |
| 3.2 Data structures | `server.h` (instance, leader bookkeeping, conflicts) | ~250 |
| 3.3 Server protocol | `server.cc` (PreAccept, Accept, Commit, helpers) | ~600 |
| 3.4 Execution engine | `exec.cc` (Tarjan's SCC, topological sort) | ~200 |
| 3.5 Recovery | `server.cc` (Prepare, TryPreAccept, 6 subcases, defer) | ~400 |
| 3.6 Batching | `server.cc` (batch proposal handling) | ~50 |
| 3.7 Config integration | config files, experiment_defs.sh | ~20 |
| 3.8 Experiments | results doc | — |

**Total**: ~1800 lines new code. Comparable to SwiftPaxos (Phase 2) in complexity. Most complex parts are 3.5 (recovery with 6 subcases + TryPreAccept + defer mechanism) and 3.4 (Tarjan execution).

**Key implementation risks:**
- Recovery correctness is notoriously tricky in EPaxos — the original paper had bugs. Must faithfully port the corrected version's 6 subcases.
- Tarjan's SCC requires all dependency instances to be COMMITTED before executing. A stuck dependency triggers recovery, which can cascade.
- The `vbal` (validated ballot) is a correction to the original spec — must not be confused with the regular ballot.
- Go's concurrent channel model maps to C++ coroutines/events, requiring careful translation of the message-processing loop.

---

## Phase 4: Full Protocol Benchmark Suite

**Goal**: Run latency and max-throughput experiments for all 12 protocol configurations on the 5-node zoo cluster (.101-.105). Produce a single comprehensive results document with all commands, metrics, and CPU data.

### 4.0 Pre-experiment: enable in-binary CPU monitoring and verify mid-10s recording

All metrics must come from the middle 10 seconds of the 30-second run.

**Latency (p50/p90/p99)**: ✅ Already mid-10s filtered. The coordinators gate `cli2cli_[].append()` calls with `latency_window` (`dispatch_duration_3_times` between `duration*1000` and `duration*2*1000`). Both Jetpack (`rule/coordinator.cc:50-51,183`) and non-Jetpack (`none/coordinator.cc:17-18,36`) paths use this gating. No `mid_time_append()` needed — the caller already filters.

**Throughput (`Mid throughput`)**: ✅ Already mid-10s. `cli2cli[5]` only receives appends during the `latency_window`, so `cli2cli[5].count() / (duration / 3.0)` at `s_main.cc:924` is correct.

**CPU**: Use the in-binary `/proc/stat` monitor that already exists behind `#ifdef AWS` (`s_main.cc:838-846`). This calls `getUsage(server_core_id, duration)` which reads `/proc/stat` for core 1 every second during the middle third only (`first_phase` to `second_phase`), then logs `server median`. This is exactly what we need — mid-10s filtered, pinned to the server thread's core.

**Action item — enable the AWS CPU path for all builds:**
- [ ] Remove the `#ifdef AWS` / `#endif` guards around `s_main.cc:838-848` so the CPU monitor runs unconditionally (not just AWS builds)
- [ ] Also remove the `#ifndef AWS` / `#endif` around `sleep(Config::GetConfig()->duration_)` at line 849-851, since `getUsage()` already sleeps for the full duration
- [ ] Verify `server_core_id = 1` matches our server thread pinning (core 1). ✅ Correct.

After this change, every `.res` file will contain:
```
server median : 74.23       # CPU% of core 1 during mid-10s (median of 1-second samples)
```
plus the individual per-second samples logged as `CORE 1 USAGE: ...`. This works for ALL protocols (Raft, Jetpack, CURP, SwiftPaxos, EPaxos, etcd, etc.) since it reads `/proc/stat` directly, not from Jetpack RPC callbacks.

**No external CPU monitoring needed**: Drop `run_single_exp.sh`'s `/proc/stat` polling and `parse_cpustat.py` for this phase. The in-binary monitor is more accurate (mid-10s filtered, 1 sample/sec, correct core).

**Acceptance criteria:**
- [ ] `server median` line appears in `.res` files for ALL protocol modes (not just `#ifdef AWS`)
- [ ] CPU value is from mid-10s window only (verify by comparing with full-duration external monitor)
- [ ] Core ID matches server thread pinning (core 1)

### 4.1 Build

Build the binary following `README.md` Section 1.2:

```bash
docker build -f docker/zoo-build/Dockerfile -t jetpack-zoo-build .
docker create --name tmp jetpack-zoo-build
docker cp tmp:/output/deptran_server build/deptran_server
docker cp tmp:/output/lib build/docker_libs/
docker rm tmp
rm -f build/docker_libs/{libc.so.6,libm.so.6,libresolv.so.2,libgcc_s.so.1,libstdc++.so.6,ld-linux-x86-64.so.2}
```

Record in the results doc: git commit hash, build timestamp, binary sha256.

**Acceptance criteria:**
- [ ] Binary runs on all 5 zoo nodes
- [ ] `LD_LIBRARY_PATH=build/docker_libs deptran_server --help` succeeds on .101

### 4.2 Experiment matrix — 12 protocol configurations

| # | Label | Config | `-m` | Notes |
|---|---|---|---|---|
| 1 | Raft | `none_raft.yml` | `0` | Baseline, 2 RTT |
| 2 | Raft + Jetpack+Raft fp100 | `rule_raft.yml` | `100` | Jetpack 100% fast path |
| 3 | Raft + Jetpack+Raft adaptive | `rule_raft.yml` | `101` | Jetpack+Raft adaptive throttle |
| 4 | CURP (+ Raft) | `none_curp.yml` | `200` | Leader checks log, no recovery |
| 5 | SwiftPaxos | `none_swiftpaxos.yml` | `0` | Leaderless, hash-based |
| 6 | EPaxos (corrected) | `none_epaxos_corrected.yml` | `0` | Leaderless, dependency graph |
| 7 | etcd | `none_etcd.yml` | `0` | External etcd backend |
| 8 | ZooKeeper | `none_zookeeper.yml` | `0` | External ZK backend |
| 9 | CoPilot | `none_copilot.yml` | `0` | Dual-pilot protocol |
| 10 | Jetpack+CoPilot adaptive | `rule_copilot.yml` | `101` | Jetpack on CoPilot |
| 11 | Mencius | `none_mencius.yml` | `0` | Rotating leader |
| 12 | Jetpack+Mencius adaptive | `rule_mencius.yml` | `101` | Jetpack on Mencius |

### 4.3 Experiment 1: Latency (low load)

**Settings** (same as previous SwiftPaxos-style experiment):
- Topology: `30c1s5r5p-zoo.yml`
- Concurrency: `concurrent_1`
- Workload: `rw_1000000.yml` (100% write, 1M key range, near-zero conflict)
- Client: `client_open.yml` (open-loop, rate=1000/client)
- WAN: `WAN_DELAY_MS=20` (20ms one-way, 40ms RTT)
- Duration: 30s
- CPU monitoring: in-binary `/proc/stat` reader for core 1, mid-10s only (`server median` in `.res`)

**Run commands** (record each in the results doc):
```bash
RDIR=results/$(date +%Y-%m-%d)-full-protocol-benchmark

# 1. Raft
./run_single_exp.sh none_raft.yml 0 concurrent_1.yml raft-c1 $RDIR

# 2. Raft + Jetpack+Raft fp100
./run_single_exp.sh rule_raft.yml 100 concurrent_1.yml jp-raft-fp100-c1 $RDIR

# 3. Raft + Jetpack+Raft adaptive
./run_single_exp.sh rule_raft.yml 101 concurrent_1.yml jp-raft-adaptive-c1 $RDIR

# 4. CURP
./run_single_exp.sh none_curp.yml 200 concurrent_1.yml curp-c1 $RDIR

# 5. SwiftPaxos
./run_single_exp.sh none_swiftpaxos.yml 0 concurrent_1.yml swiftpaxos-c1 $RDIR

# 6. EPaxos
./run_single_exp.sh none_epaxos_corrected.yml 0 concurrent_1.yml epaxos-c1 $RDIR

# 7. etcd
./run_single_exp.sh none_etcd.yml 0 concurrent_1.yml etcd-c1 $RDIR

# 8. ZooKeeper
./run_single_exp.sh none_zookeeper.yml 0 concurrent_1.yml zookeeper-c1 $RDIR

# 9. CoPilot
./run_single_exp.sh none_copilot.yml 0 concurrent_1.yml copilot-c1 $RDIR

# 10. Jetpack+CoPilot adaptive
./run_single_exp.sh rule_copilot.yml 101 concurrent_1.yml jp-copilot-adaptive-c1 $RDIR

# 11. Mencius
./run_single_exp.sh none_mencius.yml 0 concurrent_1.yml mencius-c1 $RDIR

# 12. Jetpack+Mencius adaptive
./run_single_exp.sh rule_mencius.yml 101 concurrent_1.yml jp-mencius-adaptive-c1 $RDIR
```

**Metrics to record per protocol** (all from mid-10s window, all from `.res` files):

| Metric | Source in `.res` file |
|---|---|
| p50, p90, p99 (ms) | `All-efficient-attempts statistics ... 50pct X 90pct Y 99pct Z` |
| Total throughput (cmd/s) | Sum of `Mid throughput is X` across 5 hosts |
| Fast-path attempted / succeeded / rate | `Fastpath statistics attempted N successed M rate(pct) R` |
| CPU core 1 median per host (zoo0-zoo4) | `server median : X` (mid-10s, per-second samples of core 1) |
| CPU avg across 5 hosts | Average of 5 hosts' `server median` values |

**Acceptance criteria:**
- [ ] All 12 protocols produce valid results
- [ ] All metrics recorded from mid-10s window
- [ ] Results table in docs with exact commands used

### 4.4 Experiment 2: Max throughput (adaptive concurrency sweep)

**Settings**: Same as Experiment 1 except concurrency varies.

**Approach**: Adaptive binary search per protocol (same as our earlier SwiftPaxos-style experiment):
1. **Coarse scan**: concurrency = 1, 50, 150, 500, 1000
2. **Bisect**: narrow to find saturation point (throughput plateaus or latency spikes)
3. **Fine-tune**: 1-2 more points around the peak

**Saturation criteria**: throughput stops increasing AND/OR p90 jumps to >2x the low-load p90.

**Run commands**: For each of the 12 protocols, run the coarse scan first:
```bash
for conc in 1 50 150 500 1000; do
  ./run_single_exp.sh <protocol>.yml <mode> concurrent_${conc}.yml <label>-c${conc} $RDIR
done
```
Then bisect based on results (manual decision per protocol).

**Metrics to record per (protocol, concurrency) point**: Same table as Experiment 1.

**Acceptance criteria:**
- [ ] Each protocol's peak throughput identified (within ~10% of true max)
- [ ] Saturation concurrency identified for each protocol
- [ ] Total experiment points per protocol: ~8-12 (coarse + bisect)

### 4.5 Results documentation

Create `docs/full_protocol_benchmark.md` with:

1. **Header**: date, git commit, binary sha256, cluster layout, common settings
2. **Experiment 1 table**: 12 rows, columns: Protocol, p50, p90, p99, Total Throughput, FP Rate, CPU median per host (zoo0-zoo4), CPU avg across hosts
3. **Experiment 2 tables**: One table per protocol with columns: Conc, Total Throughput, p50, p90, p99, FP Rate, CPU median per host, CPU avg across hosts
4. **Max throughput summary table**: 12 rows, columns: Protocol, Peak Conc, Peak Throughput, p50 @ peak, CPU avg @ peak
5. **All commands run**: Exact `run_single_exp.sh` commands for every experiment point
6. **Raw data location**: Path to results directory with `.res` and `.csv` files

**Acceptance criteria:**
- [ ] All 12 protocols have latency + throughput data
- [ ] Every data point has CPU data from `server median` in each host's `.res` file (mid-10s filtered, core 1)
- [ ] Every command used is recorded verbatim in the doc
- [ ] Results are reproducible by re-running the recorded commands

### Summary of Phase 4

| Step | What | Depends on |
|---|---|---|
| 4.0 | Enable in-binary CPU monitor for all builds (remove `#ifdef AWS`) | — |
| 4.1 | Build binary | Phases 1-3 complete + 4.0 code change |
| 4.2 | Define experiment matrix (12 configs) | 4.1 |
| 4.3 | Run latency experiments (12 runs) | 4.2 |
| 4.4 | Run throughput experiments (~100 runs total) | 4.3 |
| 4.5 | Document results | 4.3, 4.4 |

**Estimated time**: ~12 latency runs × 85s + ~100 throughput runs × 85s ≈ ~2.5 hours total experiment time (excluding bisect decision time).

**Prerequisites**: Phases 1 (CURP), 2 (SwiftPaxos), and 3 (EPaxos) must be complete. etcd, ZooKeeper, CoPilot, and Mencius are already implemented in the codebase.

**Code change required**: Remove `#ifdef AWS` guard around `s_main.cc:838-851` so the in-binary CPU monitor runs for all builds. This is the only code change in Phase 4 — everything else is running experiments and documenting results.

---

## Phase 5: (Future) Evaluation paper

Write-up comparing all 12 protocol configurations across latency, throughput, contention (Zipf sweep), key-range sweep, failure recovery, and cluster size dimensions. Phase 4 provides the latency + throughput data; additional experiments (contention, recovery) would be added here.

*(Details TBD after Phase 4 is complete.)*
