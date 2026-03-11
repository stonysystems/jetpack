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
- Historical baseline (2026-03-02 docs): etcd `~43.6ms`, MongoDB `~47.7ms`, ZooKeeper `~45.5ms`.
- Runbook-path rerun (2026-03-10, 3 attempts each): etcd median `42.59ms` (range `22.64-42.79`),
  MongoDB median `7.27ms` (range `7.12-7.28`), ZooKeeper median `42.78ms`
  (range `42.68-43.23`).
- Interpretation: etcd/ZooKeeper remain near the expected OFF-mode shape; MongoDB absolute
  levels are materially lower than the old baseline and are treated as updated rerun evidence.

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

| Setting | 2026-03-02 published h1/h2-h5 (ms) | 2026-03-10 rerun h1/h2-h5 (range, median) | Notes |
|---|---:|---:|---|
| etcd A (off) | 43.6 / 83.7 | 22.64-42.79 (42.59) / 62.65-82.86 (82.66) | Supporting overall with one low-latency outlier |
| etcd C (on) | 40.4 / 40.7 | 22.65-40.26 (22.78) / 40.41-40.42 (40.42) | `h2-h5` stable; `h1` bimodal; fast-path 100% |
| MongoDB A (off) | 47.7 / 88.0 | 7.12-7.28 (7.27) / 46.15-46.53 (46.27) | Material absolute mismatch vs old baseline |
| MongoDB C (on) | 45.2 / 45.9 | 7.33-7.76 (7.45) / 41.39-41.49 (41.44) | Material absolute mismatch vs old baseline; fast-path 100% |
| ZK A (off) | 45.5 / 86.0 | 42.68-43.23 (42.78) / 82.83-83.41 (82.89) | Supporting with mild downward drift |
| ZK C (on) | 40.3 / 40.5 | 40.25-40.27 (40.26) / 40.35-40.35 (40.35) | Supporting and stable |

Rerun evidence source: `docs/phase1d_low_concurrency_runs.md`.

### Maximum Throughput Sweep (accepted pass, refreshed 2026-03-11)

Configuration: 60 clients (`60c1s5r5p.yml`), 5 replicas, 5 partitions, 20ms tc/netem,
3-node backend clusters, open-loop, 30s test duration per point.
Canonical files in `docs/sweep_2026-02-28/` were refreshed from accepted pass
`results/reproduce_20260310_164201/sweep/` (accepted build commit `ff81e913`).

**Modes:**
- **Original** (`none_*.yml`): Jetpack OFF, single-leader replication through backend.
- **Fast path 100%** (`rule_*.yml -m 100`): Jetpack ON, all txns use fast path.
- **Adaptive** (`rule_*.yml`): Jetpack ON, dynamically selects fast/slow path.

**CPU measurement:**
- Rule modes: in-process leader CPU from RPC response aggregation.
- Original mode: external host CPU from `/proc/stat` snapshots before/after each Docker run
  (system-wide average across all cores, so lower than single-process measurements).

#### Peak Throughput Summary (accepted canonical pass)

| Backend | Original | FP 100% | Adaptive | Adaptive vs Original |
|---|---:|---:|---:|---|
| etcd | 7,743 @ c=150 | 6,995 @ c=150 | 7,369 @ c=200 | −4.8% |
| MongoDB | 4,298 @ c=75 | 3,380 @ c=200 | 3,873 @ c=75 | −9.9% |
| ZooKeeper | 5,564 @ c=150 | 5,438 @ c=150 | 5,427 @ c=150 | −2.5% |

#### CPU and Bottleneck Analysis

| Case | Peak (txn/s) | CPU Avg (%) | Queue Depth | FP Rate at Peak | Bottleneck |
|---|---:|---:|---:|---:|---|
| etcd original | 7,743 | 8.0† | 7 | — | Backend Raft replication latency |
| etcd FP 100% | 6,995 | 8.9 | 319 | 0% | Rule mode overhead + queue buildup |
| etcd adaptive | 7,369 | 9.3 | 362 | 90.9% | Adaptive keeps fast path high near peak |
| MongoDB original | 4,298 | 8.7† | 0.2 | — | w:majority replication + connection pool |
| MongoDB FP 100% | 3,380 | 12.1 | 1 | 0% | Fast-path throttled/conflicting at high load |
| MongoDB adaptive | 3,873 | 11.6 | 1 | 74.5% | Better than FP100, still below original |
| ZK original | 5,564 | 9.8† | 391 | — | ZAB replication + queue buildup |
| ZK FP 100% | 5,438 | 9.8 | 2,602 | 0% | Queue depth buildup at high concurrency |
| ZK adaptive | 5,427 | 9.6 | 3,436 | 0% | Queue depth buildup at high concurrency |

† = external host CPU from `/proc/stat` (system-wide average); other values are in-process leader CPU.

#### Peak/Shape Reproducibility vs Prior 2026-03-02 Baseline

To avoid over-precise single-run claims, we compare accepted canonical shapes against the
previous 2026-03-02 canonical snapshot (kept in Git history).

