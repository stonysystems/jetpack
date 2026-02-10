# Jetpack + ZooKeeper Integration Notes

Notes on the Jetpack + ZooKeeper integration, covering architectural decisions,
performance characteristics, and observations suitable for the paper.

## 1. ZooKeeper as an Ordering Layer (Like etcd, Unlike MongoDB)

Like etcd, Jetpack uses ZooKeeper as an **atomic broadcast / command sequencing
layer**. Commands are written to znodes under `/JetPack/KVTable/{key}` for
ordering purposes, using ZooKeeper's ZAB (ZooKeeper Atomic Broadcast) protocol
to guarantee total order across replicas.

| Aspect | etcd | MongoDB | ZooKeeper |
|--------|------|---------|-----------|
| Role | Ordering oracle | Data store | Ordering oracle |
| Protocol | Raft | Raft (replica set) | ZAB |
| Data model | Key-value (flat) | BSON documents | Znodes (hierarchical) |
| API style | gRPC + pplx async | Sync (thread pool) | C callbacks (async) |
| Path format | `JetPack/KVTable/{key}` | `JetPack.KVTable` collection | `/JetPack/KVTable/{key}` |

ZooKeeper's hierarchical znode structure naturally maps to Jetpack's key-value
model: each key becomes a child znode under `/JetPack/KVTable/`, with the
integer value stored as the znode data.

## 2. Native Async API via C Callbacks

ZooKeeper's C client library (`libzookeeper_mt`) provides true async operations
via callback-based APIs. This is architecturally distinct from both etcd (C++
futures via pplx) and MongoDB (no async, thread pool workaround):

| Backend | Async Mechanism | Thread Model |
|---------|----------------|--------------|
| etcd | `pplx::task` with `.then()` | C++ REST SDK thread pool |
| MongoDB | Custom thread pool (sync API) | N persistent worker threads |
| ZooKeeper | `zoo_aget`/`zoo_aset`/`zoo_acreate` callbacks | ZooKeeper internal I/O thread |

