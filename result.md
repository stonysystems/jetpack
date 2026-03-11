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

### Claim Status and Sources (Benchmark Throughput/Latency)

- `artifact-backed`:
  - accepted high-concurrency and peak-throughput tables in this section
  - source: `docs/sweep_2026-02-28/*.tsv`
- `rerun-confirmed`:
  - low-concurrency rerun ranges and mismatch assessments
  - source: `docs/phase1d_low_concurrency_runs.md`
- `historical context`:
  - old published baseline values shown for contrast in low-concurrency tables
  - legacy baseline sections later in this file (`5 replicas`, `3 replicas`)
- `still open`:
  - MongoDB low-concurrency absolute mismatch vs the old published baseline

### Low-concurrency latency comparison (1 client per process, concurrency=1)
Claim status: `rerun-confirmed` (with `still open` MongoDB absolute mismatch).

All backends run as **3-node clusters** (etcd Raft cluster, ZooKeeper ZAB ensemble,
MongoDB replica set with `w:majority`), so backend write latency includes the backend's
own replication RTT (~40ms via tc/netem).

Published values below are the 2026-03-02 baseline from earlier reruns. The right column
shows the 2026-03-10 runbook-path rerun (3 attempts per case, 18 runs total).

| Case | Published h1/h2-h5 (ms) | 2026-03-10 rerun h1/h2-h5 (range, median) | Assessment |
|---------|---:|---:|---|
| etcd OFF | 43.6 / 83.7 | 22.64-42.79 (42.59) / 62.65-82.86 (82.66) | Supporting overall with one low-latency outlier |
| etcd ON | 40.4 / 40.7 | 22.65-40.26 (22.78) / 40.41-40.42 (40.42) | `h2-h5` aligns; `h1` is bimodal |
| MongoDB OFF | 47.7 / 88.0 | 7.12-7.28 (7.27) / 46.15-46.53 (46.27) | Material mismatch vs published absolute values |
| MongoDB ON | 45.2 / 45.9 | 7.33-7.76 (7.45) / 41.39-41.49 (41.44) | Material mismatch vs published absolute values |
| ZooKeeper OFF | 45.5 / 86.0 | 42.68-43.23 (42.78) / 82.83-83.41 (82.89) | Supporting with mild downward drift |
| ZooKeeper ON | 40.3 / 40.5 | 40.25-40.27 (40.26) / 40.35-40.35 (40.35) | Supporting and stable |

Source for rerun evidence: `docs/phase1d_low_concurrency_runs.md`.

### High-concurrency comparison (c=200, accepted canonical pass)
Claim status: `artifact-backed`.

| Backend | Jetpack OFF (original) | Jetpack ON (adaptive) |
|---------|---:|---:|
| etcd | 7,605 txn/s | 7,369 txn/s |
| MongoDB | 3,867 txn/s | 3,591 txn/s |
| ZooKeeper | 5,140 txn/s | 5,018 txn/s |

### Maximum throughput (best concurrency from accepted canonical pass)
Claim status: `artifact-backed`.

| Backend | Jetpack OFF (original) | | Jetpack ON (adaptive) | |
|---------|---:|---:|---:|---:|
| | Concurrency | Max (txn/s) | Concurrency | Max (txn/s) |
| etcd | c=150 | 7,743 | c=200 | 7,369 |
| MongoDB | c=75 | 4,298 | c=75 | 3,873 |
| ZooKeeper | c=150 | 5,564 | c=150 | 5,427 |

*Data source: `docs/sweep_2026-02-28/*.tsv` (refreshed from accepted pass `results/reproduce_20260310_164201/sweep/`, build commit `ff81e913`).*

### Observations (open-loop, Jetpack ON vs OFF, 3-node backend clusters)

- `rerun-confirmed`: **etcd and ZooKeeper OFF-mode reruns remain consistent** with the expected `h2-h5 ~= h1 + 40ms`
  model, with one etcd absolute-latency outlier.
- `rerun-confirmed`: **Jetpack ON behavior diverges by backend in the rerun set**:
  - ZooKeeper ON is stable near `~40ms` for both leader and non-leader clients.
  - etcd ON keeps stable `h2-h5 ~40.4ms` and `100%` fast-path success, but `h1` is bimodal.
  - MongoDB ON keeps `100%` fast-path success but its absolute latencies are materially lower
    than the previously published table values.
