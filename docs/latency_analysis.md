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

### Notes

- Each process in the 5-process benchmark setup reports its own latency independently.
  The leader process's client (h1) always has lower latency than follower processes because
  client→leader communication is on the same loopback IP (no tc/netem).
- High-concurrency results are dominated by queuing effects, not network RTT.
- `SIMULATE_WAN` must remain disabled when using tc/netem.

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
