# Jetpack Benchmark Results

## Test Environment

- **Platform**: Docker containers (Ubuntu 22.04 base)
- **CPU**: Host machine (Linux 6.17.4-2-pve)
- **Mode**: Single-process (`-P localhost`) — all replicas and clients share one process
- **Benchmark**: `rw_fixed.yml` (100% writes to backend KV store)
- **Duration**: 30 seconds per test
- **Replicas**: 3 or 5 server replicas, 1 partition

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

Recovery testing measures two phases:
1. **Original protocol downtime**: from triggering failure to the original protocol
   completing leader election (signal file written)
2. **Jetpack downtime**: from signal file written to Jetpack finishing its own recovery

Jetpack recovery is triggered via `server_failover_co()` which calls `Pause()` on the
leader server and writes a `failure_triggered` signal. The client detects this signal
(~50-90ms latency) and pauses until `recovery_finish_after_failure` is signaled.

### Test Configuration

- **Config**: `failover_mongodb.yml` / `failover_etcd.yml` / `failover_zookeeper.yml`
- **Run interval**: 5s (normal operation before triggering failure)
- **Stop interval**: 10s (pause duration for recovery)
- **Fail target**: leader (locale_id=0)

### Recovery Test Results

Recovery tests were attempted in both single-process and multi-process Docker modes.

**Single-process mode** (5 replicas, `-P localhost`): Soft failover triggers correctly
(leader Pause + failure_triggered signal), but Jetpack recovery never completes because
no backend protocol leader election occurs — `Pause()` is internal and the backend
(MongoDB/etcd/ZooKeeper) continues running. Without a real leader change signal, the
`recovery_finish_after_failure` signal is never written and the client stays paused.

**Multi-process mode** (`--privileged`, 3-node backend clusters): The inter-replica
connectivity issue has been fixed (the `-P` flag bug), and normal multi-process throughput
now works. Recovery tests in multi-process mode have not yet been re-attempted with the fix.

| Backend | Mode | Original Protocol Downtime | Jetpack Downtime | Notes |
|---------|------|---------------------------:|-----------------:|-------|
| MongoDB | single-process | N/A | N/A | Failover triggered; recovery incomplete (no MongoDB leader election) |
| MongoDB | multi-process | N/A | N/A | Inter-replica connectivity fixed; recovery test not yet re-attempted |
| etcd | single-process | N/A | N/A | Failover triggered; recovery incomplete (etcd still running) |
| etcd | multi-process | N/A | N/A | Inter-replica connectivity fixed; recovery test not yet re-attempted |
| ZooKeeper | single-process | N/A | N/A | Failover triggered; recovery incomplete (ZK still running) |
| ZooKeeper | multi-process | N/A | N/A | Inter-replica connectivity fixed; recovery test not yet re-attempted |

### What Works

- Jetpack's soft failover mechanism triggers correctly in single-process mode
- `server_failover_co()` pauses the leader and signals clients within 50-90ms
- The recovery code path (`JetpackRecovery()`, `JetpackRecoveryEntry()`) is implemented
  and logs timestamps with millisecond precision

### What Needs Work

- **Multi-process networking**: Fixed. The `-P` flag bug (site names vs process names)
  was the root cause of 0 throughput. All three backends now work in multi-process mode.
- **Recovery signal chain**: The full chain (backend leader election → signal file →
  Jetpack recovery trigger → recovery complete) needs a multi-node backend deployment
  where the backend actually fails over. Now that multi-process connectivity is fixed,
  recovery tests should be re-attempted.

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