ZooKeeper async callbacks fire on the library's internal I/O completion thread
(part of the `zookeeper_mt` multi-threaded library). This means:
- **No per-request thread creation** (unlike etcd's sync fallback)
- **No dedicated thread pool needed** (unlike MongoDB)
- **Callbacks must be non-blocking** (they run on ZooKeeper's I/O thread)

The `ZookeeperConnectionThreadPool` dispatches commands via `ReadAsync()` /
`WriteAsync()`, and callbacks signal completion back to the caller via
`ThreadSafeIntEvent`. Despite the "ThreadPool" name, it uses ZooKeeper's
internal threading — an inflight counter pattern rather than worker threads.

## 3. Async Upsert with ZNONODE Fallback

ZooKeeper has no native upsert operation. The async write path implements a
two-phase upsert pattern:

```
WriteAsync(key, value, on_complete)
  → zoo_aset(path, data)            // Try to update existing znode
    → WriteSetAsyncCallback:
      if rc == ZOK:                  // Znode existed, update succeeded
        on_complete(true)
      elif rc == ZNONODE:            // Znode doesn't exist yet
        → zoo_acreate(path, data)    // Create it
          → WriteCreateAsyncCallback:
            on_complete(rc == ZOK)
      else:
        on_complete(false)           // Other error
```

This contrasts with:
- **etcd**: `put()` is naturally idempotent (creates or overwrites)
- **MongoDB**: `update_one(filter, update, upsert=true)` built into API

The two-phase approach adds one extra round trip for the first write to each
key, but subsequent writes to the same key are single-operation. Under Jetpack's
workload pattern (hot keys with repeated writes), the amortized overhead is low.

## 4. Watch-Based Leader Detection

ZooKeeper's most distinctive feature for failover is its **native watch
mechanism**. Unlike etcd (key-watching via gRPC streams) or MongoDB (SDAM
heartbeat-based), ZooKeeper watches are:

- **One-shot**: Each watch fires exactly once, then must be re-registered
- **Server-side**: The ZooKeeper server pushes notifications (no polling)
- **Low-latency**: Watch events arrive within the session timeout window

The `ZookeeperLeaderWatcher` monitors an ephemeral znode at `/JetPack/leader`:

```
Leader creates ephemeral /JetPack/leader znode
  → Leader session dies
    → ZooKeeper automatically deletes ephemeral znode
      → ZOO_DELETED_EVENT fires on all watchers
        → ZookeeperLeaderWatcher re-registers watch via zoo_wexists()
          → New leader creates /JetPack/leader
            → ZOO_CREATED_EVENT fires
              → jm_signal::set_key("zookeeper", "primary_elected", host)
```

This leverages ZooKeeper's ephemeral znode semantics: the leader's session
keepalive automatically handles crash detection without any application-level
heartbeat. Session expiry triggers znode deletion, which triggers watches.

| Detection | etcd | MongoDB | ZooKeeper |
|-----------|------|---------|-----------|
| Mechanism | Key watch (gRPC stream) | SDAM heartbeat | Ephemeral znode + watch |
| Latency | <1ms (event-driven) | ~1-10s (heartbeat) | ~session timeout (event-driven) |
| Polling | None (async) or 100ms (sync) | None (driver-managed) | None (server-pushed) |
| Re-registration | Persistent watch | Automatic | Must re-register after each event |

## 5. Non-Leader Request Throttling

Same pattern as etcd and MongoDB — non-leader replicas set `max_inflight = 0`:

```cpp
ZookeeperConnectionThreadPool(
    loc_id_ == 0 ? zk_connection_ : 0,  // Leaders: 80-2500; followers: 0
    zk_uri_
)
```

This prevents followers from competing for ZooKeeper during normal operation.
Connection limits are environment-dependent: 2500 for AWS, 80 for local.

## 6. ZooKeeper Ensemble vs. etcd Cluster

The recovery test creates a 3-node ZooKeeper ensemble, which differs from
etcd's 3-node cluster in several ways:

| Aspect | etcd Cluster | ZooKeeper Ensemble |
|--------|-------------|-------------------|
| Leader election | Raft (randomized timeout) | ZAB (FastLeaderElection) |
| Election time | ~1-3s | ~2-10s (tickTime-dependent) |
| Health check | HTTP `/health` endpoint | Four-letter commands (`ruok`, `srvr`) |
| Leader detection | `etcdctl endpoint status` | `srvr` → `Mode: leader` |
| Config format | CLI flags | `zoo.cfg` file + `myid` |
| Ports | 1 client + 1 peer | 1 client + 1 peer + 1 election |

ZooKeeper ensembles use three ports per node: client port (2181+), peer port
(2888+), and election port (3888+). The `myid` file in each node's data
directory is critical for ensemble identity.

## 7. Build Complexity: Maven + CMake

The ZooKeeper C client build is more complex than etcd or MongoDB due to the
jute serialization code generation step:

```
Step 1: mvn generate-sources -pl zookeeper-jute -q -DskipTests
  → Generates zookeeper.jute.c and zookeeper.jute.h from zookeeper.jute schema
  → Requires Java + Maven (heavyweight build dependencies)

Step 2: cmake .. -DWANT_SYNCAPI=ON -DWANT_CPPUNIT=OFF -DWITH_CYRUS_SASL=OFF
  → Builds libzookeeper_mt.so (sync + async multi-threaded library)
```

This means the Docker build stage requires both `default-jdk` and `maven`
packages (significant image size overhead), even though the runtime only needs
`default-jre-headless` for the ZooKeeper server.

Build dependency comparison:
- **etcd**: C++ only (etcd-cpp-apiv3, CMake)
- **MongoDB**: C + C++ (mongo-c-driver + mongo-cxx-driver, both CMake)
- **ZooKeeper**: Java + Maven + C/CMake (heaviest build chain)

## 8. File-Based IPC for Failover Signaling

Same mechanism as etcd and MongoDB (`jm_file_signal.h`):

- **Signal format**: `/tmp/JM_Jetpack_<host>` contains `role:value` lines
- **Writer**: `ZookeeperLeaderWatcher` appends `zookeeper:primary_elected`
- **Reader**: `ZookeeperServer::Setup()` coroutine polls every 10ms
- **Consumer**: On detection, calls `JetpackRecoveryEntry()`

Signal namespaces across all three backends:
- etcd: `etcd:primary_elected`
- MongoDB: `mongo:primary_elected`
- ZooKeeper: `zookeeper:primary_elected`

## 9. Testing Infrastructure

Three Docker test modes validate the integration end-to-end:

| Mode | Topology | Purpose |
|------|----------|---------|
| `single` | 1 ZooKeeper + Jetpack (all-in-one) | Basic read/write correctness |
| `multi` | 1 ZooKeeper + 5 servers + 5 clients | Throughput under simulated latency (tc/netem) |
| `recovery` | 3-node ZooKeeper ensemble + Jetpack | Failover and recovery measurement |

The recovery test measures new leader election time with nanosecond precision
(`date +%s%N`), kills the ZooKeeper leader via SIGKILL, and validates that
the ensemble re-elects a leader and Jetpack detects the change.

Network latency simulation uses Linux `tc` with netem qdisc, applying per-IP
delay rules on the loopback interface (default 5ms +/- 2ms jitter).

## 10. Observations for the Paper

**Contrasting with etcd and MongoDB:**
- ZooKeeper provides the most natural watch mechanism (ephemeral znodes +
  one-shot watches) — no application-level key seeding needed, session
  expiry automatically signals leader loss
- ZooKeeper's C callback API is the only truly event-driven async path
  among the three backends — no thread pool needed, no polling
- ZAB election is slower than Raft (~2-10s vs ~1-3s), but ZooKeeper's
  ephemeral znode detection is faster than MongoDB's SDAM heartbeat
- ZooKeeper's hierarchical namespace (`/JetPack/KVTable/{key}`) vs etcd's
  flat namespace (`JetPack/KVTable/{key}`) — conceptually similar but
  ZooKeeper requires explicit parent node creation

**Novel contributions:**
- Async upsert pattern with ZNONODE fallback — solves ZooKeeper's lack of
  native upsert while maintaining non-blocking execution
- Using ZooKeeper's ephemeral znode + watch mechanism for automatic leader
  crash detection — leverages ZAB session management rather than implementing
  custom heartbeat
- Unified recovery protocol (3-phase Paxos) works identically across all
  three backends (etcd, MongoDB, ZooKeeper), demonstrating Jetpack's
  backend-agnostic architecture

**Performance characteristics:**
- Callback-based async avoids thread pool overhead entirely
- Non-leader throttling (max_inflight=0) consistent across all backends
- Two-phase async upsert adds ~1 extra operation per new key (amortized to 0)
- 10ms failover detection granularity via file polling (same as etcd/MongoDB)

**Design tensions:**
- Maven/Java dependency for building ZooKeeper C client adds significant
  build complexity; could be mitigated by pre-generating jute files
- One-shot watches must be carefully re-registered after each event —
  missing a re-registration causes silent failure
- ZooKeeper session timeout determines leader crash detection latency;
  tuning it lower increases false positive risk under network partitions
- ZooKeeper's 1MB default znode size limit may constrain large value storage
  (not a concern for Jetpack's integer key-value workload)

**Verification:**
- 81 infrastructure validation checks pass (test-zookeeper-setup.sh)
- Docker-based integration tests cover basic, latency, and recovery scenarios
- All ZooKeeper C API calls verified against zookeeper.h (release-3.9.4)
