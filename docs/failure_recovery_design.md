# Failure Recovery Design

This document covers the full failure recovery architecture and integration procedure
for Jetpack with all three backends (etcd, MongoDB, ZooKeeper).

## Overall Design

Jetpack uses a **signal-file-based hooker pattern** for failure recovery. When the
underlying consensus protocol's leader fails:

1. The backend cluster detects the failure and elects a new leader.
2. A signal file is written to notify Jetpack.
3. Jetpack's polling coroutine detects the signal and triggers recovery.

### Why External Kill + Signal (vs. Client Watcher)

Jetpack supports two approaches for detecting leader changes:

- **Client-side watchers** (`EtcdLeaderWatcher`, `MongodbLeaderWatcher`,
  `ZookeeperLeaderWatcher`): event-driven detection via the backend's native API.
  These are suitable for production but depend on the backend client library's
  session/connection health, which can introduce detection delays or false positives
  (see `docs/leader_watcher_analysis.md` for detailed analysis).

- **External kill + signal file**: the test script kills the leader externally and
  writes signal files at precise timestamps. This gives exact control over the recovery
  timeline and produces clean, reproducible timing measurements for benchmarking.

The recovery tests use external kill + signal for measurement accuracy. In production,
client-side watchers would be used instead (or source-code modifications to the backend
that write the signal directly).

### Separation of Recovery Phases

Recovery is split into two independent phases with separate timing:

```
T_kill                    T_new_leader                   T_jetpack_done
  |--- backend downtime ----|--- Jetpack downtime ----------|
  |   (re-election)         |   (coordinated Paxos recovery)|
```

- **Original protocol downtime**: time for the backend cluster to elect a new leader.
  This is entirely determined by the backend's election timeout and protocol.
- **Jetpack downtime**: time from signal detection to Jetpack recovery completion.
  This is determined by Jetpack's 3-phase coordinated recovery protocol.

## Hook Mechanism

### File Signal Library (`jm_file_signal.h`)

Location: project root (`jm_file_signal.h`).

Signal files are stored in `/tmp/` (overridable via `JM_SIGNAL_DIR` environment variable).
Each file is named `JM_Jetpack_<host>`, where `<host>` is the Jetpack server's address
(e.g., `0.0.0.0` in Docker/AWS mode).

File format: append-only, one signal per line as `<role>:<value>`.

```
# Example: /tmp/JM_Jetpack_0.0.0.0
etcd:primary_elected
failure:failure_triggered
jetpack:recovery_finish
jetpack:recovery_finish_after_failure
```

Key API:

| Function | Description |
|----------|-------------|
| `jm_signal::set_key(role, value, host)` | Appends `role:value` to the signal file |
| `jm_signal::exists_key(role, value, host)` | Non-blocking check if signal exists |
| `jm_signal::wait_for_key(role, value, host)` | Busy-wait with 1ms sleep until signal appears |

### Recovery Hooker Thread

Each backend server (`etcd/server.h`, `mongodb/server.h`, `zookeeper/server.h`) creates
a polling coroutine in its `Setup()` method. The hooker thread:

1. Only runs on **non-leader replicas** (`loc_id_ != 0`).
2. Is guarded by a compile-time flag (`JETPACK_ETCD_RECOVERY`, `JETPACK_MONGODB_RECOVERY`,
   `JETPACK_ZOOKEEPER_RECOVERY` in `src/deptran/constants.h`).
3. Polls `jm_signal::exists_key()` every **10ms**.
4. When the signal is detected, calls `JetpackRecoveryEntry()` and exits.

```cpp
// Simplified hooker pattern (from etcd/server.h)
Coroutine::CreateRun([this]() {
    while (true) {
        if (jm_signal::exists_key("etcd", "primary_elected", host)) {
            JetpackRecoveryEntry();
            break;
        }
        auto ev = Reactor::CreateSpEvent<TimeoutEvent>(10 * 1000); // 10ms
        ev->Wait();
    }
});
```

### JetpackRecoveryEntry()

Declared in `src/deptran/scheduler.h`, implemented in `src/deptran/scheduler.cc`.

Recovery steps:
1. Logs recovery start with timestamp.
2. Sets `jetpack_status_ = JetpackStatus::RECOVERY`.
3. Calls `JetpackRecovery()` which performs coordinated recovery:
   - **Step 1**: Parallel `PullRecovery` + `Prepare` RPCs to all replicas.
   - **Step 2**: If Prepare succeeds, parallel `RecordCmd` + `Accept` RPCs.
4. Logs recovery completion with duration metrics.
5. Writes `jetpack:recovery_finish_after_failure` signal to indicate completion.

## Per-Backend Integration

### MongoDB

**Cluster setup**: 3-member replica set (`jetpack-rs`) on 127.0.0.1-3.

**Automatic reconnect**: URI uses `replicaSet=jetpack-rs` parameter, enabling the
mongocxx driver's SDAM (Server Discovery and Monitoring) to automatically reconnect
to the new primary after failover.

**Source-code signal write**: In `third_party/mongo/`, signal is written in
`replication_coordinator_impl.cpp:signalDrainComplete()` after the log message
"Transition to primary complete". This fires when the new primary finishes
applying oplog entries and is ready for writes.

**Election timing**: ~10-11s (default `electionTimeoutMillis` = 10000ms plus
replica set reconfiguration).

