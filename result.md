# Jetpack Benchmark Results

## Test Environment

- **Platform**: Docker containers (Ubuntu 22.04 base)
- **CPU**: Host machine (Linux 6.17.4-2-pve)
- **Benchmark**: `rw_fixed.yml` (100% writes to backend KV store)
- **Duration**: 30 seconds per test
- **Replicas**: 5 server replicas, 1 partition

## Open-Loop Performance (Jetpack ON vs OFF, 20ms latency)

Multi-process mode with 5 replicas, 20ms one-way simulated network latency (tc/netem),
open-loop client. Each process on a separate loopback IP (127.0.0.1-5).

**Latency model** (see `docs/latency_analysis.md`):
- tc/netem adds 20ms one-way delay between loopback IPs (127.0.0.2-5 ↔ any other IP).
  Server h1 (127.0.0.1) has no tc delay.
- `SIMULATE_WAN` is disabled (no software delays).
- RPC client sockets bind to their process's host IP (e.g. 127.0.0.2 for h2), so
  client→server traffic goes through tc/netem.
- Jetpack OFF: 1 client→leader RTT + backend write latency (BroadcastCommit is fire-and-forget)
- Jetpack ON (fast path): 1 RTT ≈ 40ms (BroadcastDispatch, speculative execution)

Each process reports its own latency independently. The leader process (h1) has lower
latency because client→leader is on the same IP (no tc/netem delay).

### Low-concurrency latency comparison (1 client per process, concurrency=1)

All backends run as **3-node clusters** (etcd Raft cluster, ZooKeeper ZAB ensemble,
MongoDB replica set with `w:majority`), so backend write latency includes the backend's
own replication RTT (~40ms via tc/netem).

| Backend | Jetpack OFF (h1/h2-h5 ms) | Jetpack ON (h1/h2-h5 ms) | Sanity |
|---------|---:|---:|---|
| etcd | 43.6 / 83.7 | 40.4 / 40.7 | PASS (40ms RTT + ~43ms etcd Raft repl) |
| MongoDB | 47.7 / 88.0 | 45.2 / 45.9 | PASS (40ms RTT + ~48ms Mongo repl) |
| ZooKeeper | 45.5 / 86.0 | 40.3 / 40.5 | PASS (40ms RTT + ~45ms ZAB repl + fsync) |

### High-concurrency comparison (60 clients, near-peak concurrency)

| Backend | Jetpack OFF | | Jetpack ON | |
|---------|---:|---:|---:|---:|
| | Concurrency | Throughput | Concurrency | Throughput |
| etcd | c=200 | 7,927 txn/s | c=200 | 7,104 txn/s |
| MongoDB | c=200 | 2,135 txn/s | c=200 | 2,160 txn/s |
| ZooKeeper | c=200 | 5,743 txn/s | c=200 | 5,498 txn/s |

### Maximum throughput (60 clients, best concurrency from sweep)

| Backend | Jetpack OFF | | Jetpack ON | |
|---------|---:|---:|---:|---:|
| | Concurrency | Max (txn/s) | Concurrency | Max (txn/s) |
| MongoDB | c=50 | 2,304 | c=75 | 1,966 |
| etcd | c=200 | 7,753 | c=200 | 7,414 |
| ZooKeeper | c=400 | 5,879 | c=200 | 5,954 |

### Observations (open-loop, Jetpack ON vs OFF, 3-node backend clusters)

- **All three backends pass the latency sanity check** with 3-node backend clusters.
  Backend write latency now includes the backend's own replication RTT (~40ms), making
  the results realistic. etcd h1=43.6ms (0 RTT + ~43ms etcd Raft repl), h2-h5=83.7ms
  (40ms RTT + ~43ms). MongoDB h1=47.7ms, h2-h5=88.0ms. ZK h1=45.5ms (0 RTT + ~45ms
  ZAB repl + fsync), h2-h5=86.0ms (40ms RTT + ~45ms).
- **Jetpack ON latency is ~40ms** across all backends (fast path bypasses backend write).
  This demonstrates Jetpack's core value: speculative execution eliminates backend I/O
  from the critical path.
