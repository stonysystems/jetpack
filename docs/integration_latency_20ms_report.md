# How Current Integration Tests Simulate 20ms WAN Latency

This report explains the mechanisms Jetpack uses to simulate 20ms one-way
(40ms RTT) WAN latency in its benchmark and failure-recovery test paths,
covering MongoDB, etcd, and ZooKeeper individually.

## Executive Summary

Jetpack uses two distinct latency simulation mechanisms.  The **active
production mechanism** is `tc`/`netem` (Linux traffic control with network
emulation), which adds real kernel-level delay to packets on the loopback
interface.  A **legacy software mechanism** (`SIMULATE_WAN` compile-time
macro) exists in the source but is **disabled** and must not be combined
with `tc`/`netem`.

| Mechanism       | Where           | Status          | Scope                          |
|-----------------|-----------------|-----------------|--------------------------------|
| `tc`/`netem`    | Docker scripts  | **Active**      | Benchmark + WAN recovery tests |
| `SIMULATE_WAN`  | C++ source      | **Disabled**    | Legacy; additive to `tc`       |

**`LATENCY_MS=20` and `RECOVERY_LATENCY_MS=20` are one-way latency settings.
They correspond to RTT = 40ms (20ms outbound + 20ms inbound).**

**`SIMULATE_WAN` and `tc`/`netem` must NOT both be enabled.  They are additive,
not alternative.  Enabling both would produce 40ms one-way / 80ms RTT.**

---

## Mechanism 1: `tc`/`netem` (Active)

### How It Works

Each Docker test script contains a `setup_latency()` function that uses the
Linux `tc` (traffic control) command with the `netem` (network emulation)
qdisc to add real kernel-level delay to packets on the loopback interface.

Servers are bound to separate loopback IPs (127.0.0.1 through 127.0.0.5).
The first IP (127.0.0.1) has no added delay; remaining IPs get `netem`
delay rules.  This means communication between any two servers on different
IPs incurs `LATENCY_MS` one-way delay per hop.

**Simplified `tc` commands generated:**

```bash
# Root qdisc with priority bands
tc qdisc add dev lo root handle 1: prio bands 16 priomap \
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0

# For each server IP (127.0.0.2 through 127.0.0.5):
tc qdisc add dev lo parent 1:2 handle 11: \
    netem delay "20ms" "0ms"
tc filter add dev lo parent 1:0 protocol ip prio 1 u32 \
    match ip dst 127.0.0.2 flowid 1:2
tc filter add dev lo parent 1:0 protocol ip prio 1 u32 \
    match ip src 127.0.0.2 flowid 1:2
```

**Requirements:**
- Docker `--privileged` flag (needed for `tc` and `netem`)
- `iproute2` package installed in container (provides `tc`)

### Environment Variables

| Variable               | Default | Meaning                                |
|------------------------|---------|----------------------------------------|
| `LATENCY_MS`           | 20      | One-way delay for benchmark mode (ms)  |
| `LATENCY_JITTER`       | 0       | Jitter for benchmark mode (ms)         |
| `RECOVERY_LATENCY_MS`  | 0       | One-way delay for recovery mode (ms)   |
| `RECOVERY_LATENCY_JITTER` | 0    | Jitter for recovery mode (ms)          |

---

## Mechanism 2: `SIMULATE_WAN` (Disabled)

### How It Works

When `#define SIMULATE_WAN` is enabled in `src/deptran/constants.h`, the
`WAN_WAIT` macro in `src/deptran/communicator.h` expands to a 20ms software
sleep:

```cpp
// communicator.h
static void _wan_wait() {
    Reactor::CreateSpEvent<NeverEvent>()->Wait(20*1000);  // 20ms
}
#ifdef SIMULATE_WAN
#define WAN_WAIT _wan_wait();
#else
#define WAN_WAIT ;
#endif
```

`WAN_WAIT` is inserted at ~50 call sites across RPC send/receive handlers
for Raft, Paxos, Mencius, CoPilot, and other protocols.  Each invocation
adds a 20ms sleep to simulate network transit time.

### Current Status

**DISABLED** — line 147 of `src/deptran/constants.h`:

```cpp
// #define SIMULATE_WAN   // MUST be commented out for tc/netem benchmarks
```

This macro is disabled because:
1. It is **additive** to `tc`/`netem` — enabling both doubles the latency.
2. Software sleeps do not accurately model real network behavior (queueing,
   reordering, bandwidth constraints).
3. All current Docker test scripts use `tc`/`netem` instead.

---

## Benchmark Tests: How 20ms Latency Is Applied

### Common Pattern (All Three Backends)

All benchmark tests follow the same pattern:

1. Start the backend cluster (MongoDB / etcd / ZooKeeper) on separate
   loopback IPs.
2. Call `setup_latency $LATENCY_MS $LATENCY_JITTER` to apply `tc`/`netem`
   rules.
3. Start Jetpack server processes.
4. Run benchmark clients for `TEST_DURATION` seconds.
5. Call `remove_latency` to clean up `tc` rules.

### MongoDB Benchmarks

**Script:** `docker/mongodb/run-mongodb-test.sh`
**Config:** `config/60c1s5r5p.yml` (5 servers on h1–h5, 60 clients)
**Entry point:**
```bash
docker run --rm --privileged \
    -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 \
    -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_mongodb.yml \
    jetpack-mongodb benchmark
```

**Mechanism:** `tc`/`netem` on 127.0.0.2–127.0.0.5, MongoDB replica set
across all five IPs.  MongoDB replication (oplog sync) and Jetpack RPCs both
traverse the delayed network paths.

### etcd Benchmarks

**Script:** `docker/etcd/run-etcd-test.sh`
**Config:** `config/60c1s5r5p.yml` (5 servers on h1–h5, 60 clients)
**Entry point:**
```bash
docker run --rm --privileged \
    -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 \
    -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_etcd.yml \
    jetpack-etcd benchmark
```

**Mechanism:** `tc`/`netem` on 127.0.0.2–127.0.0.5, etcd Raft cluster
across all five IPs.  etcd Raft heartbeat/log replication and Jetpack RPCs
both traverse the delayed network paths.

### ZooKeeper Benchmarks

**Script:** `docker/zookeeper/run-zookeeper-test.sh`
**Config:** `config/60c1s5r5p.yml` (5 servers on h1–h5, 60 clients)
**Entry point:**
```bash
docker run --rm --privileged \
    -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 \
    -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_zookeeper.yml \
    jetpack-zookeeper benchmark
```

**Mechanism:** `tc`/`netem` on 127.0.0.2–127.0.0.5.  ZooKeeper's
`setup_latency()` additionally applies `netem` delay to the ZAB peer port
so that ZooKeeper's internal replication traffic is also delayed.  Both ZAB
replication and Jetpack RPCs traverse the delayed paths.

---

## Failure-Recovery Tests: How 20ms Latency Is Applied

### Two Modes

Each backend's recovery test has two modes controlled by
`RECOVERY_LATENCY_MS`:

| `RECOVERY_LATENCY_MS` | Mode            | Config               | Latency      |
|------------------------|-----------------|----------------------|--------------|
| 0 (default)            | Single-process  | `1c1s3r1p.yml`       | 0ms RTT      |
| 20                     | WAN mode        | `1c1s3r1p_wan.yml`   | 40ms RTT     |

### WAN Recovery Config

**File:** `config/1c1s3r1p_wan.yml`

```yaml
site:
  server:
    - ["s101:38200", "s201:38201", "s301:38202"]
  client:
    - ["c01"]
process:
  s101: h1    # 127.0.0.1 — no delay
  s201: h2    # 127.0.0.2 — 20ms one-way
  s301: h3    # 127.0.0.3 — 20ms one-way
  c01: h1
host:
  h1: 127.0.0.1
  h2: 127.0.0.2
  h3: 127.0.0.3
```

### MongoDB Recovery

**Script:** `docker/mongodb/run-mongodb-test.sh` (recovery mode)
**Entry point:**
```bash
docker run --rm --privileged \
    -e RECOVERY_LATENCY_MS=20 \
    jetpack-mongodb recovery
```