**Client watcher**: `MongodbLeaderWatcher` uses the mongocxx APM
(Application Performance Monitoring) callback `on_topology_changed`. The driver's
background SDAM thread monitors replica set topology and invokes the callback when
the topology transitions from `ReplicaSetNoPrimary` to `ReplicaSetWithPrimary`.
A `had_no_primary_` flag prevents false positives on initial connection.

### etcd

**Cluster setup**: 3-node Raft cluster on 127.0.0.1-3, each with separate data dirs.

**Leader detection**: `etcdctl endpoint status -w json` returns the Raft leader ID
for each member. The script compares `raft_leader == member_id` to identify the leader.

**Source-code signal write**: In `third_party/etcd/`, signal is written in
`server/etcdserver/server.go:updateLeadership()` callback when
`newLeader && isLeader()` — i.e., when the node transitions to leader status.

**Election timing**: ~6.0-6.3s (default election timeout).

**Client watcher**: `EtcdLeaderWatcher` watches the etcd key `JetPack/leader`:
- **Event-driven mode** (if `JANUS_ETCD_HAS_PPLX`): uses `etcd::Watcher` API for
  real-time PUT event notifications.
- **Polling fallback**: uses `etcd::SyncClient` with 100ms poll interval.

When the key changes, calls `jm_signal::set_key("etcd", "primary_elected", host)`.

### ZooKeeper

**Cluster setup**: 3-node ensemble on 127.0.0.1-3. myids assigned in reverse order
so 127.0.0.1 gets the highest myid and wins Fast Leader Election (FLE).

**Leader detection**: `echo srvr | nc <ip> <port>` returns server status including
`Mode: leader` or `Mode: follower`.

**Source-code signal write**: In `third_party/zookeeper/`, signal is written in
`Leader.java:lead()` after `setZabState(BROADCAST)` — i.e., when the leader enters
the broadcast phase and is ready to process writes.

**Election timing**: ~0.5-1.1s (Fast Leader Election is significantly faster than
etcd Raft or MongoDB elections).

**Client watcher**: `ZookeeperLeaderWatcher` uses ZooKeeper's native watch mechanism
on ephemeral znode `/JetPack/leader`:
- Sets a one-shot watch via `zoo_wexists()`.
- Handles `ZOO_DELETED_EVENT` (leader crashed, sets `had_no_leader_ = true`),
  `ZOO_CREATED_EVENT` (new leader), `ZOO_CHANGED_EVENT` (leader data changed).
- Re-registers watch after each event.
- Only signals on transitions from no-leader to with-leader.

## End-to-End Flow

```
1. Normal Operation
   - Jetpack leader processes client requests
   - Backend leader receives writes from Jetpack

2. Leader Kill
   - Test script (or production failure) kills backend leader
   - Backend writes stop, clients see errors
   - Script writes /tmp/JM_Jetpack_failure_triggered

3. Backend Re-election
   - Surviving backend nodes detect the failure
   - Backend-specific election protocol runs:
     - etcd: Raft election (~6s)
     - MongoDB: replica set election (~11s)
     - ZooKeeper: ZAB Fast Leader Election (~0.5s)
   - New leader becomes ready for writes

4. Signal File Written
   - Test script detects new leader (via status query) and writes:
     echo "<backend>:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
   - OR source-code modification writes signal directly
   - OR client watcher detects and writes signal

5. Jetpack Hooker Detects Signal
   - Non-leader replica's polling coroutine finds signal via exists_key()
   - Calls JetpackRecoveryEntry()

6. Jetpack Coordinated Recovery
   - Step 1: PullRecovery + Prepare RPCs (parallel)
   - Step 2: RecordCmd + Accept RPCs (parallel, if Prepare succeeded)
   - Duration: ~100-280ms (independent of backend)

7. Recovery Complete
   - Jetpack writes /tmp/JM_Jetpack_recovery_finish_after_failure
   - Normal operation resumes with new Jetpack leader
```

## Key Source Files

| Component | Path |
|-----------|------|
| File signal library | `jm_file_signal.h` |
| Recovery entry point | `src/deptran/scheduler.cc` (`JetpackRecoveryEntry`) |
| etcd hooker | `src/deptran/etcd/server.h` |
| MongoDB hooker | `src/deptran/mongodb/server.h` |
| ZooKeeper hooker | `src/deptran/zookeeper/server.h` |
| etcd watcher | `src/deptran/etcd_leader_watcher.h` |
| MongoDB watcher | `src/deptran/mongodb_leader_watcher.h` |
| ZooKeeper watcher | `src/deptran/zookeeper_leader_watcher.h` |
| Feature flags | `src/deptran/constants.h` |
| Recovery test (etcd) | `docker/etcd/run-etcd-test.sh` |
| Recovery test (MongoDB) | `docker/mongodb/run-mongodb-test.sh` |
| Recovery test (ZooKeeper) | `docker/zookeeper/run-zookeeper-test.sh` |

## Observed Recovery Times

| Backend | Backend Downtime | Jetpack Downtime | Total |
|---------|----------------:|----------------:|------:|
| etcd | ~6.0-6.7s | ~4-107ms | ~6.1-6.8s |
| MongoDB | ~10.6-11.0s | ~143-281ms | ~10.8-11.3s |
| ZooKeeper | ~0.5-1.1s | ~106ms | ~0.6-1.2s |

Jetpack's internal recovery time (~100-280ms) is small compared to backend election
times and is largely independent of which backend is used.