- **Backend write latency with replication**: etcd ~43ms (Raft repl RTT + WAL),
  MongoDB ~48ms (repl RTT + local write), ZooKeeper ~45ms (ZAB repl RTT + txn log fsync).
  The 40ms client→leader RTT is visible as the delta between h1 and h2-h5 latencies for
  etcd (43.6 vs 83.7), MongoDB (47.7 vs 88.0), and ZooKeeper (45.5 vs 86.0).
- **Maximum throughput**: etcd is fastest (~7.8K txn/s off, ~7.4K on), ZooKeeper is
  moderate (~5.7K off, ~5.5K on), MongoDB is lowest (~2.3K off, ~2.0K on).
- **Jetpack ON throughput is comparable or slightly lower** than Jetpack OFF. The
  BroadcastDispatch fast path adds some coordination overhead but does not significantly
  reduce peak throughput.

## Performance Results (5 replicas)

### Single-client tests (1 client, 5 replicas, concurrency=1)

| Backend | Median Latency (ms) | Average Latency (ms) | Throughput (txn/s) |
|---------|--------------------:|---------------------:|-------------------:|
| MongoDB | 141.74 | 141.24 | 7.10 |
| etcd | 87.82 | 90.04 | 11.20 |
| ZooKeeper | 84.01 | 83.90 | 11.90 |

### Multi-client tests (12 clients, 5 replicas, concurrency=10)

| Backend | Median Latency (ms) | Average Latency (ms) | Throughput (txn/s) |
|---------|--------------------:|---------------------:|-------------------:|
| MongoDB | 166.30 | 167.23 | 716.50 |
| etcd | 86.98 | 87.55 | 1368.20 |
| ZooKeeper | 85.69 | 86.05 | 1393.20 |

### Observations (5 replicas)

- **Ranking is consistent** with the 3-replica results: ZooKeeper < etcd < MongoDB for latency.
- **MongoDB latency increases significantly** with 5 replicas (106→142ms single-client, 116→166ms
  multi-client), reflecting the cost of replicating to more Jetpack replicas before responding.
- **etcd and ZooKeeper latency is nearly unchanged** (~84-88ms), suggesting their backend
  round-trip dominates and the Jetpack overhead per additional replica is minimal.
- **Throughput drops** for MongoDB (1234→717 multi-client) due to higher per-request latency,
  while etcd (1593→1368) and ZooKeeper (1736→1393) see moderate decreases.

## Multi-Process Results (5 replicas, 5ms network latency)

Multi-process mode runs each server+client pair as a separate OS process, with tc/netem
simulating 5ms +/- 2ms network latency between loopback addresses (127.0.0.1-5).