**Mechanism:** When `RECOVERY_LATENCY_MS > 0`:
1. Uses `1c1s3r1p_wan.yml` (3 servers on separate IPs).
2. Starts 3-node MongoDB replica set.
3. Applies `tc`/`netem` with `RECOVERY_LATENCY_MS` as one-way delay.
4. Starts 3 Jetpack server processes.
5. Kills leader, waits for re-election, writes `primary_elected` signal.
6. Measures recovery time.

When `RECOVERY_LATENCY_MS = 0`: Uses single-process config, no `tc`/`netem`.

### etcd Recovery

**Script:** `docker/etcd/run-etcd-test.sh` (recovery mode)
**Entry point:**
```bash
docker run --rm --privileged \
    -e RECOVERY_LATENCY_MS=20 \
    jetpack-etcd recovery
```

**Mechanism:** Same pattern as MongoDB — `tc`/`netem` applied when
`RECOVERY_LATENCY_MS > 0`, using `1c1s3r1p_wan.yml`.

### ZooKeeper Recovery

**Script:** `docker/zookeeper/run-zookeeper-test.sh` (recovery mode)
**Entry point:**
```bash
docker run --rm --privileged \
    -e RECOVERY_LATENCY_MS=20 \
    jetpack-zookeeper recovery
```

**Mechanism:** Same pattern — `tc`/`netem` applied when
`RECOVERY_LATENCY_MS > 0`, using `1c1s3r1p_wan.yml`.  Additionally includes
ZAB peer port delay rules.

---

## Automation Entry Points

### Sweep Benchmark

**Script:** `scripts/sweep_benchmark.sh`
**Behavior:** Runs a concurrency sweep (1 to 400 clients) with hardcoded
`LATENCY_MS=20` and `LATENCY_JITTER=0`.

### Full Reproduction

**Script:** `scripts/reproduce_evaluation.sh`
**Phases:**
1. **Build:** Fresh Docker images for all backends.
2. **Sanity:** 6 low-concurrency runs (3 repeats each).
3. **Sweep:** 9-case throughput sweep (3 backends × 3 modes).
4. **Recovery:** 3 backends × 3 repeats, with `RECOVERY_LATENCY_MS=20`.

---

## Accepted WAN Recovery Results

From `docs/failure_recovery_evaluation.md`, measured at RTT = 40ms:

**Expected:** Jetpack recovery ≈ 1ms (poll) + 2 × RTT = 81ms

| Backend    | Rep 1 | Rep 2 | Rep 3 |
|------------|------:|------:|------:|
| etcd       |  82ms |  81ms |  82ms |
| MongoDB    |  83ms |  83ms |  82ms |
| ZooKeeper  |  81ms |  82ms |  81ms |

---

## Limitations and Known Gaps

1. **`SIMULATE_WAN` is disabled:** The software-sleep mechanism exists in
   source code (~50 call sites) but is commented out.  If anyone enables it
   without disabling `tc`/`netem`, latency would double.  There is no
   runtime guard preventing this.

2. **`tc`/`netem` requires `--privileged`:** Benchmark and WAN recovery tests
   cannot run in unprivileged containers or standard CI runners without
   elevated permissions.

3. **Benchmark and recovery use different topologies:**
   - Benchmarks: 5 servers, `60c1s5r5p.yml`, delays on 127.0.0.2–5
   - Recovery: 3 servers, `1c1s3r1p_wan.yml`, delays on 127.0.0.2–3
   The recovery topology has fewer replicas, so recovery timing may not
   perfectly match production 5-replica scenarios.

4. **No 3c1s3r1p or 5c1s5r5p CI matrices exist yet:** The TODO requests
   a `3c1s3r1p` `SIMULATE_WAN` CI lane and a `5c1s5r5p` `tc` CI lane.
   Neither is checked in.

5. **Single-process recovery tests (default) use 0ms RTT:** Without
   `RECOVERY_LATENCY_MS=20`, recovery tests run at 0ms RTT, which does
   not reflect WAN conditions.  The default is useful for correctness
   testing but not for latency benchmarking.

6. **No enforcement that `SIMULATE_WAN` and `tc` are mutually exclusive:**
   The `constants.h` comment warns against enabling both, but there is no
   build-time or runtime check that enforces this.
