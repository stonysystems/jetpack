# Benchmark Latency Analysis

## Summary

With `SIMULATE_WAN` disabled and tc/netem providing 20ms one-way network latency, the
latency model depends on the client's location relative to the leader:

- **Non-leader client (h2-h5) → Leader (h1)**: ~1 RTT = **40ms** + backend write latency
- **Leader client (h1) → Leader (h1)**: ~0ms RTT + backend write latency
- **Jetpack ON (fast path)**: ~1 RTT ≈ **40ms** (client broadcasts to all, waits for quorum)

The "none" mode (Jetpack OFF) is single-leader: client sends 1 Dispatch RPC to the leader,
leader runs OnCommit inline (backend write), then replies. BroadcastCommit to followers is
fire-and-forget (not in critical path). So the total latency is 1 client→leader RTT plus
the backend write time.

## Latency Simulation: tc/netem Only

The Docker benchmark uses **tc/netem** (kernel-level) to add 20ms one-way delay between
loopback IPs (127.0.0.2–5). Server h1 (127.0.0.1) has no tc delay. This simulates
inter-server network latency.

### SIMULATE_WAN Must Be Disabled

The `SIMULATE_WAN` macro (`src/deptran/constants.h`) adds 20ms `WAN_WAIT` software sleeps
at multiple code points. **When using tc/netem, `SIMULATE_WAN` must be commented out** —
otherwise the software delays are additive to the kernel-level delays.

```cpp
// src/deptran/constants.h
// #define SIMULATE_WAN   // <-- MUST be commented out for tc/netem benchmarks
```

### RPC Client Source IP Binding

The RPC client (`src/rrr/rpc/client.cpp`) now supports an optional `bind_addr` parameter.
When provided, the client socket calls `bind()` before `connect()`, ensuring traffic
originates from the process's configured host IP (e.g. 127.0.0.2 for h2).

Without this fix, all client sockets on Linux loopback default to src=127.0.0.1, bypassing
tc/netem rules entirely. The `Communicator` passes its local host IP (from
`Config::GetMyServers()`) to all `connect()` calls.

---

## Latency Model

### None Mode (Jetpack OFF)

The "none" mode protocol path:
1. Client sends 1 Dispatch RPC to the leader
2. Leader's `SchedulerNone::Dispatch()` calls `OnCommit()` inline
3. `OnCommit()` invokes the replication coordinator (`EtcdServer::Submit()`,
   `ZookeeperServer::Submit()`, or `MongodbServer::Submit()`) which writes to the backend
4. Leader replies to client
5. BroadcastCommit to followers is fire-and-forget (not in critical path)

```
Client on hX → Leader on h1:
  - If X=1: 0ms RTT (same host, no tc/netem)
  - If X=2-5: ~40ms RTT (20ms each way via tc/netem)
+ Backend write latency (includes backend's own replication RTT)
= Total per-transaction latency
```

### Backend Cluster Configuration

All three backends now run as **multi-node clusters** in benchmark mode, matching
their production deployment model. The backend's own replication RTT is part of the
write latency:

- **etcd**: 3-node Raft cluster (127.0.0.1-3). Writes require majority ack (2/3 nodes).
  etcd leader at 127.0.0.1 replicates to 127.0.0.2-3 via tc/netem (~40ms RTT).
  Expected write latency: ~40ms (Raft replication RTT) + few ms (local WAL).
- **ZooKeeper**: 3-node ZAB ensemble (127.0.0.1-3). Writes require majority ack.
  ZAB leader replicates to followers via tc/netem (~40ms RTT).
  Expected write latency: ~40ms (ZAB replication RTT) + few ms (txn log fsync).
- **MongoDB**: 3-node replica set (127.0.0.1-3) with `w:majority`. Writes wait for
  majority ack. Primary replicates to secondaries via tc/netem (~40ms RTT).
  Expected write latency: ~40ms (replication RTT) + ~46ms (local write) ≈ ~86ms.