- `still open`: **MongoDB low-concurrency absolute values are currently non-supporting** relative to the
  old published baseline and are tracked as updated rerun evidence in
  `docs/phase1d_low_concurrency_runs.md`.
- `artifact-backed`: **Maximum throughput (accepted pass)**: etcd remains fastest (~7.7K off, ~7.4K adaptive),
  ZooKeeper is moderate (~5.6K off, ~5.4K adaptive), MongoDB is lower (~4.3K off, ~3.9K adaptive).
- `artifact-backed`: **Jetpack ON throughput** is lower than OFF at peak in this accepted pass for all three
  backends (etcd −4.8%, MongoDB −9.9%, ZooKeeper −2.5%).
- `rerun-confirmed`: **Tail sensitivity**: peak magnitudes are relatively stable, but c300/c400 tail shape is
  environment-sensitive (especially MongoDB and etcd FP100), so peak/near-peak ranges are
  more reliable than a single tail point.

## Performance Results (5 replicas, historical context)

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

## Multi-Process Results (5 replicas, 5ms network latency, historical context)

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

## Performance Results (3 replicas, baseline historical context)

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

### Claim Status and Sources (Failure Recovery)

- `artifact-backed`:
  - accepted WAN recovery matrix values in this section
  - source:
    - `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md`
    - `docs/phase1f_wan_recovery_20260311/*_wan_r*.txt`
- `rerun-confirmed`:
  - RTT-model interpretation (`1ms poll + 2*RTT`) applied to accepted WAN internal
    `duration=` values at `RECOVERY_LATENCY_MS=20` (20ms one-way, RTT=40ms)
- `historical context`:
  - pre-fix Run A / Run B gap-analysis trail and projections retained for diagnostic context
  - sources: `docs/logs/*_recovery_gap_fix_wan_r*.txt`, `docs/*_recovery_v2.txt`
- `still open`:
  - no open claim in accepted WAN internal-duration metrics; script-detected downtime
    remains a separate, detection-path-dependent metric

### Recovery Architecture

Recovery testing uses an **external kill approach**: the test script (not Jetpack's
internal `server_failover_co()`) kills the backend leader by PID and writes signal
files. This simulates a real backend failure with actual leader election.

Recovery measures two phases:
1. **Original protocol downtime**: from SIGKILL of the leader to the new leader being
   elected (detected by the test script polling the backend cluster)
2. **Jetpack script-detected downtime**: from `primary_elected` signal file write to
   script detection of recovery completion (`recovery_finish_after_failure` signal or
   completion log match)

For RTT-model comparison, use a separate metric:
- **Jetpack internal recovery duration**: in-process `duration=...ms` from
  `JETPACK-RECOVERY.*COMPLETED`.

Signal file path: `/tmp/JM_Jetpack_0.0.0.0` (due to `#define AWS` in constants.h).
Non-leader Jetpack servers poll this file every 1ms and trigger `JetpackRecoveryEntry()`
when the signal is detected (reduced from original 10ms poll interval).

### WAN Recovery Test Results (post-fix, RTT=40ms)

Claim status: `artifact-backed` for table values; `rerun-confirmed` for RTT-model interpretation.

WAN mode runs 3 separate OS processes (h1=127.0.0.1, h2=127.0.0.2, h3=127.0.0.3)
with tc/netem adding 20ms one-way delay (RTT=40ms). Config: `config/1c1s3r1p_wan.yml`.

| Backend (rep) | Backend downtime (script) | Jetpack script-detected downtime | Jetpack internal `duration=` | Expected internal | Status |
|---|---:|---:|---:|---:|---|
| etcd (r1) | 6568ms | 4ms | 82ms | 81ms | PASSED |
| etcd (r2) | 6729ms | 4ms | 81ms | 81ms | PASSED |
| etcd (r3) | 6817ms | 3ms | 82ms | 81ms | PASSED |
| MongoDB (r1) | 23209ms | 92ms | 83ms | 81ms | PASSED |
| MongoDB (r2) | 10741ms | 88ms | 83ms | 81ms | PASSED |
| MongoDB (r3) | 21684ms | 92ms | 82ms | 81ms | PASSED |
| ZooKeeper (r1) | 774ms | 83ms | 81ms | 81ms | PASSED |
| ZooKeeper (r2) | 800ms | 82ms | 82ms | 81ms | PASSED |
| ZooKeeper (r3) | 773ms | 83ms | 81ms | 81ms | PASSED |

