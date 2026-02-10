# Leader Watcher Analysis

This document analyzes how each leader watcher detects leader elections in
the base protocol (etcd, MongoDB, ZooKeeper) and what problems each approach
may have. For background on the overall signal mechanism and recovery chain,
see `docs/leader_election_signal.md`.

## Overview

Each `*_leader_watcher.h` file implements **client-side detection** (Approach A
in `leader_election_signal.md`). These watchers observe the base protocol
externally — without modifying the base protocol's source code — and write a
file signal (`primary_elected`) via `jm_signal::set_key()` when they detect a
new leader has been elected.

All three watchers share the same structure:

1. Connect to the backend cluster
2. Monitor for topology/key/znode changes indicating a new leader
3. On detection, call `jm_signal::set_key("<backend>", "primary_elected", local_host_)`
4. The Jetpack server's polling coroutine picks up the signal and calls `JetpackRecoveryEntry()`

The watchers differ in their detection mechanisms due to the different APIs
exposed by each backend.

---

## etcd Leader Watcher (`src/deptran/etcd_leader_watcher.h`)

### Detection Mechanism

Two modes, selected at compile time via `JANUS_ETCD_HAS_PPLX`:

**Mode 1: Event-driven watch (with pplx)**
- Uses `etcd::Watcher` to subscribe to the well-known key `JetPack/leader`
- The etcd Watch API establishes a gRPC stream that pushes events in real-time
- Triggers on `PUT` events: when a new leader writes its identity to the key
- The callback fires on the etcd client's pplx thread

**Mode 2: Polling fallback (without pplx)**
- Creates an `etcd::SyncClient` in a dedicated `std::thread`
- Polls `client.get(kEtcdLeaderKey)` every 100ms
- Compares the value against `last_value`; on change, triggers `OnLeaderChange`
- First read is treated as baseline (no signal on startup)

### Timing Characteristics

| Mode | Detection Latency | CPU Cost |
|------|------------------:|----------|
| Event-driven | ~0-10ms (gRPC push) | Negligible (idle stream) |
| Polling | 0-100ms (poll interval) | Low (one GET every 100ms) |

### Potential Problems

**1. Requires leader to write to the key.**
The watcher monitors the key `JetPack/leader`. For a detection to occur, the
new etcd leader must actively write its identity to this key. If the leader
election happens but nobody writes to the key (e.g., the application layer
crashes before writing), the watcher will never fire. This is unlike the
source-code modification approach (Approach C) where the signal is written
by the etcd server itself during its internal leader transition.

**2. Write delay after election.**
Even if the new leader writes to the key, there is an inherent delay between
when etcd internally promotes the new leader and when the application-level
write reaches the watcher. The etcd leader must first complete its internal
state transitions, then the application code must run, then the key write
propagates through etcd's Raft log and triggers the watch. This adds latency
compared to the source-code signal approach.

**3. Polling mode can miss rapid leader changes.**
In polling mode, if two leader changes happen within 100ms, the watcher may
only detect the final state. This is acceptable in practice (leader elections
are rare), but the intermediate state is invisible.

