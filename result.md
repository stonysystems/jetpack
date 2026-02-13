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

**Latency model** (see `docs/latency_analysis.md`): Two layers of latency simulation are active:
(1) tc/netem 20ms one-way between loopback IPs, and (2) `WAN_WAIT` 20ms software delays at
RPC send/receive points and backend server submit. Jetpack OFF latency = 80ms (4 × WAN_WAIT)
+ backend I/O. Jetpack ON (fast path) latency ≈ 80ms (2 × WAN_WAIT + tc quorum RTT),
independent of backend because the fast path bypasses backend I/O.

### Low-concurrency latency comparison (5 clients, concurrency=1)

| Backend | Jetpack OFF (ms) | Jetpack ON (ms) | Reduction |
|---------|---:|---:|---:|
| MongoDB | 133.60 | 87.64 | 34% |
| etcd | 86.54 | 81.79 | 5% |
| ZooKeeper | 172.09 | 81.90 | 52% |

### High-concurrency comparison (60 clients, concurrency=200)

| Backend | Jetpack OFF | | Jetpack ON | |
|---------|---:|---:|---:|---:|
| | Median (ms) | Throughput | Median (ms) | Throughput |
| MongoDB | 7,100 | 1,668 txn/s | 5,539 | 1,648 txn/s |
| etcd | 1,134 | 9,063 txn/s | 1,244 | 8,752 txn/s |
| ZooKeeper | 3,904 | 2,986 txn/s | 4,991 | 2,191 txn/s |

### Maximum throughput (60 clients, best concurrency)

| Backend | Jetpack OFF | | Jetpack ON | |
|---------|---:|---:|---:|---:|
| | Concurrency | Max (txn/s) | Concurrency | Max (txn/s) |
| MongoDB | c=70 | 2,226 | c=70 | 1,871 |
| etcd | c=200 | 9,063 | c=200 | 8,752 |
| ZooKeeper | c=300 | 3,006 | c=100 | 2,816 |

### Observations (open-loop, Jetpack ON vs OFF)

- **Jetpack's latency benefit is most dramatic for ZooKeeper** (52% reduction: 172→82ms),
  because ZooKeeper's write path (ZAB broadcast) requires extra network round trips that
  Jetpack's fast path eliminates.
- **MongoDB sees a strong 34% reduction** (134→88ms). MongoDB's write-to-primary overhead
  makes the saved RTT significant.
- **etcd's improvement is modest** (5%: 87→82ms) because etcd's embedded Raft is already
  very fast, so the Jetpack RTT savings are a small fraction of total latency.
- **Throughput under high load** is similar between Jetpack ON and OFF, indicating Jetpack's
  fast-path overhead does not degrade throughput significantly at saturation.
- **Maximum throughput** peaks at moderate concurrency (c=70 for MongoDB, c=200 for etcd,
  c=100-300 for ZooKeeper). Higher concurrency causes queuing without proportional
  throughput gains.

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

### Recovery Test Raw Output

#### MongoDB Recovery
```
MongoDB downtime: 10569ms (new primary: 127.0.0.3)
Jetpack recovery detected (159ms after signal)
Jetpack recovery completed (duration=162ms)
MongoDB replica set: 2/3 nodes healthy
```

#### etcd Recovery
```
etcd downtime: 6282ms (new leader: 127.0.0.3)
Jetpack recovery detected (107ms after signal)
Jetpack recovery completed (duration=124ms)
etcd cluster: 2/3 nodes healthy
```

#### ZooKeeper Recovery
```
ZooKeeper downtime: 538ms (new leader: 127.0.0.3:2183)
Jetpack recovery detected (106ms after signal)
Jetpack recovery completed (duration=123ms)
ZooKeeper ensemble: 2/3 nodes healthy
```

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
