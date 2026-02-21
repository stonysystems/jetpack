# Failure Recovery Evaluation Methodology

This document describes how to evaluate failure recovery downtime for Jetpack and its
backend protocols (etcd, MongoDB, ZooKeeper). It covers what to measure, which
timestamps/log lines to use, and how to distinguish each recovery phase.

## Recovery Phases

A failure recovery test has three distinct phases:

1. **Leader Kill** — The test script kills the backend protocol's leader/primary process.
2. **Backend Re-election** — The backend's remaining nodes detect the failure and elect
   a new leader. This is the **original protocol downtime**.
3. **Jetpack Recovery** — Once the backend has a new leader, Jetpack detects the change
   (via signal file) and performs its own recovery. This is the **Jetpack downtime**.

```
Timeline:
  T_kill                T_new_leader              T_jetpack_done
    |--- backend downtime ---|--- Jetpack downtime ---|
```

## How Each Phase Is Measured

### T_kill: Leader Kill Timestamp

Captured in each script immediately before calling the kill function:

```bash
kill_ns=$(date +%s%N)       # nanosecond timestamp
kill_<backend>_node "$leader_ip"
```

### T_new_leader: Backend Re-election Complete

**etcd**: `wait_etcd_new_leader()` polls surviving nodes with `etcdctl endpoint status`
until a node reports itself as Raft leader (`raft_leader == member_id`), excluding the
killed IP. Elapsed time from `kill_ns` = etcd downtime.

**MongoDB**: `wait_mongodb_new_primary()` polls surviving nodes with `rs.status()` until
a member reports `stateStr === "PRIMARY"` and it's not the killed IP. Elapsed time from
`kill_ns` = MongoDB downtime.

**ZooKeeper**: `wait_zookeeper_new_leader()` polls surviving nodes with the `srvr`
four-letter command until one reports `Mode: leader`, excluding the killed IP. Elapsed
time from `kill_ns` = ZooKeeper downtime.

### T_jetpack_done: Jetpack Recovery Complete

After the backend elects a new leader, the script writes a signal file:

```bash
echo "<backend>:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
```

Jetpack's recovery hooker (in `src/deptran/jm_file_signal.h`) polls for this file. When
found, it triggers `JetpackRecoveryEntry()`, which performs Jetpack's internal recovery
(re-establish leadership, replay log, etc.).

Recovery completion is detected by polling for either:
- The signal file `/tmp/JM_Jetpack_recovery_finish_after_failure`, or
- The log line matching `JETPACK-RECOVERY.*COMPLETED` in server output.

Jetpack downtime = T_jetpack_done - T_new_leader (i.e., from signal file write to
recovery completion detection).

## How Leader Identity Is Verified Before Kill

Each script dynamically identifies the actual leader (not hardcoded):

| Backend    | Detection Method                                                |
|------------|----------------------------------------------------------------|
| etcd       | `etcdctl endpoint status -w json`: `raft_leader == member_id`  |
| MongoDB    | `mongosh rs.status()`: member with `stateStr === "PRIMARY"`    |
| ZooKeeper  | `echo srvr \| nc`: node with `Mode: leader`                   |

All kill by targeted PID from the cluster PID array (not `pkill`), ensuring only the
leader process is killed while followers remain running.

## Key Log Lines and Signal Files

### Signal Files (in `/tmp/`)

| File                                       | Written By   | Meaning                           |
|-------------------------------------------|-------------|-----------------------------------|
| `JM_Jetpack_failure_triggered`            | Test script  | Leader kill has been triggered     |
| `JM_Jetpack_0.0.0.0`                     | Test script  | Backend re-election complete       |
| `JM_Jetpack_recovery_finish_after_failure`| Jetpack      | Jetpack recovery complete          |

### Jetpack Server Log Lines

| Pattern                            | Meaning                                 |
|-----------------------------------|-----------------------------------------|
| `JETPACK-RECOVERY STARTING`      | Jetpack detected signal, beginning recovery |
| `JETPACK-RECOVERY.*COMPLETED`    | Jetpack recovery finished               |
| `JetpackRecoveryEntry`           | Entry point of Jetpack's recovery code  |

### Backend-Specific Indicators

**etcd**: `etcdctl endpoint status` shows new leader ID after election.

**MongoDB**: `rs.status()` shows new PRIMARY member after election. MongoDB logs show
`transition to primary complete; database writes are now permitted`.

**ZooKeeper**: `srvr` command shows `Mode: leader` on new leader. ZK source code writes
signal file after `setZabState(BROADCAST)` in `Leader.java:lead()`.

## Interpreting Results

| Metric                      | Typical Range     | Notes                              |
|----------------------------|------------------|------------------------------------|
| etcd Raft election         | ~6.0-6.3s        | Default election timeout           |
| MongoDB replica set election| ~10.6s           | Default `electionTimeoutMillis`    |
| ZooKeeper ZAB election     | ~0.5-1.1s        | Fast Leader Election (FLE)         |
| Jetpack internal recovery  | ~106-281ms       | Independent of backend choice      |

Jetpack's recovery time is dominated by its own protocol work (log replay, leadership
re-establishment) and is largely independent of which backend is used.

## RTT-Based Sanity Check for Jetpack Recovery Downtime

### Jetpack Recovery Protocol: RTT Count

Jetpack's recovery protocol (`JetpackRecovery()` in `src/deptran/scheduler.cc`) performs
two sequential parallel-broadcast rounds:

```
T_signal_detected
    |
    +--- [Hooker polling delay: 0-P ms, P = poll interval]
    |
    +--- Round 1 (parallel): PullRecovery + Prepare RPCs
    |      Duration: 1 RTT (bottlenecked by the slower of the two)
    |
    +--- Round 2 (parallel): RecordCmd + Accept RPCs
    |      Duration: 1 RTT (bottlenecked by the slower of the two)
    |
T_recovery_complete
```