**4. Watch stream disconnection.**
The event-driven mode relies on a persistent gRPC stream. If the connection
is broken (e.g., network partition, etcd cluster restart), the watcher may
miss events during the disconnection window. The `etcd::Watcher` library
handles reconnection, but there is no guarantee that events during the gap
are replayed (depends on etcd's watch history retention and compaction).

**5. False positives on key overwrites.**
If the same leader re-writes the key (e.g., during a no-op update or key
refresh), the watcher will fire even though no actual leader change occurred.
The watcher does not track the previous value to distinguish a genuine leader
change from a redundant write (both modes just call `OnLeaderChange` on any
value difference or any PUT event).

**6. No `had_no_leader_` guard.**
Unlike the MongoDB and ZooKeeper watchers, the etcd watcher has no
`had_no_leader_` flag to debounce signals. Every PUT to the leader key
triggers a signal, even at startup. This means that if the etcd cluster is
already running with a leader when the watcher starts, the first watch event
(possibly spurious) will trigger a signal.

---

## MongoDB Leader Watcher (`src/deptran/mongodb_leader_watcher.h`)

### Detection Mechanism

Uses the **mongocxx driver's APM (Application Performance Monitoring)**
with SDAM (Server Discovery And Monitoring) topology change callbacks:

- Registers `on_topology_changed` callback via `mongocxx::options::apm`
- The mongocxx driver runs a background SDAM thread that monitors the replica
  set topology by periodically pinging all servers (default every 10 seconds,
  reduced to ~500ms for failover detection)
- The callback receives the previous and new topology descriptions
- Topology types are string-typed: `"Unknown"`, `"ReplicaSetNoPrimary"`,
  `"ReplicaSetWithPrimary"`

### State Machine

The watcher implements a simple state machine using `had_no_primary_`:

```
                       ┌─────────────────────────┐
      start            │   had_no_primary_=false  │
───────────────────────│                          │
                       │   (normal: with primary) │
                       └──────────┬───────────────┘
                                  │
              new_type = "ReplicaSetNoPrimary"
              or "Unknown"
                                  │
                                  ▼
                       ┌─────────────────────────┐
                       │   had_no_primary_=true   │
                       │                          │
                       │   (degraded: no primary) │
                       └──────────┬───────────────┘
                                  │
              new_type = "ReplicaSetWithPrimary"
              AND had_no_primary_ was true
                                  │
                                  ▼
                       ┌─────────────────────────┐
                       │ Signal: primary_elected  │ ──► jm_signal::set_key()
                       │ had_no_primary_=false    │
                       └──────────────────────────┘
```

This ensures the signal only fires when transitioning **from** no-primary
**to** with-primary — not on startup when the primary is already present.

### Timing Characteristics

| Aspect | Value |
|--------|------:|
| Detection latency | SDAM heartbeat interval (default ~10s, typically ~500ms-2s in practice) |
| Callback overhead | Negligible (runs on SDAM thread) |

### Potential Problems

**1. SDAM heartbeat delay dominates detection time.**
The driver's SDAM monitor pings servers at a configurable heartbeat interval.
The default is 10 seconds, which means after a primary step-down, it could
take up to 10 seconds for the driver to notice the topology change. In
practice, failover-aware URIs reduce this with `serverSelectionTimeoutMS`
and `heartbeatFrequencyMS`, but the latency is fundamentally bounded by the
heartbeat frequency. This is significantly slower than the source-code
signal approach.

**2. Topology event does not mean writes are ready.**
The `ReplicaSetWithPrimary` topology event fires when the driver discovers
a new primary. However, this does not guarantee the primary has finished
draining or is ready to accept writes. The driver may report the primary
while it is still in the `DRAIN` state. This can cause Jetpack to start
recovery before the MongoDB primary is fully operational, leading to
potential write errors.

**3. No reconnection handling for SDAM thread failure.**
If the mongocxx client object is disrupted (e.g., connection pool exhausted,
network partition), the SDAM thread may stop receiving topology events. The
watcher has no reconnection logic — it relies on the client staying alive.
If `client_` fails silently, the watcher becomes deaf to topology changes.

**4. Race between topology callback and signal write.**
The `OnTopologyChanged` callback runs on the SDAM background thread. If the
main Jetpack thread reads the signal file at the exact moment the callback
is writing to it (via `jm_signal::set_key`), there is a potential race on
the signal file. In practice, this is mitigated by the append-only nature
of the signal file and the polling interval (10ms), but it is not
theoretically race-free without file locking.

**5. Server description iteration is string-based.**
The watcher identifies the primary by iterating `servers` and comparing
`server.type()` with the string `"RSPrimary"`. The mongocxx API returns
`bsoncxx::stdx::string_view`, which is compared against a `std::string`
literal. If the driver changes the string representation in a future
version, the comparison would silently fail. This is a maintenance risk.

**6. Spurious topology oscillations.**
In a network partition scenario, the driver may rapidly oscillate between
`ReplicaSetWithPrimary` and `ReplicaSetNoPrimary` as it probes different
servers. Each transition from no-primary to with-primary fires a signal.
Multiple signals are idempotent from Jetpack's perspective (the polling
coroutine reads the signal once and breaks), but the log noise can be
confusing during debugging.

