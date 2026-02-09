# Jetpack + MongoDB Integration Notes

Notes on the Jetpack + MongoDB integration, covering architectural decisions,
performance characteristics, and observations suitable for the paper.

## 1. MongoDB as a Data Store (vs. etcd as an Ordering Layer)

The most fundamental difference from the etcd integration is that Jetpack uses
MongoDB as an **actual data store**. Both reads and writes to MongoDB are
meaningful — the data written is read back for application logic.

| Aspect | etcd Integration | MongoDB Integration |
|--------|-----------------|---------------------|
| Role | Ordering oracle (consensus only) | Data store (persistence + consensus) |
| Reads | Discarded after ordering | Returned to application |
| Writes | Key logged for ordering | Document persisted with upsert |
| Data model | `JetPack/KVTable/{key}` keys | `JetPack.KVTable` collection, `{key, value}` documents |

Document format: BSON documents with `key` (integer) and `value` (integer)
fields, stored in database `JetPack`, collection `KVTable`. A unique index
on `key` enables efficient point lookups and upserts.

Write semantics use `collection.update_one(filter, update, upsert=true)`,
which inserts on miss — a natural fit for Jetpack's idempotent write commands.

## 2. Thread Pool as the Async API Pattern

Unlike etcd's `pplx::task`-based async API, mongocxx r3.10.1 provides **no
native async API** — no futures, no callbacks, no coroutine support. The
official recommendation is to use separate `mongocxx::client` instances per
thread, as each client is not thread-safe.

Jetpack implements a custom thread pool (`MongodbConnectionThreadPool`) that
provides non-blocking dispatch to callers while executing sync MongoDB
operations on dedicated worker threads:

```
Caller thread → CommandQueue[round-robin] → Worker thread → mongocxx::client → MongoDB
                                                        ↓
                                          cmd.mongodb_finished.Set(1) → Caller unblocks
```

Architecture:
- **N persistent worker threads**, each owning a dedicated `mongocxx::client`
- **Round-robin dispatch**: main thread pushes to per-worker queues (O(1))
- **Blocking on completion**: caller waits on `ThreadSafeIntEvent` signal
- **Per-thread connections**: satisfies mongocxx's single-thread-per-client constraint

This is superior to the etcd sync fallback (`std::thread(...).detach()`) because
it avoids per-request thread creation overhead and maintains persistent
connections. For mongocxx, this IS the correct async pattern.

## 3. Non-Leader Request Throttling

Identical to the etcd pattern, non-leader replicas set `thread_num = 0` in
their connection thread pool, effectively dropping all MongoDB requests:

```cpp
MongodbConnectionThreadPool(
    loc_id_ == 0 ? mongodb_connection_ : 0,  // Leaders: 80-2500; followers: 0
    mongodb_uri_
)
```

Only the Jetpack leader writes to MongoDB. This prevents:
- **Thundering herd**: Followers don't compete for MongoDB connections
- **Write conflicts**: Only one writer to the MongoDB replica set
- **Resource waste**: Followers focus on participating in consensus, not I/O

Connection limits are environment-dependent:
- **AWS**: 2500 connections (tuned for 3000 concurrent clients, ~0.66s latency)
- **Local**: 80 connections (constrained by OS ulimit)

## 4. SDAM-Based Leader Election Detection

MongoDB's Server Discovery And Monitoring (SDAM) protocol provides background
topology monitoring through the driver's Application Performance Monitoring
(APM) callbacks. The `MongodbLeaderWatcher` hooks into this:

```cpp
mongocxx::options::apm apm_opts;
apm_opts.on_topology_changed([this](const topology_changed_event& event) {
    OnTopologyChanged(event);
});
mongocxx::options::client client_opts;
client_opts.apm_opts(apm_opts);
client_ = std::make_unique<mongocxx::client>(uri, client_opts);
```

Detection logic:
1. SDAM background thread monitors replica set topology continuously
2. On topology change, callback fires with previous and new descriptions
3. If new type is `ReplicaSetNoPrimary` or `Unknown`: sets `had_no_primary_` flag
4. If new type is `ReplicaSetWithPrimary` AND previously had no primary:
   - Iterates server descriptions to find `RSPrimary` type
   - Extracts primary host:port
   - Calls `jm_signal::set_key("mongo", "primary_elected", host)`

This approach is fundamentally different from etcd's key-watching:
- **etcd**: Application-level key watch (`JetPack/leader` key, <1ms latency)
- **MongoDB**: Driver-level topology monitoring (SDAM heartbeat-based, ~1-10s)

The MongoDB approach doesn't require seeding a leader key — SDAM automatically
monitors the replica set topology based on the connection URI.

## 5. File-Based IPC for Failover Signaling

Same mechanism as etcd (`jm_file_signal.h`):

- **Signal format**: `/tmp/JM_Jetpack_<host>` contains `role:value` lines
- **Writer**: `MongodbLeaderWatcher` appends `mongo:primary_elected`
- **Reader**: `MongodbServer::Setup()` coroutine polls every 10ms
- **Consumer**: On detection, calls `JetpackRecoveryEntry()`

The signal namespace differs from etcd (`mongo:primary_elected` vs
`etcd:primary_elected`), allowing both integrations to coexist without
signal collision.

## 6. Recovery Protocol Integration

