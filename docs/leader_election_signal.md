# Leader Election Signal Mechanism

This document explains how Jetpack detects leader changes in the underlying
consensus protocol (MongoDB/etcd/ZooKeeper) and triggers its own recovery.

## The Problem

Jetpack is a plugin consensus protocol that sits on top of a base protocol.
When the base protocol's leader fails and a new leader is elected, Jetpack
must detect this event and run its own recovery procedure
(`JetpackRecoveryEntry()` in `scheduler.cc`). The challenge is coordinating
between two independent systems — the base protocol's leader election and
Jetpack's recovery — without modifying the base protocol's source code.

## Signal Mechanism

Communication between the base protocol layer and Jetpack uses **file-based
IPC** implemented in `jm_file_signal.h`. Signal files are stored under `/tmp/`
(overridable via `JM_SIGNAL_DIR` environment variable).

### File Format

Each signal file is named `JM_Jetpack_<host>` where `<host>` identifies the
Jetpack server instance. Lines in the file have the format `<role>:<value>`:

```
# /tmp/JM_Jetpack_0.0.0.0
etcd:primary_elected
failure:failure_triggered
jetpack:recovery_finish
jetpack:recovery_finish_after_failure
```

### API

```cpp
namespace jm_signal {
  // Write a signal: appends "<role>:<value>\n" to /tmp/JM_Jetpack_<host>
  void set_key(const string& role, const string& value, const string& host);

  // Check if a signal exists (non-blocking)
  bool exists_key(const string& role, const string& value, const string& host);

  // Block until a signal appears (busy-wait, 1ms sleep)
  void wait_for_key(const string& role, const string& value, const string& host);
}
```

### Host Resolution

The `<host>` portion of the signal file path depends on the build configuration:
- With `#define AWS` in `constants.h` (current default): host is always `"0.0.0.0"`
- Without AWS: host is resolved from `frame_->site_info_->host` (e.g., `"127.0.0.1"`)

Both the signal writer and reader must agree on the host value, or signals will
be missed. The current Docker test scripts write to `/tmp/JM_Jetpack_0.0.0.0`.

## Signal Chain

The full recovery signal chain has these steps:

```
1. Base protocol leader fails (killed/crashed)
2. Base protocol elects new leader
3. Signal writer detects new leader → writes "primary_elected" signal
4. Jetpack server (non-leader) polls for signal (every 10ms)
5. Jetpack detects signal → calls JetpackRecoveryEntry()
6. JetpackRecovery() runs 4-phase Paxos-like recovery
7. JetpackResubmit() writes "recovery_finish" signal
8. If "failure_triggered" exists, also writes "recovery_finish_after_failure"
```

### Step 3: Who Writes the Signal?

There are two approaches for detecting the new leader and writing the signal:

#### Approach A: Client-side detection (current `*_leader_watcher.h` files)

The `*_leader_watcher.h` files detect leader changes from the **client side**
by watching topology/keys/znodes. This does NOT modify the original protocol's
source code — it observes externally.

| Backend   | Watcher File                    | Detection Method |
|-----------|--------------------------------|------------------|
| MongoDB   | `mongodb_leader_watcher.h`     | mongocxx APM `topology_changed` callbacks (SDAM) |
| etcd      | `etcd_leader_watcher.h`        | Watch `JetPack/leader` key for PUT events (or poll) |
| ZooKeeper | `zookeeper_leader_watcher.h`   | Watch `/JetPack/leader` ephemeral znode for create/delete events |

- **MongoDB**: Uses the mongocxx driver's APM (Application Performance Monitoring)
  to receive topology change callbacks. When the topology transitions from
  `ReplicaSetNoPrimary` to `ReplicaSetWithPrimary`, it signals `primary_elected`.

- **etcd**: Uses `etcd::Watcher` (pplx-based async) or falls back to polling the
  `JetPack/leader` key every 100ms. When the key's value changes, it signals.

- **ZooKeeper**: Uses `zoo_wexists()` with a watch callback on the
  `/JetPack/leader` ephemeral znode. Watches fire on `ZOO_DELETED_EVENT`
  (leader lost) and `ZOO_CREATED_EVENT` (new leader). Watches are one-shot
  and re-registered after each event.

#### Approach B: External script (current Docker test approach)

In the Docker integration tests, the **test script** itself detects the new
leader by polling the backend cluster, then writes the signal file directly:

```bash
# Kill the leader
kill -KILL $LEADER_PID

# Write failure signal
echo "failure:failure_triggered" > /tmp/JM_Jetpack_failure_triggered

# Wait for new leader (polling backend API)
wait_for_new_leader

# Write primary_elected signal
echo "etcd:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
```

This approach is simpler for testing but introduces latency from the bash
polling loop. The client-side watcher approach (A) is more accurate for
production timing.

#### Approach C: Source code modification (implemented)

For the most accurate recovery timing, the base protocol's source code
(in `third_party/`) is modified so the **new leader itself** writes
the signal file immediately after completing its election/recovery. This
eliminates any detection latency from approaches A and B.