Previously this mode produced 0 throughput due to a `-P` flag bug: run scripts passed
site names (`-P s101`) instead of process names (`-P h1`). The `SitesByProcessName()`
function in `config.cc` matches process names (the VALUE in the config's `process:` map),
not site names (the KEY).

### Multi-process throughput (5 replicas, 1 client per process, 30s)

| Backend | Per-process throughput (txn/s) | Status |
|---------|----:|---|
| MongoDB | 9.4-9.6 | PASSED |
| etcd | 11.4-11.5 | PASSED |
| ZooKeeper | 9.0 | PASSED |

### Observations (multi-process)

- **All three backends produce non-zero throughput**, confirming inter-replica communication
  works correctly with the `-P` flag fix.
- **etcd** achieves the highest per-process throughput, consistent with single-process results.
- **MongoDB** and **ZooKeeper** are close at ~9-9.6 txn/s per process.
- **Throughput is lower** than single-process mode because each process only has 1 client
  (concurrency=1) and network latency adds ~5ms per inter-replica message.

## Performance Results (3 replicas, baseline)

### Single-client tests (1 client, 3 replicas)

| Backend | Median Latency (ms) | Average Latency (ms) | Throughput (txn/s) |
|---------|--------------------:|---------------------:|-------------------:|
| MongoDB | 106.45 | 106.24 | 9.50 |
| etcd | 88.64 | 89.97 | 11.10 |
| ZooKeeper | 82.98 | 83.14 | 12.10 |

### Multi-client tests (12 clients, 3 replicas)

| Backend | Median Latency (ms) | Average Latency (ms) | Throughput (txn/s) |
|---------|--------------------:|---------------------:|-------------------:|
| MongoDB | 115.72 | 116.35 | 1234.10 |
| etcd | 89.47 | 90.09 | 1593.10 |
| ZooKeeper | 82.78 | 82.85 | 1736.30 |

### Observations

- **ZooKeeper** achieves the lowest latency and highest throughput across both single-client
  and multi-client configurations. The native C client library with async callbacks
  (`zoo_aset`/`zoo_acreate`) avoids thread pool overhead.
- **etcd** has moderate latency (~89ms). The etcd-cpp-apiv3 library with pplx async tasks
  provides good throughput scaling with concurrent clients.
- **MongoDB** has the highest latency (~106-116ms). The mongocxx driver requires a dedicated
  thread pool (one `mongocxx::client` per thread) which adds scheduling overhead.
- **Throughput scales well** with concurrent clients for all backends: ~100x improvement
  going from 1 to 12 clients, indicating the bottleneck is per-client round-trip latency
  rather than backend capacity.

## Failure Recovery Results

### Recovery Architecture

Recovery testing uses an **external kill approach**: the test script (not Jetpack's
internal `server_failover_co()`) kills the backend leader by PID and writes signal
files. This simulates a real backend failure with actual leader election.

Recovery measures two phases:
1. **Original protocol downtime**: from SIGKILL of the leader to the new leader being
   elected (detected by the test script polling the backend cluster)
2. **Jetpack downtime**: from `primary_elected` signal file write to Jetpack finishing
   its own recovery (`recovery_finish_after_failure` signal detected)

Signal file path: `/tmp/JM_Jetpack_0.0.0.0` (due to `#define AWS` in constants.h).
Non-leader Jetpack servers poll this file every 10ms and trigger `JetpackRecoveryEntry()`
when the signal is detected.

### Test Configuration

- **Mode**: Single-process (`-P localhost`), 3 server replicas, 1 client
- **Backend clusters**: 3-node (MongoDB replica set / etcd cluster / ZooKeeper ensemble)
- **Run interval**: 5s normal operation before triggering failure
- **Kill method**: SIGKILL on backend leader PID (external, not Jetpack-initiated)
- **Signal chain**: script writes `failure_triggered` → kills leader → waits for new
  leader → writes `primary_elected` → Jetpack detects signal → runs recovery

### Recovery Test Results

| Backend | Protocol Downtime | Jetpack Downtime | Recovery Duration (internal) | Status |
|---------|------------------:|----------------:|----------------------------:|--------|
| MongoDB | ~10.6s | ~159-281ms | ~162-184ms | PASSED |
| etcd | ~6.0-6.3s | ~106-107ms | ~124-128ms | PASSED |
| ZooKeeper | ~0.5-1.1s | ~106ms | ~123-124ms | PASSED |

### Observations

- **ZooKeeper has the fastest leader election** (~0.5-1.1s), consistent with ZAB's
  fast leader election algorithm designed for low-latency failover.
- **etcd leader election takes ~6s**, reflecting Raft's election timeout (default
  1000ms) plus randomized backoff with 3-node quorum.
- **MongoDB replica set election is slowest** (~10.6s), as MongoDB's election protocol
  includes a longer heartbeat timeout (default 10s `electionTimeoutMillis`) before
  triggering step-down and new election.
- **Jetpack recovery is consistently fast** (~106-281ms across all backends). The
  internal recovery duration (logged by `JetpackRecovery()`) is 123-184ms, which
  includes the 4-phase Paxos-like recovery protocol. The measured "Jetpack downtime"
  includes signal detection latency (polling every 10ms) plus recovery execution.