---

## ZooKeeper Leader Watcher (`src/deptran/zookeeper_leader_watcher.h`)

### Detection Mechanism

Uses ZooKeeper's native **watch mechanism** with ephemeral znodes:

- Monitors the ephemeral znode `/JetPack/leader`
- Uses `zoo_wexists()` to set a one-shot watch on the znode
- Watch callback fires on:
  - `ZOO_DELETED_EVENT`: leader's ephemeral node deleted (leader crashed,
    session expired)
  - `ZOO_CREATED_EVENT`: new leader created the znode
  - `ZOO_CHANGED_EVENT`: znode data changed (leader identity updated)
- ZooKeeper watches are **one-shot** — the callback must re-register the
  watch after each event by calling `SetWatch()` again

### Session Management

The watcher handles ZooKeeper session lifecycle:

- `DefaultWatcher` handles `ZOO_SESSION_EVENT`:
  - `ZOO_CONNECTED_STATE`: session (re)connected, sets up watch
  - `ZOO_EXPIRED_SESSION_STATE`: session expired, calls `Reconnect()`
- `Reconnect()` closes the old handle and creates a new session with
  `zookeeper_init()` (session timeout: 30 seconds)
- New sessions automatically trigger `DefaultWatcher` with connected state,
  which re-sets the watch

### State Machine

Similar to MongoDB's `had_no_primary_`:

```
      ZOO_DELETED_EVENT
──────────────────────────►  had_no_leader_ = true
                             SetWatch() (re-register)

      ZOO_CREATED_EVENT
      or ZOO_CHANGED_EVENT
      (when had_no_leader_)
──────────────────────────►  Signal: primary_elected
                             had_no_leader_ = false
                             SetWatch() (re-register)
```

The `had_no_leader_` flag prevents signaling on startup when the leader
znode already exists. It is set to `true` when the znode is absent (via
`zoo_wexists` returning `ZNONODE`) or deleted.

### Timing Characteristics

| Aspect | Value |
|--------|------:|
| Leader loss detection | Near-instant (ephemeral node deletion on session timeout) |
| New leader detection | Near-instant (watch fires on znode creation) |
| Session timeout | 30 seconds (configured in `zookeeper_init`) |
| Overall detection | Session timeout + watch delivery (~30s worst case for crash) |

### Potential Problems

**1. Session timeout delay for crash detection.**
When the ZooKeeper leader crashes (killed, not graceful shutdown), the
leader's session does not expire until the session timeout elapses (30
seconds in this code). During this window, the ephemeral znode still
exists, and the watcher sees no change. The actual detection latency for
a crash is bounded by the session timeout, not the watch mechanism itself.

This is a significant delay. The ZooKeeper leader election itself
(~0.5-1.1 seconds from benchmarks) may complete before the old leader's
session expires. In this case, the watcher detects a `ZOO_CHANGED_EVENT`
(new leader wrote to the znode) rather than a `ZOO_DELETED_EVENT` followed
by `ZOO_CREATED_EVENT`.

**2. One-shot watches can miss events.**
Between a watch callback firing and the `SetWatch()` re-registration,
there is a brief window where no watch is active. If an event occurs in
this gap, it is missed. This is a well-known ZooKeeper watch limitation.
For example:
- Watch fires with `ZOO_DELETED_EVENT` (leader lost)
- Before `SetWatch()` completes, a new leader creates the znode
- The creation event is missed because no watch was registered

In practice this window is very short (microseconds), but under heavy
load or network congestion it could widen.