The recovery pipeline mirrors etcd's, using the same 3-phase Paxos protocol:

```
MongoDB primary killed
  → mongocxx SDAM detects topology change (~election timeout, typically 10s)
  → MongodbLeaderWatcher callback fires
  → jm_signal::set_key("mongo", "primary_elected", host)
  → MongodbServer coroutine detects signal (within 10ms)
  → JetpackRecoveryEntry()
  → Phase 1: PullRecovery + Prepare (parallel)
  → Phase 2: RecordCmd + Accept (conditional parallel)
  → Phase 3: Commit + Resubmit
```

Key difference from etcd: MongoDB's election timeout is typically 10 seconds
(configurable via `settings.electionTimeoutMillis`), while etcd's Raft election
is typically 1-3 seconds. This means the total recovery window for MongoDB is
dominated by the replica set election, not the Jetpack recovery protocol.

## 7. Coordinator Dispatch: Blocking Until Durable

The `CoordinatorMongodb::Submit()` follows a 3-step pattern:
1. `Server()->Submit(cmd)` — dispatches to MongoDB via thread pool, **blocks**
   until the write is durable
2. `commo()->BroadcastCommit(...)` — fire-and-forget replication to all replicas
3. Local callbacks — `func()`, `exe_callback()`

Crucially, the server-side `Submit()` blocks on `mongodb_finished->Wait()` until
the worker thread signals completion. This guarantees that when `BroadcastCommit`
fires, the data is already persisted in MongoDB — a stronger durability guarantee
than etcd's fire-and-forget pattern.

The Submit path also checks recovery status: if the server is in RECOVERY mode,
it rejects commands with `WRONG_LEADER`, ensuring no writes occur during the
recovery window.

## 8. Performance Instrumentation

With the `MONGODB_STATISTICS` compile flag, `MongoMetrics` records fine-grained
latency breakdown:
- **Queue depth**: Number of commands waiting at enqueue time
- **Queue wait**: Time from enqueue to dequeue (thread pool contention)
- **Service latency**: Actual mongocxx I/O time
- **End-to-end**: Queue wait + service time

Statistics are reported as percentiles (p50) via the `Distribution` class,
enabling identification of bottlenecks: is latency dominated by thread pool
contention (queue wait) or MongoDB I/O (service time)?

## 9. Testing Infrastructure

Three Docker test modes validate the integration end-to-end:

| Mode | Topology | Purpose |
|------|----------|---------|
| `single` | 1 mongod + 3 servers + 1 client | Basic read/write correctness |
| `multi` | 1 mongod + 5 servers + 5 clients | Throughput under simulated latency (tc/netem) |
| `recovery` | 3-member replica set + 3 servers + 1 client | Failover and recovery measurement |

The recovery test creates a 3-member MongoDB replica set using `rs.initiate()`,
runs Jetpack with failover configuration, kills the primary via SIGKILL, and
validates that the kill → re-election → APM detection → recovery pipeline
completes correctly. It measures MongoDB election timing via
`wait_mongodb_new_primary()` and checks Jetpack recovery completion in logs.

Network latency simulation uses Linux `tc` with netem qdisc, applying per-IP
delay rules on the loopback interface (default 5ms +/- 2ms jitter).

## 10. Observations for the Paper

**Contrasting with etcd:**
- MongoDB serves as both consensus participant AND data store, while etcd is
  purely a consensus oracle. This has implications for consistency: MongoDB's
  reads are eventually consistent across replicas, while etcd provides
  linearizable reads.
- Thread pool pattern (MongoDB) vs. pplx async (etcd) — different strategies
  for the same problem (non-blocking dispatch to a blocking backend)
- SDAM topology monitoring (MongoDB) vs. key-watching (etcd) — driver-level
  vs. application-level leader change detection
- MongoDB election takes ~10s vs. etcd ~1-3s, making MongoDB failover the
  dominant cost in the recovery pipeline

**Novel contributions:**
- Using mongocxx APM topology_changed callbacks for automatic leader change
  detection — leverages the driver's built-in SDAM rather than implementing
  custom monitoring
- Thread pool with per-thread connections as the canonical async pattern for
  mongocxx — could serve as a reference implementation for other projects
- Unified recovery protocol (3-phase Paxos) that works identically across
  different backend stores (etcd, MongoDB)

**Performance characteristics:**
- Non-leader throttling (thread_num=0) prevents write contention
- Blocking Submit guarantees data durability before replication broadcast
- AWS tuning (2500 connections) vs. local (80) reflects deployment realities
- 10ms failover detection granularity via file polling (same as etcd)

**Design tensions:**
- MongoDB's ~10s election timeout dominates recovery latency; tuning it lower
  risks split-brain scenarios within MongoDB
- Thread pool size is hardcoded per environment; could be config-driven
- Legacy URIs (AWS IPs) are hardcoded; recovery mode correctly builds from
  config, but non-recovery mode still uses fixed URIs
- The blocking `Submit()` serializes writes per leader; high-throughput
  scenarios may bottleneck on queue depth rather than I/O

**Verification:**
- 95 infrastructure validation checks pass (test-mongodb-setup.sh)
- Docker-based integration tests cover basic, latency, and recovery scenarios
- All mongocxx v3 API calls verified against r3.10.1 driver headers