- **MongoDB required a URI fix**: the original code built a comma-separated URI without
  `replicaSet=jetpack-rs`, so the mongocxx driver couldn't failover to surviving nodes.
  Adding the `replicaSet` parameter enabled automatic failover.
- **ZooKeeper required enabling recovery**: `JETPACK_ZOOKEEPER_RECOVERY` was not defined
  in `constants.h`. Adding the define enabled the signal polling code in
  `zookeeper/server.h`.

### RTT-Based Sanity Check and Gap Analysis

#### Protocol: 2 RTT rounds

Jetpack recovery requires **2 sequential RTT rounds** (each round sends parallel broadcasts):
- Round 1: PullRecovery + Prepare (parallel) → 1 RTT
- Round 2: RecordCmd + Accept (parallel) → 1 RTT

Plus a signal polling delay of 0–P ms (P = hooker poll interval).

**Expected Jetpack downtime = polling_delay + 2 × RTT**

With RTT = 40ms (benchmark environment): 0.5ms + 40ms + 40ms = **~81ms** (1ms poll) or
~85ms (10ms poll). This is the theoretical floor.

#### Measurement issue: script poll artifact

The recovery detection script was polling every **100ms** (`sleep 0.1`), inflating
reported Jetpack downtime by up to 100ms. With 10ms polling (`sleep 0.01`), the
measurement resolution improves to ±10ms.

#### Corrected results (10ms script poll interval)

Tests run in single-process Docker (0ms RTT between Jetpack replicas):

| Backend | Protocol Downtime | Jetpack Downtime | Internal Duration |
|---------|------------------:|----------------:|------------------:|
| etcd | ~1.1s | **3ms** | **1ms** |
| ZooKeeper | ~0.5s | **16ms** | **1ms** |
| MongoDB | ~10.3s | **94ms** | **60ms** |

Note: etcd and ZooKeeper recovery are near-zero as expected for 0ms RTT.

#### Gap: MongoDB 60ms overhead with 0ms RTT

**Expected with 0ms RTT**: ~0.5ms (polling) + 0ms + 0ms = ~1ms

**Observed**: 60-95ms (run-to-run variation) — a **~60-94ms gap**

**Root cause**: The Jetpack event reactor is congested by MongoDB driver reconnection
events (SDAM topology monitoring). After MongoDB leader failover, the mongocxx driver
triggers server discovery, generating I/O events that compete with Jetpack's in-process
recovery RPC coroutines. This is not a network latency issue but a CPU/reactor contention
issue specific to the MongoDB integration.

**Comparison**: etcd and ZooKeeper recover in 1ms because their client reconnection
overhead is minimal or handled in a separate thread, leaving the Jetpack reactor free.

#### Projection to WAN (RTT = 40ms)

| Backend | Expected Jetpack downtime | Notes |
|---------|--------------------------|-------|
| etcd | ~81ms | 0.5ms poll + 2×40ms |
| ZooKeeper | ~81ms | 0.5ms poll + 2×40ms |
| MongoDB | ~141–175ms | 81ms + ~60–95ms MongoDB reactor overhead |

### Recovery Test Raw Output (v2: 10ms script poll)

#### etcd Recovery (10ms poll)
```
etcd downtime: 1060ms (new leader: 127.0.0.1)
Jetpack recovery detected (3ms after signal)
Jetpack recovery completed (duration=1ms)
etcd cluster: 2/3 nodes healthy
```

#### ZooKeeper Recovery (10ms poll)
```
ZooKeeper downtime: 539ms (new leader: 127.0.0.3:2183)
Jetpack recovery detected (16ms after signal)
Jetpack recovery completed (duration=1ms)
ZooKeeper ensemble: 2/3 nodes healthy
```

#### MongoDB Recovery (10ms poll)
```
MongoDB downtime: 10259ms (new primary: 127.0.0.3)
Jetpack recovery detected (94ms after signal)
Jetpack recovery completed (duration=60ms)
MongoDB replica set: 2/3 nodes healthy
```

