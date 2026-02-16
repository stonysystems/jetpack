# Benchmark Latency Analysis

## Summary

With `SIMULATE_WAN` disabled and tc/netem providing 20ms one-way network latency, the
expected latencies are:

- **Jetpack OFF (original protocol)**: ~2 RTT ≈ **80ms** (client → leader → replicas → leader → client)
- **Jetpack ON (fast path)**: ~1 RTT ≈ **40ms** (client broadcasts to all, waits for quorum)

Any significant deviation from these targets indicates a bug in the benchmark setup.

## Latency Simulation: tc/netem Only

The Docker benchmark uses **tc/netem** (kernel-level) to add 20ms one-way delay between
loopback IPs (127.0.0.2–5). Server h1 (127.0.0.1) has no tc delay. This simulates
inter-server network latency.

### SIMULATE_WAN Must Be Disabled

The `SIMULATE_WAN` macro (`src/deptran/constants.h`) adds 20ms `WAN_WAIT` software sleeps
at multiple code points (client send, client callback, server submit before/after). These
were originally intended to simulate backend access latency when running without tc/netem.

**When using tc/netem, `SIMULATE_WAN` must be commented out** — otherwise the software delays
are additive to the kernel-level delays, roughly doubling all latencies and producing
misleading results.

```cpp
// src/deptran/constants.h
// #define SIMULATE_WAN   // <-- MUST be commented out for tc/netem benchmarks
```

---

## Expected Latency Model

### None Mode (Jetpack OFF): ~2 RTT ≈ 80ms

The original protocol path requires the client to send to the leader, the leader to
replicate to a quorum of replicas, and then respond to the client. This is 2 network
round trips through the tc/netem delay.

```
Client h1 → Leader h1 (local, ~0ms)
Leader h1 → Replicas h2-h5 (20ms one-way) → wait for quorum
Replicas respond (20ms return) → 1 RTT = 40ms
Leader h1 → Client h1 (local, ~0ms)
Total consensus RTT: ~40ms
+ Backend I/O RTT (backend also goes through consensus): ~40ms
= ~80ms total (2 RTT)
```

### Rule Mode (Jetpack ON): ~1 RTT ≈ 40ms

The Jetpack fast path broadcasts the speculative execution request to all replicas and
waits for a quorum to respond. This needs only 1 network round trip.

```
Client h1 → broadcast to all replicas (h1: 0ms, h2-h5: 20ms one-way)
Wait for 3/5 quorum: h1 responds immediately, h2+h3 respond after 40ms RTT
Total: ~40ms (1 RTT)
```

---

## Current Results (SIMULATE_WAN disabled)

### Low-Concurrency Sanity Check (1 client, concurrency=1)

| Setting | Expected | Actual | Status |
|---|---|---|---|
| MongoDB A (off, 1c) | ~80ms (2 RTT) | 46.65ms | **FAIL** — too low |
| MongoDB C (on, 1c) | ~40ms (1 RTT) | 44.80ms | OK |
| etcd A (off, 1c) | ~80ms (2 RTT) | 2.65ms | **FAIL** — way too low |
| etcd C (on, 1c) | ~40ms (1 RTT) | 7.88ms | **FAIL** — too low |
| ZooKeeper A (off, 1c) | ~80ms (2 RTT) | 89.60ms | OK |
| ZooKeeper C (on, 1c) | ~40ms (1 RTT) | 40.43ms | OK |

### Known Issues

**etcd** (2.65ms / 7.88ms): tc/netem latency is not being applied to etcd traffic at all.
Likely causes: etcd client connects via a loopback address not covered by tc/netem rules,
or etcd responds locally without going through the replicated consensus path.

**MongoDB** (46.65ms): Only ~1 RTT instead of expected ~2 RTT. Likely cause: write concern
is w=1 (acknowledged after local write only, no replication wait), or the commit path
skips one network round trip.

**ZooKeeper** (89.60ms / 40.43ms): Passes sanity check. Both off (~80ms) and on (~40ms)
are within expected range.

### High-Concurrency Results (60 clients, concurrency=200)

| Experiment | Median Latency (ms) | Avg Latency (ms) | Throughput (txn/s) |
|---|---:|---:|---:|
| MongoDB Setting B (off) | 5,765 | 5,790 | 1,920 |
| MongoDB Setting D (on) | 6,450 | 6,530 | 2,020 |
| etcd Setting B (off) | 1,780 | 1,810 | 6,626 |
| etcd Setting D (on) | 2,042 | 2,055 | 5,983 |
| ZooKeeper Setting B (off) | 4,058 | 4,062 | 3,034 |
| ZooKeeper Setting D (on) | 4,416 | 4,530 | 2,335 |

High-concurrency latencies are dominated by queuing effects, not network RTT. Throughput
numbers are more meaningful in this regime. These results will be updated after the
low-concurrency sanity check issues are fixed.

---

## History

### Previous Analysis (obsolete)

An earlier version of this document analyzed results with `SIMULATE_WAN` enabled, which
added 4x 20ms `WAN_WAIT` software delays on top of tc/netem. That analysis explained why
Jetpack OFF was ~80ms + backend_IO and Jetpack ON was ~80ms (2 WANs + 1 tc RTT). Those
results and explanations are no longer valid — `SIMULATE_WAN` has been disabled, and the
correct expectations are the simple 2-RTT / 1-RTT model described above.
