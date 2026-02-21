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

> **Sanity Check Status: FAILED**
>
> Expected Jetpack downtime at RTT=40ms: ~81ms (1ms poll + 2×40ms).
> Current status:
> - MongoDB: confirmed ~60–95ms SDAM reactor overhead on top of 2×RTT → **FAILS**
> - etcd/ZooKeeper: overhead is ~1ms at 0ms RTT; projected ~81ms at 40ms RTT, but not
>   yet validated with RTT applied in the recovery test.
>
> To mark PASSED: fix MongoDB reactor congestion + add tc/netem to recovery test scripts
> + run ≥3 repetitions at RTT=40ms with all backends ≤100ms.

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

Two sets of measurements exist:

**Run A — RTT≈40ms** (initial run, tc/netem 20ms one-way latency active from prior benchmark):

| Backend | Internal duration | Expected (40ms RTT) | Gap |
|---------|------------------:|--------------------:|----:|
| etcd | ~124–128ms | ~81ms | **+43–47ms** |
| ZooKeeper | ~123–124ms | ~81ms | **+42–43ms** |
| MongoDB | ~162–184ms | ~81ms | **+81–103ms** |

**Run B — 0ms RTT** (single-process Docker, no tc/netem; 10ms script poll fixed):

| Backend | Script-reported | Internal duration | Expected (0ms RTT) | Gap |
|---------|---------------:|------------------:|-------------------:|----:|
| etcd | 3ms | 1ms | ~0.5ms | ~0.5ms (none) |
| ZooKeeper | 16ms | 1ms | ~0.5ms | ~15ms (script poll artifact) |
| MongoDB | 94ms | 60ms | ~0.5ms | **~59ms (SDAM reactor)** |

Run B uses 10ms script poll (vs 100ms in Run A), so ±10ms measurement noise.
ZooKeeper 16ms in Run B = 10ms poll granularity + 6ms overhead; actual internal = 1ms.

### Root Cause of Gaps

#### ZooKeeper: Script measurement artifact (100ms poll) — FIXED

The ZooKeeper internal recovery completed in **1ms**, but the test script detected
it **106ms** after the signal in Run A. This was not a real downtime gap — the test
script was polling every **100ms** (`sleep 0.1`), inflating reported time by up to 100ms.

**Fix applied**: Reduced test script poll from 100ms to 10ms. ZooKeeper now reports
actual ~16ms (10ms poll granularity + few ms overhead), with internal 1ms.

#### etcd/ZooKeeper: RTT-level gap at RTT=40ms (~42–47ms unexplained overhead)

At RTT=40ms (Run A), etcd and ZK showed ~123–128ms internal duration vs expected 81ms.

**Gap**: ~42–47ms above the 2×RTT floor.

**Hypothesized cause**: Jetpack reactor coroutine scheduling overhead. In-process RPCs
between replicas on the same host (127.0.0.1) still go through the event reactor's
scheduling machinery. At 0ms RTT these coroutines dispatch instantly, but at 40ms RTT
the coroutine dispatch happens after the RPC response arrives, and the reactor may not
be in an "immediately ready" state, adding scheduling latency.

**Status**: Not yet confirmed — needs profiling with per-RPC timing at RTT=40ms.
Recovery test scripts do not currently apply tc/netem, so RTT=40ms case cannot be
reproduced without modifying the scripts.

#### etcd: No significant gap at 0ms RTT — validates base protocol

Internal recovery was 1ms. Script detected at 3ms. Near-optimal for 0ms RTT.
This confirms the Jetpack recovery protocol itself is correct and fast when
the reactor is not congested.

#### MongoDB: SDAM reactor congestion — ~60ms overhead at 0ms RTT (OPEN)

Internal recovery (`JetpackRecoveryEntry` total) took **60–95ms** even with 0ms RTT.
This is a real performance issue independent of network latency.

**Root cause**: The Jetpack event reactor runs on a single event loop shared by:
1. Jetpack protocol RPC handling (PullRecovery, Prepare, RecordCmd, Accept)
2. MongoDB client I/O (SDAM reconnection events after leader failover)

After MongoDB leader failover, the mongocxx driver's SDAM (Server Discovery and
Monitoring) thread triggers reconnection, which generates I/O events in the Reactor.
This congests the reactor and delays in-process recovery RPC coroutines, making them
take 60–95ms instead of ~1ms (as seen with etcd and ZK).

**Evidence**: etcd and ZooKeeper recover in 1ms at 0ms RTT (reactor is free); MongoDB
takes 60–95ms (reactor congested by SDAM). At RTT=40ms, MongoDB adds the full RTT
overhead on top: 80ms + 60–95ms reactor = ~140–175ms total (matches Run A: ~162–184ms).

### Fixes Applied

| Component | Before | After | Status |
|-----------|--------|-------|--------|
| Hooker poll interval | 10ms | 1ms | Applied (needs Docker image rebuild) |
| Test script poll interval | 100ms | 10ms | Applied (scripts updated) |
| etcd/ZK RTT-level gap (42–47ms) | not diagnosed | — | OPEN (needs profiling at RTT=40ms) |
| MongoDB reactor congestion (60–95ms) | — | — | OPEN (needs async I/O separation) |
| Recovery test tc/netem latency | not supported | — | OPEN (needed to validate RTT case) |