RTT-model comparison uses only Jetpack internal `duration=`:
expected = 1ms poll delay + 2x40ms RTT = 81ms.
All 9 internal values are within +/-2ms of 81ms.
Consolidated source: `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md`.

Note: etcd election time in this accepted pass is stable at ~6.6-6.8s;
ZooKeeper remains consistently fast (~0.77-0.80s) due to ZAB's Fast Leader Election.

### Observations

- **ZooKeeper has the fastest backend re-election** (~0.8s), consistent with ZAB's
  fast leader election algorithm designed for low-latency failover.
- **etcd leader election** in this accepted pass is ~6.6-6.8s, reflecting Raft election
  variability and retry timing.
- **MongoDB replica-set election is slowest and most variable** in this accepted pass
  (~10.7-23.2s), consistent with longer election timeout behavior.
- **Jetpack internal recovery duration is consistently 81-83ms** across all backends at
  RTT=40ms, matching the 2-RTT lower bound (1ms poll + 2x40ms). This confirms the recovery
  protocol complexity is exactly 2 sequential broadcast rounds regardless of backend choice.
- **Jetpack script-detected downtime is not the RTT-comparison metric**; it reflects the
  script detection path and is reported separately.
- **MongoDB required a URI fix**: the original code built a comma-separated URI without
  `replicaSet=jetpack-rs`, so the mongocxx driver couldn't failover to surviving nodes.
- **ZooKeeper required enabling recovery**: `JETPACK_ZOOKEEPER_RECOVERY` was not defined
  in `constants.h`. Adding the define enabled the signal polling code in `zookeeper/server.h`.
- **WAN mode required two bug fixes** (see sanity check section below for details):
  server-only process lifetime fix (`s_main.cc`) and MongoDB non-leader connection fix
  (`mongodb/server.h`).

### RTT-Based Sanity Check and Gap Analysis

> **Sanity Check Status: PASSED**
>
> Expected Jetpack internal recovery duration at RTT=40ms: **~81ms** (1ms poll + 2x40ms).
> All three backends measured at RTT=40ms (20ms one-way via tc/netem) in WAN mode
> (3 separate OS processes on loopback IPs 127.0.0.1–3). Each backend run 3 times.
> All results within ±2ms of the expected 81ms.
>
> **Accepted WAN rerun pass (RTT=40ms, 3 reps each):**
>
> | Backend | Rep 1 | Rep 2 | Rep 3 | Expected | Status |
> |---------|------:|------:|------:|---------:|--------|
> | etcd | 82ms | 81ms | 82ms | 81ms | PASS |
> | MongoDB | 83ms | 83ms | 82ms | 81ms | PASS |
> | ZooKeeper | 81ms | 82ms | 81ms | 81ms | PASS |
>
> Root causes previously blocking this check:
> 1. **Server-only process lifetime bug**: Non-client h2/h3 processes exited after ~16s
>    because `s_main.cc` only called `sleep(duration_)` in the client branch. Fixed by
>    adding `else if (!server_infos.empty())` branch with `sleep(Config::GetConfig()->duration_)`.
> 2. **MongoDB non-leader connection flood**: In WAN mode with 3 processes, all 3 created
>    80 MongoDB connections each (240 total), overwhelming mongod. Fixed by applying
>    `loc_id_ == 0 ? mongodb_connection_ : 0` in the `JETPACK_MONGODB_RECOVERY` branch.

#### Protocol: 2 RTT rounds

Jetpack recovery requires **2 sequential RTT rounds** (each round sends parallel broadcasts):
- Round 1: PullRecovery + Prepare (parallel) → 1 RTT
- Round 2: RecordCmd + Accept (parallel) → 1 RTT