| Case | Peak 2026-03-02 | Peak accepted | Delta | Tail drop at c=400 (old -> accepted) |
|---|---:|---:|---:|---:|
| etcd original | 7,686.6 @ c=200 | 7,743.2 @ c=150 | +0.7% | 10.0% -> 5.0% |
| etcd FP100 | 6,749.3 @ c=400 | 6,995.2 @ c=150 | +3.6% | 0.0% -> 14.5% |
| etcd adaptive | 7,323.3 @ c=200 | 7,368.7 @ c=200 | +0.6% | 17.4% -> 13.3% |
| MongoDB original | 3,799.3 @ c=100 | 4,297.9 @ c=75 | +13.1% | 17.1% -> 22.3% |
| MongoDB FP100 | 3,199.6 @ c=200 | 3,380.0 @ c=200 | +5.6% | 8.7% -> 19.5% |
| MongoDB adaptive | 3,858.3 @ c=100 | 3,872.6 @ c=75 | +0.4% | 57.0% -> 28.4% |
| ZK original | 5,647.6 @ c=150 | 5,563.9 @ c=150 | -1.5% | 7.5% -> 2.2% |
| ZK FP100 | 5,456.4 @ c=300 | 5,438.1 @ c=150 | -0.3% | 9.6% -> 2.3% |
| ZK adaptive | 5,486.0 @ c=150 | 5,426.9 @ c=150 | -1.1% | 1.2% -> 8.9% |

**Reconciled interpretation:**
- Peak magnitudes are generally stable for etcd and ZooKeeper (within about +/-4%).
- MongoDB peak location is more environment-sensitive (`c=75` vs `c=100`) and shows
  larger absolute variance in original/FP100 modes.
- High-concurrency tail shape (`c=300/400`) is materially more variable than the peak.
  Claims should therefore emphasize **peak ranges and shoulder behavior near peak** rather
  than one over-precise tail number.
- **99/99 data points OK** in the accepted canonical dataset; the only retry event is
  MongoDB adaptive `c=1` (attempt0 failed, attempt1 selected).

#### Raw Sweep Data

Full concurrency sweep (total txn/s, accepted canonical pass):

| Conc | etcd Orig | etcd FP100 | etcd Adapt | MongoDB Orig | MongoDB FP100 | MongoDB Adapt | ZK Orig | ZK FP100 | ZK Adapt |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 40 | 40 | 40 | 40 | 40 | 40 | 40 | 40 | 40 |
| 5 | 273 | 273 | 275 | 274 | 272 | 272 | 272 | 274 | 274 |
| 10 | 566 | 570 | 572 | 570 | 572 | 568 | 572 | 570 | 572 |
| 25 | 1,467 | 1,472 | 1,477 | 1,466 | 1,471 | 1,465 | 1,470 | 1,465 | 1,469 |
| 50 | 2,964 | 2,967 | 2,967 | 2,963 | 2,602 | 2,971 | 2,970 | 2,970 | 2,969 |
| 75 | 4,449 | 4,465 | 4,462 | 4,298 | 2,678 | 3,873 | 4,457 | 4,462 | 4,469 |
| 100 | 5,937 | 5,960 | 5,965 | 3,986 | 2,752 | 3,695 | 5,345 | 5,345 | 4,845 |
| 150 | 7,743 | 6,995 | 7,084 | 3,800 | 3,164 | 3,786 | 5,564 | 5,438 | 5,427 |
| 200 | 7,605 | 6,686 | 7,369 | 3,867 | 3,380 | 3,591 | 5,140 | 5,404 | 5,018 |
| 300 | 7,261 | 6,932 | 6,620 | 3,601 | 2,960 | 3,279 | 5,494 | 5,027 | 5,405 |
| 400 | 7,353 | 5,984 | 6,390 | 3,339 | 2,720 | 2,773 | 5,440 | 5,315 | 4,944 |

Raw data: [`docs/sweep_2026-02-28/`](sweep_2026-02-28/README.md) (TSV + Markdown tables for each backend/mode).
*Note: The directory is named `sweep_2026-02-28` (initial sweep date) but currently contains the accepted refreshed canonical artifacts from the 2026-03-10/11 rerun pass.*

**Notes:** MongoDB remains systematically slower (~3.9K-4.3K) than etcd (~7.4K-7.7K) and ZK (~5.4K-5.6K)
due to the `#define AWS` 2500-connection pool and w:majority replication.

### Notes

- Each process in the 5-process benchmark setup reports its own latency independently.
  The leader process's client (h1) always has lower latency than follower processes because
  client→leader communication is on the same loopback IP (no tc/netem).
- High-concurrency results are dominated by queuing effects, not network RTT.
- `SIMULATE_WAN` must remain disabled when using tc/netem.
- etcd shows highest throughput (7,743 txn/s original in accepted pass) due to efficient
  Raft implementation. Rule modes (FP100/adaptive) peak at 6,995-7,369.
- ZooKeeper original (5,564) slightly outperforms rule modes (5,438 and 5,427). High queue
  depth at peak concurrency indicates ZAB replication is the bottleneck, not CPU.
- MongoDB original (4,298) is above adaptive (3,873) and FP100 (3,380) in the accepted pass.
  MongoDB tails remain the most environment-sensitive (`c=300/400`).
- Tail shape at high concurrency (`c=300/400`) is more variable across reruns than peak
  magnitude; prefer range-aware claims over single-run tail numbers.
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