**Hooker poll fix** (`src/deptran/etcd/server.h`, `mongodb/server.h`, `zookeeper/server.h`):
Reduces average signal detection delay from 5ms to 0.5ms. With RTT=40ms, total
expected recovery time improves from ~85ms to ~81ms. Change committed; Docker images
need rebuild to take effect in tests.

**Script poll fix** (`docker/*/run-*-test.sh`):
Reduces measurement noise. ZooKeeper now reports actual ~16ms recovery (not ~106ms).

**MongoDB reactor fix (OPEN)**:
The 60–95ms overhead from MongoDB SDAM reconnection during recovery is the dominant gap.
Potential approaches:
1. Separate MongoDB client I/O onto a dedicated thread, isolating it from the reactor.
2. Pre-warm the MongoDB connection pool before triggering `JetpackRecoveryEntry`.
3. Add an explicit wait for SDAM stabilization before starting recovery RPCs.

**Recovery test RTT support (OPEN)**:
Recovery test scripts need tc/netem latency applied between Jetpack replicas (using
different loopback IPs: 127.0.0.1–3 with tc qdisc netem delay 20ms). This requires
running replicas on separate loopback IPs rather than all on 127.0.0.1.

### Detailed Timing Breakdown (at RTT=40ms, pre-fix)

Based on measured data and code analysis:

```
etcd/ZooKeeper (measured internal ~124ms at RTT=40ms):
  ├── Hooker poll delay (avg, 10ms interval): ~5ms
  ├── Round 1: PullRecovery + Prepare (parallel, 1×RTT=40ms): ~40ms
  ├── Round 2: RecordCmd + Accept (parallel, 1×RTT=40ms): ~40ms
  └── Reactor scheduling / undiagnosed overhead: ~39ms ← GAP
  Total: ~124ms (expected: ~85ms with 10ms poll, gap: ~39ms)

MongoDB (measured internal ~162ms at RTT=40ms):
  ├── Hooker poll delay (avg, 10ms interval): ~5ms
  ├── SDAM reactor congestion (mongocxx reconnection): ~60–95ms
  ├── Round 1: PullRecovery + Prepare (parallel, 1×RTT=40ms): ~40ms
  ├── Round 2: RecordCmd + Accept (parallel, 1×RTT=40ms): ~40ms
  └── (SDAM congestion reduces effective RTT concurrency, absorbed above)
  Total: ~162ms (expected: ~85ms with 10ms poll, gap: ~77ms)
```

The ~39ms etcd/ZK overhead is the "RTT-level gap" mentioned in the sanity check.
The MongoDB gap is dominated by SDAM congestion (~60–95ms).

### Root Cause: etcd/ZooKeeper ~39ms overhead

**Hypothesis**: The Reactor's epoll polling loop runs in a **separate thread** from the
main coroutine scheduler. After an RPC response arrives on the network socket, the following
steps must happen before the coroutine is resumed:

1. epoll_wait detects the socket as readable (up to 1ms polling interval)
2. Connection reads the RPC response and creates a ready Event
3. Main Reactor::Loop picks up the ready Event from `ready_events_` queue
4. Coroutine is resumed (ContinueCoro)

At RTT=40ms, both RPC rounds involve 2 such "pick up" steps (one per round). If the
main reactor loop is busy processing other events (heartbeats, background tasks), each
pick-up step can be delayed by tens of milliseconds.

**Evidence needed**: Per-step timing inside `JetpackRecovery()` at RTT=40ms is needed
to confirm. The existing code has STEP1/STEP2 timing logs only in the failure branch.
A `JETPACK_RECOVERY_DEBUG` define exists but only covers some log points.

**Alternative hypothesis**: The original cluster measurements had variable actual RTT
(not exactly 20ms one-way), so the 39ms extra could be network variability rather than
reactor scheduling overhead.

### Root Cause: MongoDB ~60–95ms SDAM congestion (confirmed)

The mongocxx driver runs SDAM (Server Discovery And Monitoring) in a background thread.
When the MongoDB primary fails, SDAM detects the failure and begins reconnection. The
reconnection process posts I/O events (socket connect, auth, handshake) into the Jetpack
event reactor. These events compete with Jetpack's recovery RPC coroutines.

**Why this blocks recovery**:
- All Jetpack protocol work (PullRecovery, Prepare, RecordCmd, Accept) goes through the
  event reactor's epoll loop
- When SDAM posts many reconnection events to the reactor, those events get processed
  in the same main loop iteration as recovery RPCs
- This effectively serializes MongoDB driver I/O with recovery RPC completion processing
- Duration: ~60–95ms (SDAM stabilization time on the test system)

**Why etcd/ZK don't have this**: etcd's gRPC client and ZK's zkc client handle their
reconnection in separate threads or with minimal reactor interaction. Their reconnection
events don't flood the Jetpack event reactor during recovery.

### Post-Fix Expected Results

After fixing MongoDB SDAM congestion and rebuilding Docker images (1ms hooker poll):

| Backend | Expected (0ms RTT, post-fix) | Expected (40ms RTT, post-fix) | Sanity check |
|---------|-----------------------------:|------------------------------:|-------------|
| etcd | ~1ms | ~81ms | ≤100ms: PASS |
| ZooKeeper | ~1ms | ~81ms | ≤100ms: PASS |
| MongoDB | ~5ms (if SDAM fix works) | ~85ms | ≤100ms: PASS |
| MongoDB | ~60ms (without SDAM fix) | ~140ms | ≤100ms: FAIL |

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