Plus a signal polling delay of 0–P ms (P = hooker poll interval).

**Expected Jetpack internal recovery duration = polling_delay + 2 x RTT**

With RTT = 40ms (benchmark environment): 0.5ms + 40ms + 40ms = **~81ms** (1ms poll) or
~85ms (10ms poll). This is the theoretical floor for internal recovery duration.

#### Historical context: Results with RTT ≈ 40ms (original run, tc/netem active)

The following numbers were measured in an environment where tc/netem latency (20ms one-way)
was active between Jetpack replicas, consistent with the WAN benchmark setup:

| Backend | Protocol Downtime | Jetpack script-detected downtime | Jetpack internal duration | vs Expected ~81ms |
|---------|------------------:|----------------:|------------------:|------------------:|
| etcd | ~6.0–6.3s | ~106–107ms | ~124–128ms | **+43ms gap** |
| ZooKeeper | ~0.5–1.1s | ~106ms | ~123–124ms | **+42ms gap** |
| MongoDB | ~10.6s | ~159–281ms | ~162–184ms | **+81–103ms gap** |

These numbers are from the initial test run and serve as the pre-fix baseline.

#### Historical context: Results at 0ms RTT (single-process Docker)

After fixing the test script detection poll from 100ms → 10ms:

| Backend | Protocol Downtime | Jetpack script-detected downtime | Jetpack internal duration | Expected (0ms RTT) | Gap |
|---------|------------------:|----------------:|------------------:|-------------------:|----:|
| etcd | ~1.1s | **3ms** | **1ms** | ~0.5ms | none |
| ZooKeeper | ~0.5s | **16ms** | **1ms** | ~0.5ms | ~15ms (script poll artifact) |
| MongoDB | ~10.3s | **94ms** | **60ms** | ~0.5ms | **~60ms (SDAM reactor)** |

Note: ZooKeeper 16ms = 10ms script poll granularity + 6ms overhead. Internal = 1ms (correct).

#### Historical context: Gap analysis (etcd/ZooKeeper at RTT=40ms, initial run)

At RTT=40ms, etcd and ZK showed ~123–128ms internal duration vs expected 81ms — a ~42–47ms gap.

**Breakdown hypothesis** (not yet fully diagnosed):
- Expected 2×RTT: 80ms
- Additional overhead: ~43–48ms — likely from Jetpack reactor scheduling latency and
  coroutine dispatch delay when the RPC completes. At 0ms RTT this overhead is hidden
  (recovery completes in 1ms total), but at 40ms RTT the coroutine scheduling adds up.

**Historical status at initial-run time**: root cause not yet confirmed; later accepted WAN reruns
show internal durations at 81-83ms.

#### Historical context: Gap analysis (MongoDB at RTT=40ms, initial run)

MongoDB shows ~162–184ms internal vs expected ~81ms — a ~81–103ms gap on top of the RTT.

**Root cause**: The Jetpack event reactor is congested by MongoDB driver (mongocxx) SDAM
reconnection events after leader failover. The SDAM background thread triggers server
discovery, generating I/O events that compete with Jetpack's recovery RPC coroutines.
This is not a network latency issue but a reactor contention issue specific to MongoDB.

- At 0ms RTT: 60–95ms overhead (reactor congestion only)
- At 40ms RTT: additional 80ms RTT → total ~140–175ms (confirmed ~162–184ms)

**Comparison**: etcd and ZooKeeper recover in 1ms at 0ms RTT because their reconnection
overhead is minimal or handled separately, leaving the Jetpack reactor free.

#### Historical context: Projection to WAN (RTT=40ms, pre-fix target)

| Backend | 0ms RTT internal | Expected at 40ms RTT | Sanity check target |
|---------|----------------:|---------------------:|--------------------:|
| etcd | ~1ms | ~81ms | ≤100ms |
| ZooKeeper | ~1ms | ~81ms | ≤100ms |
| MongoDB | ~60–95ms | ~141–175ms | pre-fix target (superseded by accepted WAN rerun at 81-83ms) |

### Historical context: Recovery Test Raw Output (v2: 10ms script poll)

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