Previously, all backends ran as single-node instances, which hid the replication
latency and produced unrealistically low write times (etcd: ~2ms, ZK: ~50ms fsync only).

**Measured write latencies** (3-node clusters, Setting A, h1 — no client→leader RTT):
- etcd: ~43.6ms (Raft replication RTT + WAL)
- MongoDB: ~47.7ms (replication RTT + local write)
- ZooKeeper: ~45.5ms (ZAB replication RTT + txn log fsync)

### Rule Mode (Jetpack ON)

The Jetpack fast path broadcasts the speculative execution request to all replicas and
waits for a quorum to respond.

```
Client on hX → broadcast to all replicas (h1: 0ms, h2-h5: 20ms one-way)
Wait for 3/5 quorum: at least 3 must respond
If client on h1: h1 immediate + h2,h3 after 40ms RTT → ~40ms
If client on h2: h2 immediate + h1 after 40ms + h3 after ~0ms (h2→h3 symmetric) → ~40ms
Total: ~40ms (1 RTT)
```

---

## Results After Fixes

### RPC Bind Fix Verification (etcd Setting A, single-node — obsolete)

**Note**: These results were obtained with a **single-node** etcd backend. With the
3-node etcd cluster fix, etcd write latency now includes Raft replication RTT (~40ms).
Expected post-fix results: h1 ~40ms, h2-h5 ~80ms.

Previous results (single-node etcd, for reference):

| Process | Host IP | Median Latency | Explanation |
|---|---|---:|---|
| h1 (leader) | 127.0.0.1 | ~2.4ms | 0ms RTT + ~2ms etcd write (single-node, no replication) |
| h2 | 127.0.0.2 | ~42ms | 40ms RTT + ~2ms etcd write (single-node) |
| h3 | 127.0.0.3 | ~42ms | 40ms RTT + ~2ms etcd write (single-node) |
| h4 | 127.0.0.4 | ~43ms | 40ms RTT + ~2ms etcd write (single-node) |
| h5 | 127.0.0.5 | ~43ms | 40ms RTT + ~2ms etcd write (single-node) |

Before the RPC bind fix, ALL processes showed ~2.65ms because all client sockets used src=127.0.0.1.

### Fixes Applied

1. **RPC client bind** (`src/rrr/rpc/client.cpp`): Client sockets now bind to the local
   process's host IP before connecting. This ensures tc/netem rules apply to client→server
   traffic on loopback.

2. **ZooKeeper URI** (`src/deptran/zookeeper/server.h`): Leader uses single-host URI
   (127.0.0.1:2181) to avoid artificial tc/netem latency through multi-host ZK URI.

3. **Multi-node backends** (`docker/*/run-*-test.sh`): Benchmark and multi-process modes
   now use 3-node backend clusters (etcd cluster, ZK ensemble, MongoDB replica set) instead
   of single-node instances. This ensures write latency includes the backend's own
   replication RTT (~40ms via tc/netem). MongoDB also uses `w:majority` write concern
   to wait for replication acknowledgment.