**3. `ZOO_CHANGED_EVENT` handling may produce false positives.**
The `ZOO_CHANGED_EVENT` handler signals if `had_no_leader_` is true.
However, a data change to the znode does not necessarily mean a new leader
was elected. If the existing leader updates the znode data (e.g., refresh
or metadata update), and `had_no_leader_` is true from a previous
transient network issue, the watcher will incorrectly signal a new leader.

**4. Reconnection creates a new session with new identity.**
When the ZooKeeper session expires and `Reconnect()` is called, a new
session is created. Any ephemeral znodes created under the old session
(if this watcher also created them) would be deleted. More importantly,
the new session starts without watches — `DefaultWatcher` re-sets them
on `ZOO_CONNECTED_STATE`, but there is a window between the old session
expiring and the new session connecting where events are missed.

**5. No leader identity verification.**
The watcher does not read the znode data to determine which server became
the new leader. It only detects that a leader change occurred and signals
`primary_elected`. The Jetpack recovery procedure does not need to know
which server is the new leader (it broadcasts to all replicas), so this
is not a functional issue, but it means the watcher cannot distinguish
between different leaders.

**6. Blocking C API in callbacks.**
`zoo_wexists()` is called from within the watch callback (via `SetWatch`).
The ZooKeeper C client documentation warns that completion callbacks should
not call synchronous ZooKeeper API functions, as this can cause deadlocks
in single-threaded mode. In multi-threaded mode (the default for
`zookeeper_init` without `ZOO_READONLY`), this is safe but adds latency
to the callback execution.

**7. Network partition: split-brain scenario.**
If the watcher's ZooKeeper client is partitioned from the quorum but the
ZooKeeper cluster remains available, the watcher's session may expire.
On reconnection, it sees the current leader znode and (if `had_no_leader_`
was set during the partition) signals `primary_elected`. This could trigger
a Jetpack recovery even though no actual leader change occurred.

---

## Comparison Summary

| Aspect | etcd | MongoDB | ZooKeeper |
|--------|------|---------|-----------|
| **Detection API** | Watch key (gRPC stream) or poll | APM topology_changed callback (SDAM) | Watch znode (one-shot) |
| **Detection latency** | ~0-10ms (event) / 0-100ms (poll) | SDAM heartbeat (500ms-10s) | Near-instant (watch), but session timeout for crash (~30s) |
| **Requires leader to act** | Yes (must write to key) | No (driver discovers topology) | Depends (ephemeral node auto-deletes, but new leader must create) |
| **Debounce (had_no_leader)** | No | Yes | Yes |
| **Reconnection handling** | Via etcd::Watcher library | No (relies on client staying alive) | Yes (session expiry triggers reconnect) |
| **Event miss window** | None (stream) / 100ms (poll) | None (SDAM continuous) | Brief (between watch fire and re-register) |
| **False positive risk** | Medium (any PUT triggers signal) | Low (state machine transition) | Medium (ZOO_CHANGED_EVENT with stale had_no_leader) |

## Comparison with Source-Code Signals (Approach C)

The `*_leader_watcher.h` files (Approach A) detect leader changes
**externally** by observing the backend's public API. The source-code
modification approach (Approach C) writes the signal **internally** at the
exact moment the backend completes its leader transition.

| Aspect | Watcher (Approach A) | Source-Code Signal (Approach C) |
|--------|---------------------|-------------------------------|
| Detection accuracy | Indirect (observes effects) | Direct (writes at transition point) |
| Detection latency | Variable (100ms-30s depending on backend and mode) | Zero (synchronous with leader transition) |
| Requires base protocol modification | No | Yes (modifies `third_party/` sources) |
| Maintenance burden | Low (uses public APIs) | High (must track upstream changes, reapply patches) |
| Portability | Works with any backend version | Tied to specific source code locations |

For production deployments where modifying `third_party/` code is unacceptable,
the watcher approach is the only viable option. For benchmark timing accuracy,
the source-code signal approach is preferred. The existing Docker tests use
external scripts (Approach B) as a simpler alternative.