Signal writes are added at the following locations:

- **MongoDB** (`third_party/mongo/src/mongo/db/repl/replication_coordinator_impl.cpp`):
  In `signalDrainComplete()`, after `completeTransitionToPrimary()` and the
  "Transition to primary complete; database writes are now permitted" log message.
  This is when the primary has finished draining, applied all pending ops, and is
  ready to accept client writes.

- **etcd** (`third_party/etcd/server/etcdserver/server.go`):
  In the `updateLeadership()` callback within `EtcdServer.run()`, inside the
  `newLeader && isLeader()` branch. This fires when the raft state machine
  transitions to `StateLeader` and the server begins serving as leader.

- **ZooKeeper** (`third_party/zookeeper/zookeeper-server/src/main/java/org/apache/zookeeper/server/quorum/Leader.java`):
  In `lead()`, after `setZabState(QuorumPeer.ZabState.BROADCAST)`. This is when
  the leader has completed ZAB discovery, synchronization, and is ready to
  broadcast proposals.

All three write `<backend>:primary_elected` to the signal file. The signal
host defaults to `0.0.0.0` but can be overridden via `JM_SIGNAL_HOST` env var.
The signal directory defaults to `/tmp` but can be overridden via `JM_SIGNAL_DIR`.

### Step 4-5: Jetpack Server Polling

Non-leader Jetpack servers run a coroutine that polls for the signal every 10ms.
This code is gated behind compile-time defines:

| Backend   | Define                          | Server File |
|-----------|--------------------------------|-------------|
| MongoDB   | `JETPACK_MONGODB_RECOVERY`     | `src/deptran/mongodb/server.h` |
| etcd      | `JETPACK_ETCD_RECOVERY`        | `src/deptran/etcd/server.h` |
| ZooKeeper | `JETPACK_ZOOKEEPER_RECOVERY`   | `src/deptran/zookeeper/server.h` |

All three are currently enabled in `src/deptran/constants.h`.

The polling code (example from etcd):
```cpp
#ifdef JETPACK_ETCD_RECOVERY
if (loc_id_ != 0) {
  Coroutine::CreateRun([this]() {
    std::string host = "0.0.0.0";  // with #define AWS
    while (true) {
      if (jm_signal::exists_key("etcd", "primary_elected", host)) {
        JetpackRecoveryEntry();
        break;
      }
      auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(10 * 1000); // 10ms
      sp_e->Wait();
    }
  });
}
#endif
```

### Step 6-8: Jetpack Recovery

`JetpackRecoveryEntry()` in `scheduler.cc` (line 856):
1. Records start timestamp with millisecond precision
2. Calls `JetpackRecovery()` — a 4-phase Paxos-like recovery protocol:
   - Phase 1: PullRecovery + Prepare (parallel broadcast to all replicas)
   - Phase 2: Accept (broadcast recovered commands)
   - Phase 3: Commit
   - Phase 4: Execute (via `JetpackResubmit()`)
3. `JetpackResubmit()` writes `recovery_finish` signal
4. If `failure_triggered` signal exists, also writes `recovery_finish_after_failure`
5. Records end timestamp and logs duration

## Recovery Timing Results

Measured in Docker with 3-node backend clusters and external kill (approach B):

| Backend   | Protocol Downtime | Jetpack Downtime | Recovery Duration |
|-----------|------------------:|----------------:|------------------:|
| MongoDB   | ~10.6s           | ~159-281ms      | ~162-184ms        |
| etcd      | ~6.0-6.3s        | ~106-107ms      | ~124-128ms        |
| ZooKeeper | ~0.5-1.1s        | ~106ms          | ~123-124ms        |

- **Protocol downtime**: Time from leader kill to new leader election (backend-specific)
- **Jetpack downtime**: Time from signal write to `recovery_finish_after_failure` detection
- **Recovery duration**: Time inside `JetpackRecovery()` (logged internally)

## Key Files

| File | Purpose |
|------|---------|
| `jm_file_signal.h` | File-based signal IPC (set_key, exists_key, wait_for_key) |
| `src/deptran/constants.h` | Feature toggles (JETPACK_*_RECOVERY, AWS) |
| `src/deptran/mongodb_leader_watcher.h` | MongoDB APM topology watcher |
| `src/deptran/etcd_leader_watcher.h` | etcd key watcher |
| `src/deptran/zookeeper_leader_watcher.h` | ZooKeeper znode watcher |
| `src/deptran/mongodb/server.h` | MongoDB server — polls for signal, triggers recovery |
| `src/deptran/etcd/server.h` | etcd server — polls for signal, triggers recovery |
| `src/deptran/zookeeper/server.h` | ZooKeeper server — polls for signal, triggers recovery |
| `src/deptran/scheduler.cc` | `JetpackRecoveryEntry()`, `JetpackRecovery()`, `JetpackResubmit()` |
| `src/deptran/s_main.cc` | `KillEtcdPrimary()`, `server_failover_co()` (internal kill path) |
| `src/deptran/client_worker.cc` | Client-side signal detection (pause/resume) |
