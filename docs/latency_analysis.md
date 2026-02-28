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

Maximum throughput (60 clients, concurrency sweep, 2026-02-27) — **DIAGNOSTIC ONLY**:

> **Status**: The 2026-02-27 sweep data below is diagnostic/preliminary. It contains
> MongoDB connection failures at several concurrency points, lacks CPU/queue-depth metrics,
> and does not include a bottleneck analysis. A re-run with richer instrumentation is
> required before these numbers can be treated as final. See the follow-up tasks in TODO.md.

| Backend | Mode | Best Concurrency | Peak (txn/s) |
|---|---|---:|---:|
| etcd | Original | c=150 | 7,703 |
| etcd | Fast path 100% | c=150 | 7,116 |
| etcd | Adaptive | c=200 | 7,233 |
| MongoDB | Original | c=150 | 5,265 |
| MongoDB | Fast path 100% | c=200 | 4,894 |
| MongoDB | Adaptive | c=100 | 5,267 |
| ZooKeeper | Original | c=200 | 5,526 |
| ZooKeeper | Fast path 100% | c=200 | 5,681 |
| ZooKeeper | Adaptive | c=200 | 5,568 |

**Notes on modes:**
- **Original** (`none_*.yml`): Jetpack OFF, single-leader replication through backend.
- **Fast path 100%** (`rule_*.yml -m 100`): Jetpack ON, all txns use fast path (broadcast + quorum).
- **Adaptive** (`rule_*.yml -m 101`): Jetpack ON, dynamically selects fast/slow path per txn.

**MongoDB reliability note:** Some MongoDB concurrency points failed due to the MongoDB C
driver's `serverSelectionTryOnce` setting combined with a 5-host URI (5 Jetpack replicas)
vs 3-node MongoDB replica set. Failed points are omitted; the peak is from the best
successful data point. This reliability problem must be fixed before re-running.
Full raw diagnostic data: `docs/sweep_results_2026-02-27_diagnostic.csv`.

Full concurrency sweep (total txn/s, 60 clients, `60c1s5r5p.yml`):

| Conc | MongoDB Orig | MongoDB Fast | MongoDB Adapt | etcd Orig | etcd Fast | etcd Adapt | ZK Orig | ZK Fast | ZK Adapt |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 41 | 40 | 39 | 40 | 39 | 41 | 41 | 40 | 40 |
| 5 | 265 | 260 | 257 | 274 | 272 | 272 | 272 | 273 | 268 |
| 10 | — | 570 | 363 | 571 | 572 | 573 | 571 | 570 | 572 |
| 25 | 1,466 | 1,458 | — | 1,472 | 1,470 | 1,464 | 1,461 | 1,472 | 1,471 |
| 50 | — | 2,960 | 2,970 | 2,959 | 2,966 | 2,958 | 2,957 | 2,957 | 2,964 |
| 75 | 4,321 | 2,764 | 4,356 | 4,462 | 4,461 | 4,451 | 4,470 | 4,459 | 4,476 |
| 100 | — | 3,041 | 5,267 | 5,956 | 5,952 | 5,966 | 5,439 | 5,442 | 4,412 |
| 150 | 5,265 | 3,966 | 3,961 | 7,703 | 7,116 | 7,081 | 5,524 | 5,480 | 5,545 |
| 200 | — | 4,894 | 4,916 | 7,639 | 5,772 | 7,233 | 5,526 | 5,681 | 5,568 |
| 300 | 3,993 | 4,490 | 4,922 | 7,220 | 1,010 | 6,587 | 5,420 | 5,482 | 5,295 |
| 400 | 4,829 | — | 4,577 | 6,416 | 6,389 | 6,310 | 5,394 | 5,307 | 5,370 |

— = failed run (MongoDB connection issue). Raw diagnostic data: `docs/sweep_results_2026-02-27_diagnostic.csv`.

### Notes

- Each process in the 5-process benchmark setup reports its own latency independently.
  The leader process's client (h1) always has lower latency than follower processes because
  client→leader communication is on the same loopback IP (no tc/netem).
- High-concurrency results are dominated by queuing effects, not network RTT.
- `SIMULATE_WAN` must remain disabled when using tc/netem.
- etcd shows highest throughput (~7.7k txn/s) due to its efficient Raft implementation.
- ZooKeeper shows consistent ~5.5k txn/s across all three modes.
- MongoDB peaks at ~5.3k txn/s but has intermittent connection failures at some concurrency levels.

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
