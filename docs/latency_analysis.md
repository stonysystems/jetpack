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

### Maximum Throughput Sweep (2026-03-02 full rerun)

Configuration: 60 clients (`60c1s5r5p.yml`), 5 replicas, 5 partitions, 20ms tc/netem,
3-node backend clusters, open-loop, 30s test duration per point.
Full 9-case rerun on 2026-03-02 (commit 194c32c1) with CPU instrumentation for all modes.

**Modes:**
- **Original** (`none_*.yml`): Jetpack OFF, single-leader replication through backend.
- **Fast path 100%** (`rule_*.yml -m 100`): Jetpack ON, all txns use fast path.
- **Adaptive** (`rule_*.yml`): Jetpack ON, dynamically selects fast/slow path.

**CPU measurement:**
- Rule modes: in-process leader CPU from RPC response aggregation.
- Original mode: external host CPU from `/proc/stat` snapshots before/after each Docker run
  (system-wide average across all cores, so lower than single-process measurements).

#### Peak Throughput Summary

| Backend | Original | FP 100% | Adaptive | Adaptive vs Original |
|---|---:|---:|---:|---|
| etcd | 7,687 @ c=200 | 6,749 @ c=400 | 7,323 @ c=200 | −5% (rule mode overhead) |
| MongoDB | 3,799 @ c=100 | 3,200 @ c=200 | 3,858 @ c=100 | **+2%** |
| ZooKeeper | 5,648 @ c=150 | 5,456 @ c=300 | 5,486 @ c=150 | −3% |

#### CPU and Bottleneck Analysis

| Case | Peak (txn/s) | CPU Avg (%) | Queue Depth | FP Rate at Peak | Bottleneck |
|---|---:|---:|---:|---:|---|
| etcd original | 7,687 | 8.1† | 7 | — | Backend Raft replication latency |
| etcd FP 100% | 6,749 | 10.2 | 284 | 26% | Rule mode overhead (witness, conflict tracking) |
| etcd adaptive | 7,323 | 11.7 | 315 | 89% | Rule mode overhead; adaptive keeps fp high |
| MongoDB original | 3,799 | 11.5† | 0.2 | — | w:majority replication + connection pool |
| MongoDB FP 100% | 3,200 | 9.7 | 1 | 0% (conflicts) | Fast-path conflicts force slow-path fallback |
| MongoDB adaptive | 3,858 | 9.2 | 1 | 77% | Best MongoDB; adaptive keeps fp high |
| ZK original | 5,648 | 9.2† | 926 | — | ZAB replication + queue buildup |
| ZK FP 100% | 5,456 | 11.9 | 4,745 | 0% (throttled) | Queue depth buildup at high concurrency |
| ZK adaptive | 5,486 | 5.9 | 3,085 | 0% (throttled) | Queue depth buildup at high concurrency |

† = external host CPU from `/proc/stat` (system-wide average); other values are in-process leader CPU.

**Key findings:**
- etcd original (7,687) is the highest throughput across all backends. Rule modes show a
  modest 5-12% throughput gap due to CoordinatorRule overhead (witness tracking, conflict
  detection, extra marshaling). The adaptive mode (7,323) recovers most of the gap by
  maintaining 89% fast-path success at peak.
- MongoDB adaptive (3,858) slightly outperforms original (3,799, +2%) because fast-path
  avoids the expensive w:majority backend write for successful transactions. FP 100%
  (3,200) is worst because fast-path conflicts at high concurrency force fallback.
- ZooKeeper original (5,648) slightly outperforms both rule modes. High queue depth
  (926-5,000+) at peak concurrency indicates the bottleneck is ZAB replication throughput,
  not CPU. Rule modes add overhead without a fast-path latency benefit at high load.
- **99/99 data points OK** — zero failed rows across all 9 datasets. The previous sweep
  (2026-02-28) had 12 sporadic Docker failures that are no longer present after the
  rerun with improved retry logic and Docker image rebuilds.

#### Raw Sweep Data

Full concurrency sweep (total txn/s, 2026-03-02 rerun, 99/99 OK):

| Conc | etcd Orig | etcd FP100 | etcd Adapt | MongoDB Orig | MongoDB FP100 | MongoDB Adapt | ZK Orig | ZK FP100 | ZK Adapt |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 40 | 40 | 40 | 41 | 40 | 40 | 40 | 41 | 39 |
| 5 | 272 | 275 | 272 | 275 | 274 | 274 | 270 | 271 | 273 |
| 10 | 568 | 567 | 574 | 569 | 573 | 563 | 570 | 574 | 567 |
| 25 | 1,472 | 1,466 | 1,466 | 1,457 | 1,474 | 1,466 | 1,476 | 1,468 | 1,463 |
| 50 | 2,975 | 2,969 | 2,964 | 2,970 | 2,104 | 2,965 | 2,959 | 2,959 | 2,958 |
| 75 | 4,458 | 4,465 | 4,463 | 3,728 | 2,715 | 3,850 | 4,460 | 4,459 | 4,459 |
| 100 | 5,949 | 5,938 | 5,925 | 3,799 | 2,948 | 3,858 | 5,360 | 4,743 | 5,054 |
| 150 | 7,616 | 4,818 | 6,956 | 3,767 | 2,507 | 3,670 | 5,648 | 4,730 | 5,486 |
| 200 | 7,687 | 6,065 | 7,323 | 3,642 | 3,200 | 3,542 | 5,590 | 5,436 | 4,621 |
| 300 | 6,977 | 6,449 | 6,790 | 3,460 | 2,880 | 3,200 | 5,489 | 5,456 | 5,380 |
| 400 | 6,915 | 6,749 | 6,051 | 3,149 | 2,920 | 1,660 | 5,223 | 4,931 | 5,423 |

Raw data: [`docs/sweep_2026-02-28/`](sweep_2026-02-28/README.md) (TSV + Markdown tables for each backend/mode).

**Notes:** MongoDB remains systematically slower (~3.8K) than etcd (~7.7K) and ZK (~5.6K)
due to the `#define AWS` 2500-connection pool and w:majority replication.

### Notes

- Each process in the 5-process benchmark setup reports its own latency independently.
  The leader process's client (h1) always has lower latency than follower processes because
  client→leader communication is on the same loopback IP (no tc/netem).
- High-concurrency results are dominated by queuing effects, not network RTT.
- `SIMULATE_WAN` must remain disabled when using tc/netem.
- etcd shows highest throughput (7,687 txn/s original) due to efficient Raft implementation.
  Rule modes (FP 100% and adaptive) peak at 6,749-7,323, a modest 5-12% gap from
  CoordinatorRule overhead.
- ZooKeeper original (5,648) slightly outperforms rule modes (5,456-5,486). High queue
  depth at peak concurrency indicates ZAB replication is the bottleneck, not CPU.
- MongoDB adaptive (3,858) slightly outperforms original (3,799). FP 100% (3,200) is
  worst because fast-path conflicts force expensive slow-path fallback at high concurrency.
- The adaptive queue-depth throttle (coordinator.cc) enables fast-path at low concurrency
  for latency benefit and throttles at high concurrency to preserve throughput.
- CPU values for original mode are host-level `/proc/stat` measurements (system-wide
  average across all cores), while rule-mode CPU is in-process leader CPU. These use
  different measurement methods and are not directly comparable.

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
