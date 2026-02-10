# Jetpack + etcd Integration Notes

Notes on the Jetpack + etcd integration, covering architectural decisions,
performance characteristics, and observations suitable for the paper.

## 1. etcd as an Ordering Layer, Not a Data Store

The most distinctive aspect of this integration is that Jetpack uses etcd purely
as an **atomic broadcast / command sequencing layer**. Both reads and writes are
dispatched to etcd for ordering, but the etcd responses are intentionally
discarded. The actual state machine lives entirely within Jetpack.

This design separates two concerns:
- **Command ordering** (etcd's Raft consensus guarantees total order)
- **State machine replication** (Jetpack's own KV store and witness)

Implication: etcd functions as a consensus oracle. The key prefix
`JetPack/KVTable/{key}` namespaces Jetpack's command log within etcd's keyspace,
but the values stored there are not read back for application logic.

## 2. Dual Async/Sync API Paths

The integration supports two API modes, selected at compile time:

| Mode | Detection | Mechanism | Latency |
|------|-----------|-----------|---------|
| Async (pplx) | `__has_include(<pplx/pplxtasks.h>)` | `pplx::task` continuations | Low (non-blocking) |
| Sync fallback | Default | `std::thread(...).detach()` per request | Higher (thread spawn) |

The async path uses the C++ REST SDK's `pplx::task` with `.then()` continuations
for composable, non-blocking I/O. The sync fallback spawns a detached thread per
etcd request. Under high throughput the sync path may create significant thread
churn, but it provides a portable fallback when pplx is unavailable.

This dual-path pattern is used in both the KV handler (`EtcdKVTableHandler`) and
the leader watcher (`EtcdLeaderWatcher`):
- KV handler: `pplx::task<etcd::Response>` vs `std::thread` + `etcd::SyncClient`
- Leader watcher: `etcd::Watcher` (event-driven) vs 100ms poll thread

## 3. Non-Leader Request Throttling

A key performance optimization: non-leader replicas set `max_inflight = 0` in
their `EtcdConnectionThreadPool`, effectively dropping all etcd requests:

```
EtcdConnectionThreadPool(
    loc_id_ == 0 ? etcd_connection_ : 0,  // Leaders: 80-2500; followers: 0
    etcd_uri_
)
```

This prevents:
- **Thundering herd**: Followers don't compete for etcd during normal operation
- **Network storm**: Only the leader writes to etcd
- **Cascading failures**: Followers focus on recovery, not etcd contention

The connection limit is environment-dependent: 2500 for AWS deployments (better
network isolation), 80 for local testing.

## 4. Fire-and-Forget Replication

After writing to etcd, the leader broadcasts commit RPCs to all replicas but
does not wait for acknowledgments:

```cpp
auto f = proxy->async_Commit(md, fuattr);
Future::safe_release(f);  // Fire-and-forget
```

Safety relies on etcd's Raft durability: if the leader crashes after writing to
etcd but before broadcasting, replicas can recover commands from etcd during the
recovery protocol. This trades acknowledgment latency for throughput.

## 5. File-Based IPC for Failover Signaling

Inter-process failover coordination uses a simple file-based mechanism
(`jm_file_signal.h`) rather than RPC:

- **Signal format**: `/tmp/JM_Jetpack_<host>` contains `role:value` lines
- **Writer**: `EtcdLeaderWatcher` appends `etcd:primary_elected`
- **Reader**: `EtcdServer::Setup()` coroutine polls every 10ms
- **Consumer**: On detection, calls `JetpackRecoveryEntry()`

Design rationale:
- **Out-of-band**: Does not depend on Jetpack's RPC layer (which may be partitioned)
- **Cross-process**: Works across separate OS processes sharing `/tmp`
- **Debuggable**: `cat /tmp/JM_Jetpack_*` shows signal state
- **No dependencies**: Pure stdlib file I/O, no protobuf/gRPC overhead

Trade-off: 10ms polling adds up to 10ms detection latency, acceptable for
failover scenarios but not suitable for hot-path coordination.

## 6. Recovery Protocol (3-Phase Paxos)

When a non-leader detects `etcd:primary_elected`, it triggers
`JetpackRecoveryEntry()` which runs a multi-phase Paxos recovery:

**Phase 1 (parallel):**
- `PullRecovery`: Query all replicas for their command history
- `Prepare`: Paxos Phase 1 — establish witness ballot, check for prior accepts

**Phase 2 (conditional parallel):**
- `RecordCmd`: Replicas acknowledge recovered command set
- `Accept`: Paxos Phase 2 — accept proposed sid if ballot is valid

**Phase 3:**
- `Commit`: Notify replicas of consensus result (fire-and-forget)
- `Resubmit`: Re-execute recovered commands through the state machine

Each phase is instrumented with millisecond-resolution timing
(`chrono::steady_clock`), enabling recovery latency breakdown analysis. The
parallel execution of PullRecovery and Prepare in Phase 1 minimizes the
critical path.

## 7. Leader Election Detection

Two complementary mechanisms detect etcd leader changes:

**EtcdLeaderWatcher** (external etcd → Jetpack signal):
- Monitors `JetPack/leader` key in etcd
- Async path: `etcd::Watcher` callback on PUT events (<1ms latency)
- Sync path: polls key every 100ms
- On change: writes `etcd:primary_elected` signal to `/tmp/JM_Jetpack_<host>`

**EtcdServer recovery coroutine** (file signal → Jetpack recovery):
- Non-leader replicas poll `/tmp/JM_Jetpack_<host>` every 10ms
- On `etcd:primary_elected` signal: calls `JetpackRecoveryEntry()`

The two-stage design (etcd watch → file signal → recovery) provides isolation
between the etcd client library and Jetpack's coroutine system.

## 8. Testing Infrastructure

Three Docker test modes validate the integration end-to-end:

| Mode | Topology | Purpose |
|------|----------|---------|
| `single` | 1 etcd + 3 servers + 1 client | Basic read/write correctness |
| `multi` | 1 etcd + 5 servers + 5 clients | Throughput under simulated latency (tc/netem) |
| `recovery` | 3-node etcd cluster + 3 servers + 1 client | Failover and recovery measurement |

The recovery test creates a 3-node etcd cluster on separate loopback IPs
(127.0.0.1-3), runs Jetpack with failover configuration, and validates that
the kill → re-election → recovery pipeline completes correctly. It checks for
recovery completion in logs, measures recovery duration, and verifies etcd
cluster survival (2/3 nodes healthy post-kill).

Network latency simulation uses Linux `tc` with netem qdisc, applying per-IP
delay rules on the loopback interface (default 5ms +/- 2ms jitter).

## 9. Observations for the Paper

**Novel contributions:**
- Using etcd as a pure ordering oracle (not a data store) for distributed
  transactions — cleanly separates consensus from application state
- File-based IPC for failover signaling — simple, out-of-band, debuggable
- Dual async/sync API compilation — graceful degradation across environments

**Performance characteristics:**
- Non-leader throttling (max_inflight=0) prevents thundering herd
- Fire-and-forget replication trades ACK latency for throughput
- 10ms failover detection granularity via file polling

**Design tensions:**
- AWS-specific tuning (2500 vs 80 connections) embedded in source; could be
  config-driven
- Sync fallback spawns O(throughput) threads; acceptable for low-load but
  scales poorly
- Read results discarded from etcd — correct but surprising; worth explaining
  clearly in the paper

**Verification:**
- TLA+ model checking with exhaustive/partial coverage across Raft, CoPilot,
  Mencius compositions (see TODO.md for state counts)
- 68 infrastructure validation checks pass (test-etcd-setup.sh)
- Docker-based integration tests cover basic, latency, and recovery scenarios