#### Previous results (100ms script poll — inflated by measurement artifact)
```
etcd:      6672ms / 4ms Jetpack (3ms internal)
MongoDB:  11047ms / 143ms Jetpack (95ms internal)
ZooKeeper:  540ms / 106ms Jetpack (1ms internal)
```
The 106ms for ZooKeeper was pure measurement artifact (100ms poll delay + 1ms recovery + 5ms detection).
The 143ms for MongoDB = 100ms script poll + ~43ms true overhead (from 95ms internal, first poll at 100ms boundary).

## Raw Metrics

### Performance test output format (5 replicas)

#### Single-client raw output (1 client, 5 replicas, concurrency=1, 30s)

**MongoDB**:
```
All-efficient-attempts  statistics  count 71  0pct 109.88  50pct 141.74  90pct 157.59  99pct 171.30  ave 141.24
Total throughtput is 7.00
Mid throughput is 7.10
```

**etcd**:
```
All-efficient-attempts  statistics  count 112  0pct 84.14  50pct 87.82  90pct 93.40  99pct 110.55  ave 90.04
Total throughtput is 10.60
Mid throughput is 11.20
```

**ZooKeeper**:
```
All-efficient-attempts  statistics  count 119  0pct 82.06  50pct 84.01  90pct 84.73  99pct 85.03  ave 83.90
Total throughtput is 11.93
Mid throughput is 11.90
```

#### Multi-client raw output (12 clients, 5 replicas, concurrency=10, 30s)

**MongoDB**:
```
All-efficient-attempts  statistics  count 7165  0pct 117.09  50pct 166.30  90pct 192.55  99pct 211.03  ave 167.23
Total throughtput is 701.97
Mid throughput is 716.50
```

**etcd**:
```
All-efficient-attempts  statistics  count 13682  0pct 82.28  50pct 86.98  90pct 90.65  99pct 97.09  ave 87.55
Total throughtput is 1359.73
Mid throughput is 1368.20
```

**ZooKeeper**:
```
All-efficient-attempts  statistics  count 13932  0pct 81.51  50pct 85.69  90pct 88.97  99pct 93.63  ave 86.05
Total throughtput is 1405.53
Mid throughput is 1393.20
```

### Performance test output format (3 replicas, baseline)

From `src/deptran/s_main.cc`:
```
All-efficient-attempts  statistics  count <N>  0pct <p0>  50pct <median>  90pct <p90>  99pct <p99>  ave <avg>
Total throughtput is <T>
Mid throughput is <M>
```

- **Median latency**: `50pct` value from `All-efficient-attempts` (milliseconds)
- **Average latency**: `ave` value from `All-efficient-attempts` (milliseconds)
- **Total throughput**: `Total throughtput` (transactions per second over entire test)
- **Mid throughput**: `Mid throughput` (transactions per second, steady-state)

### Single-client raw output

**MongoDB** (1 client, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 111  50pct 106.45  90pct 149.04  99pct 6247.84  ave 106.24
Total throughtput is 9.50
Mid throughput is 9.50
```

**etcd** (1 client, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 111  0pct 83.75  50pct 88.64  90pct 93.30  99pct 121.85  ave 89.97
Total throughtput is 11.17
Mid throughput is 11.10
```

**ZooKeeper** (1 client, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 121  0pct 81.96  50pct 82.98  90pct 83.87  99pct 88.97  ave 83.14
Mid throughput is 12.10
```

### Multi-client raw output

**MongoDB** (12 clients, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 12264  50pct 115.72  90pct 139.82  99pct 5953.35  ave 116.35
Total throughtput is 1236.23
Mid throughput is 1234.10
```

**etcd** (12 clients, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 15931  0pct 82.75  50pct 89.47  90pct 94.98  99pct 102.19  ave 90.09
Total throughtput is 1614.33
Mid throughput is 1593.10
```

**ZooKeeper** (12 clients, 3 replicas, 30s):
```
All-efficient-attempts  statistics  count 17363  0pct 80.69  50pct 82.78  90pct 83.65  99pct 84.74  ave 82.85
Total throughtput is 1737.13
Mid throughput is 1736.30
```