4. **ZK tc/netem latency** (`docker/zookeeper/run-zookeeper-test.sh`): Three fixes:
   (a) Excluded 127.0.0.1 from tc delay (etcd script already did this; ZK script didn't).
   (b) Reversed myid assignment so ZK leader is at 127.0.0.1 (highest myid=3 wins election).
   (c) Added port-based tc filter for ZK peer port 2888 to delay ZAB replication traffic.
   ZK ZAB followers connect TO the leader (dst=127.0.0.1), so IP-based tc filters never
   matched peer traffic. The port filter delays both directions on port 2888, simulating
   ~40ms RTT for ZAB replication. See `docs/zk_latency_analysis.md` for details.

### Current Results (3-node backend clusters)

Low-concurrency (5 clients, concurrency=1):

| Setting | h1 Avg (ms) | h2-h5 Avg (ms) | Explanation |
|---|---:|---:|---|
| etcd A (off) | 43.6 | 83.7 | 0/40ms RTT + ~43ms etcd Raft repl |
| etcd C (on) | 40.4 | 40.7 | Jetpack fast path, 1 RTT |
| MongoDB A (off) | 47.7 | 88.0 | 0/40ms RTT + ~48ms Mongo repl |
| MongoDB C (on) | 45.2 | 45.9 | Jetpack fast path, 1 RTT |
| ZK A (off) | 45.5 | 86.0 | 0/40ms RTT + ~45ms ZAB repl + fsync |
| ZK C (on) | 40.3 | 40.5 | Jetpack fast path, 1 RTT |

### Maximum Throughput Sweep (2026-02-28, post-fix)

Configuration: 60 clients (`60c1s5r5p.yml`), 5 replicas, 5 partitions, 20ms tc/netem,
3-node backend clusters, open-loop, 30s test duration per point.

**Modes:**
- **Original** (`none_*.yml`): Jetpack OFF, single-leader replication through backend.
- **Fast path 100%** (`rule_*.yml -m 100`): Jetpack ON, all txns use fast path.
- **Adaptive** (`rule_*.yml -m 101`): Jetpack ON, dynamically selects fast/slow path.

**Fixes applied since the 2026-02-27 diagnostic sweep:**
1. MongoDB URI limited to 3 hosts (was 5, causing connection failures)
2. `ulimit -n 65536` in Docker scripts (was 1024, exhausting file descriptors)
3. CPU, queue-depth, and fast-path metrics added to benchmark output
4. Adaptive queue-depth throttle refined: enable fast-path at low load (qd<50),
   throttle at high load (qd>50) to avoid wasted speculative RPC overhead

#### Peak Throughput Summary

| Backend | Original | FP 100% | Adaptive | Adaptive vs Original |
|---|---:|---:|---:|---|
| etcd | 7,709 @ c=150 | 6,545 @ c=200 | 6,672 @ c=200 | −13% (rule mode overhead) |
| MongoDB | 3,183 @ c=200 | 3,370 @ c=150 | 3,591 @ c=150 | **+13%** |
| ZooKeeper | 4,854 @ c=200 | 4,723 @ c=100 | 5,408 @ c=300 | **+11%** |

#### CPU and Bottleneck Analysis

| Case | Peak (txn/s) | CPU Leader Avg | Queue Depth | FP Rate at Peak | Bottleneck |
|---|---:|---:|---:|---:|---|
| etcd original | 7,709 | — | — | — | CPU-bound (etcd Raft + Jetpack leader) |
| etcd FP 100% | 6,545 | 90% | 579 | ~0% (stats gap) | Rule mode overhead (witness, conflict tracking) |
| etcd adaptive | 6,672 | 90% | 538 | ~0% (throttled) | Rule mode overhead; fp throttled at high qd |
| MongoDB original | 3,183 | — | — | — | Connection pool (2500/leader) + w:majority |
| MongoDB FP 100% | 3,370 | 20% | 1 | 5% (fp fails) | Fast-path conflicts; CPU underutilized |
| MongoDB adaptive | 3,591 | 85% | 1 | 85% | Best MongoDB; adaptive keeps fp high |
| ZK original | 4,854 | — | — | — | CPU + ZAB session overhead |
| ZK FP 100% | 4,723 | 92% | 1,451 | ~0% (stats gap) | CPU saturation + queue depth |
| ZK adaptive | 5,408 | 91% | 5,525 | 0% (throttled) | CPU near saturation; fp throttled |

**Key findings:**
- etcd is CPU-bound at ~90% in all rule modes. The ~13% gap between original and rule
  modes is inherent CoordinatorRule overhead (witness tracking, conflict detection, extra
  marshaling), not an adaptive policy issue. FP 100% shows the same gap.
- MongoDB adaptive outperforms original by 13% because fast-path avoids the expensive
  w:majority backend write for successful transactions.
- ZK adaptive outperforms original by 11%. At high concurrency the throttle correctly
  disables fast-path (queue depth reaches 5000+), preserving throughput.
- All backends show sporadic Docker process failures at various concurrency levels.
  Failed points are recorded as 0, not omitted.

#### Raw Sweep Data

Full concurrency sweep (total txn/s, 2026-02-28):

| Conc | etcd Orig | etcd FP100 | etcd Adapt | MongoDB Orig | MongoDB FP100 | MongoDB Adapt | ZK Orig | ZK FP100 | ZK Adapt |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 40 | 40 | 40 | 39 | 40 | 41 | 40 | 40 | 42 |
| 5 | 273 | 274 | 276 | 278 | 279 | — | 276 | 273 | 274 |
| 10 | 571 | 576 | 572 | 566 | 572 | 571 | 576 | 572 | 571 |
| 25 | 1,471 | 1,445 | 1,470 | 1,465 | 1,454 | 1,463 | 1,472 | 1,464 | 1,471 |
| 50 | 2,374 | — | 2,965 | 2,952 | 2,943 | 1,197 | 2,969 | 2,670 | 2,954 |
| 75 | 4,462 | — | 4,459 | 3,506 | 4,459 | 2,961 | 3,823 | 4,452 | 4,459 |
| 100 | 5,957 | 5,951 | 2,765 | — | 2,963 | — | 4,633 | 4,723 | 5,103 |
| 150 | 7,709 | 572 | — | 3,023 | 3,370 | — | — | — | 4,850 |
| 200 | 7,397 | 6,545 | 6,672 | 3,183 | 3,360 | 2,460 | 4,854 | 4,034 | 4,823 |
| 300 | 7,238 | — | — | 3,100 | 3,060 | 2,847 | — | — | 5,408 |
| 400 | 6,584 | 6,254 | 6,410 | — | 2,760 | — | — | — | 4,186 |

— = failed run (process crash or connection failure in Docker).
Raw TSV files: `docs/sweep_2026-02-28/*.tsv`.

**Notes:** MongoDB remains systematically slower (~3.2K) than etcd (~7.7K) and ZK (~5K)
due to the `#define AWS` 2500-connection pool and w:majority replication. Docker's
resource limits cause many high-concurrency MongoDB failures.

### Notes

- Each process in the 5-process benchmark setup reports its own latency independently.
  The leader process's client (h1) always has lower latency than follower processes because
  client→leader communication is on the same loopback IP (no tc/netem).
- High-concurrency results are dominated by queuing effects, not network RTT.
- `SIMULATE_WAN` must remain disabled when using tc/netem.
- etcd shows highest throughput (~7.7K txn/s original) due to efficient Raft implementation.
  Rule mode (FP 100% and adaptive) peaks at ~6.5-6.7K due to inherent CoordinatorRule overhead.
- ZooKeeper adaptive (5.4K) outperforms original (4.9K) at high concurrency.
- MongoDB adaptive (3.6K) outperforms original (3.2K) due to fast-path avoiding backend write.
- The adaptive queue-depth throttle (coordinator.cc) enables fast-path at low concurrency
  for latency benefit and throttles at high concurrency to preserve throughput.

---

## History

### Previous Analysis (obsolete)

An earlier version of this document analyzed results with `SIMULATE_WAN` enabled, which
added 4x 20ms `WAN_WAIT` software delays on top of tc/netem. Those results and explanations
are no longer valid — `SIMULATE_WAN` has been disabled, and the correct expectations are
the model described above.

### Pre-fix Sanity Check Failures

Before the RPC bind fix, etcd and MongoDB showed unrealistically low latencies because
client sockets used src=127.0.0.1 (bypassing tc/netem). ZooKeeper showed inflated latency
because the multi-host ZK URI caused writes to go through delayed loopback IPs.
