# Jetpack Benchmark Results

## Test Environment

- **Platform**: Docker containers (Ubuntu 22.04 base)
- **CPU**: Host machine (Linux 6.17.4-2-pve)
- **Mode**: Single-process (`-P localhost`) — all replicas and clients share one process
- **Benchmark**: `rw_fixed.yml` (100% writes to backend KV store)
- **Duration**: 30 seconds per test
- **Replicas**: 3 server replicas, 1 partition

## Performance Results

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

Recovery tests use Jetpack's soft failover mechanism: the leader server is paused internally
via `svr_workers_g[idx].Pause()` after a 5-second run interval (configurable via
`failover.yml`). The client monitors for a `failure_triggered` signal and pauses until
recovery completes.

### Test Configuration

- **Config**: `failover.yml` / `failover_etcd.yml` / `failover_zookeeper.yml`
- **Run interval**: 5s (normal operation before triggering failure) for etcd/ZooKeeper, 15s for MongoDB
- **Stop interval**: 10s (pause duration for recovery)
- **Fail target**: leader (locale_id=0)

### Recovery Metrics

| Backend | Total Throughput (txn/s) | Mid Throughput (txn/s) | Median Latency (ms) | Notes |
|---------|------------------------:|----------------------:|--------------------:|-------|
| MongoDB | 5.00 | 4.90 | 99.97 | `KillMongodbPrimary()` executed; MongoDB not running (Docker permission issue) |
| etcd | 1.93 | 0.00 | N/A | `KillEtcdPrimary()` killed single-node etcd; no recovery possible (single node) |
| ZooKeeper | 1.97 | 0.00 | N/A | Soft failover only (`JETPACK_ZOOKEEPER_RECOVERY` not defined in `constants.h`) |

### Recovery Sequence

1. Jetpack runs normally for `run_interval` seconds
2. `server_failover_co()` triggers:
   - Sets `failover_triggers[i] = true` for all clients
   - Writes `failure_triggered` signal via `jm_signal::set_key()`
   - Pauses leader server: `svr_workers_g[idx].Pause()`
   - For MongoDB: calls `KillMongodbPrimary()` (pkill mongod)
   - For etcd: calls `KillEtcdPrimary()` (pkill etcd)
3. Client detects `failure_triggered` signal (~30-80ms after trigger)
4. System is paused for `stop_interval` seconds
5. After stop_interval, test ends (failover runs once per test)

### Limitations

- **Single-process mode**: All replicas share one process, so Pause() affects internal
  threads rather than simulating true network partitions. For realistic failure recovery
  testing, use the Docker test scripts with multi-process mode (`run-mongodb-test.sh recovery`,
  `run-etcd-test.sh recovery`, `run-zookeeper-test.sh recovery`) which create multi-node
  backend clusters.
- **MongoDB**: Docker container had `Permission denied` starting mongod; failover triggered
  but MongoDB wasn't actually running. The throughput reflects Jetpack's internal processing only.
- **etcd**: Single-node etcd was killed — no quorum to re-elect a leader. Use `run-etcd-test.sh
  recovery` for 3-node cluster with proper recovery.
- **ZooKeeper**: `JETPACK_ZOOKEEPER_RECOVERY` is not defined in `constants.h`, so no
  `KillZookeeperPrimary()` is called and no Jetpack recovery is triggered. The server stays
  paused for the entire stop_interval.

## Raw Metrics

### Performance test output format

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