**Total Jetpack downtime (RTT-based lower bound)**:

```
T_jetpack = poll_delay + RTT_round1 + RTT_round2
           >= (0 to P ms) + 1 RTT + 1 RTT
           = polling_delay + 2 x RTT
```

### Expected Downtime with RTT = 40ms

The benchmark environment uses 20ms one-way latency (RTT = 40ms) via tc/netem
(see `result.md`). Applying this to the recovery formula:

| Component | Duration |
|-----------|---------|
| Polling delay (avg, 1ms poll interval) | ~0.5ms |
| Round 1: PullRecovery + Prepare (parallel) | ~40ms |
| Round 2: RecordCmd + Accept (parallel) | ~40ms |
| **Expected total** | **~81ms** |

With the original 10ms poll interval, polling delay averages 5ms -> expected ~85ms.

**For WAN deployments with RTT = 40ms, Jetpack recovery should take approximately 80-90ms.**

### Measured vs Expected: Gap Analysis

The recovery tests were run in a single-process Docker environment (all 3 Jetpack
replicas in one process, 127.0.0.1-3 loopback - effectively 0ms RTT).

**Predicted with 0ms RTT**:
- Expected: polling_delay + 0 + 0 = 0-10ms (with 10ms hooker poll)

**Observed** (from Jetpack internal `duration=` log, 0ms RTT environment):

| Backend | Script-reported | Internal duration | Expected (0 RTT) | Gap |
|---------|---------------:|------------------:|----------------:|----:|
| etcd | 4ms | 3ms | 0-10ms | none |
| ZooKeeper | 106ms | 1ms | 0-10ms | none (script artifact) |
| MongoDB | 143ms | 95ms | 0-10ms | **85ms gap** |

### Root Cause of Gaps

#### ZooKeeper: Script measurement artifact (100ms poll)

The ZooKeeper internal recovery completed in **1ms**, but the test script detected
it **106ms** after the signal. This is not a real downtime gap - the test script
was polling the recovery-finish signal every **100ms** (`sleep 0.1`), so the
worst-case measurement inflation is +100ms.

**Fix**: Reduce test script poll interval from 100ms to 10ms -> maximum measurement
inflation drops from +100ms to +10ms.

#### etcd: No significant gap

Internal recovery was 3ms. Script detected at 4ms. Near-optimal for 0ms RTT.
The etcd case shows the protocol works correctly when the reactor is lightly loaded.

#### MongoDB: True 95ms recovery overhead (significant gap)

Internal recovery (`JetpackRecoveryEntry` total) took **95ms** even with 0ms RTT.
This is a real performance issue independent of network latency.

**Root cause**: The Jetpack event reactor runs on a single event loop shared by:
1. Jetpack protocol RPC handling (PullRecovery, Prepare, RecordCmd, Accept)
2. MongoDB client I/O (reconnecting to new primary after failover)

After MongoDB leader failover, the mongocxx driver's SDAM (Server Discovery and
Monitoring) thread triggers reconnection, which generates I/O events in the Reactor.
This reactor congestion delays the in-process recovery RPC coroutines, making them
take 95ms instead of near-zero.

**Evidence**: ZooKeeper and etcd recover in 1-3ms (reactor is free), while MongoDB
takes 95ms (reactor congested by driver reconnection). The gap is proportional to
MongoDB's reconnection overhead (~100ms for SDAM to fully stabilize).

### Fixes Applied

| Component | Before | After | Latency Saved |
|-----------|--------|-------|--------------|
| Hooker poll interval | 10ms | 1ms | ~4.5ms avg polling delay |
| Test script poll interval | 100ms | 10ms | up to 90ms measurement artifact |
| MongoDB reactor congestion | 95ms | (open, needs async I/O separation) | ~85ms potential |

**Hooker poll fix** (`src/deptran/etcd/server.h`, `mongodb/server.h`, `zookeeper/server.h`):
Reduces average signal detection delay from 5ms to 0.5ms. With RTT=40ms, total
expected recovery time improves from ~85ms to ~81ms.

**Script poll fix** (`docker/*/run-*-test.sh`):
Reduces measurement noise. ZooKeeper now reports actual ~1ms recovery (not ~100ms).

**MongoDB reactor fix (future work)**:
The 95ms overhead from MongoDB reconnection during recovery is the dominant gap
for MongoDB-backed deployments. Potential fixes:
1. Separate MongoDB client I/O onto a dedicated thread, isolating it from the
   Jetpack protocol reactor.
2. Pre-warm the MongoDB connection pool before triggering `JetpackRecoveryEntry`.
3. Add an explicit wait for MongoDB SDAM stabilization before starting recovery
   RPCs (at the cost of slightly longer total downtime).

Until this is fixed, MongoDB deployments should expect ~95ms overhead on top of
the RTT-derived floor (~80ms at RTT=40ms), for approximately **175ms total**
Jetpack downtime in WAN conditions.

### Post-Fix Expected Results

After rebuilding the Docker images with the 1ms hooker poll interval:

| Backend | Expected Jetpack downtime (0ms RTT) | Expected (40ms RTT) |
|---------|-----------------------------------:|--------------------:|
| etcd | ~1-2ms | ~81ms |
| ZooKeeper | ~1-2ms | ~81ms |
| MongoDB | ~95ms (reactor congestion) | ~175ms |

## Running Recovery Tests

```bash
# etcd
docker/etcd/run-etcd-test.sh recovery

# MongoDB
docker/mongodb/run-mongodb-test.sh recovery

# ZooKeeper
docker/zookeeper/run-zookeeper-test.sh recovery
```

Each test prints a summary with backend downtime and Jetpack downtime in milliseconds.
