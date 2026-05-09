# Raft vs SwiftPaxos: RPC pattern, per-replica work, and throughput trade-off

**Date:** 2026-05-08
**Scope:** Side-by-side breakdown of the wire-level RPC vocabulary and per-replica work for Raft and SwiftPaxos, with the resulting throughput vs latency analysis. References both the published protocols and the implementations in this repo. Companion to the parity work landed in commit `6a1af0b1` ("swiftpaxos: bring to logical parity with imdea-software/swiftpaxos").

---

## 1. Why this comparison

For the camera-ready sweep we want a clear story about where SwiftPaxos sits relative to Raft on the latency-throughput plane. The headline question that came up: "Should SwiftPaxos have a lower max throughput than Raft, given it does more RPCs and more computation per command even on the all-fast-path case?"

Short answer: **yes on LAN/local CPU-bound benchmarks; the picture flips on WAN at moderate concurrency**. The rest of this doc walks through the message-level accounting and the geometry of the bottleneck that gives that answer.

---

## 2. Protocol message vocabulary

### Raft (this repo)

Three RPCs total in the IDL ([src/deptran/rcc_rpc.rpc:114-138](../src/deptran/rcc_rpc.rpc#L114), implementations in [src/deptran/raft/](../src/deptran/raft/)):

| RPC | Sender → Recipient | Carries |
|---|---|---|
| `Vote` (RequestVote) | candidate → all (broadcast, skip self) | `lst_log_idx`, `lst_log_term`, `self_id`, `cur_term` |
| `AppendEntries` | leader → one follower (unicast, one per HeartbeatLoop) | log entry, `prevLogIndex`, `prevLogTerm`, `leaderCommitIndex` (commit index piggybacked) |
| `EmptyAppendEntries` | leader → one follower | heartbeat variant of AE without a payload |

**Send sites:** [src/deptran/raft/commo.cc:80-202](../src/deptran/raft/commo.cc#L80) (AE unicast loop, Vote broadcast). One `HeartbeatLoop` coroutine per follower at the leader ([src/deptran/raft/server.cc:194-197](../src/deptran/raft/server.cc#L194)).

**Client edge:** in this repo the client's submit is a local function call (`RaftServer::Start` at [server.cc:1276](../src/deptran/raft/server.cc#L1276)), not a wire RPC. Same for the reply path.

### SwiftPaxos (this repo, post commit `6a1af0b1`)

Six RPCs total in the IDL ([src/deptran/rcc_rpc.rpc:428-475](../src/deptran/rcc_rpc.rpc#L428), implementations in [src/deptran/swiftpaxos/](../src/deptran/swiftpaxos/)):

| RPC | Sender → Recipient | Carries |
|---|---|---|
| `SwiftPropose` | client → all replicas | command (MarshallDeputy) |
| `SwiftFastAck` | every replica → all other replicas | `replica`, `ballot`, `cmd_id`, `key`, `seqnum`, `dep[]` |
| `SwiftSlowAck` (light) | non-leaders → all other replicas (when leader's FastAck arrives) | `replica`, `ballot`, `cmd_id` (no dep — leader's FastAck supplied it) |
| `SwiftAcks` (batched) | one replica → all peers | `MarshallDeputy` containing `SwiftBatchedAcks` (parallel arrays of FastAcks + LightSlowAcks). Used iff `batch: true` in mode YAML. |
| `SwiftNewLeader` | recovery candidate → all | new ballot |
| `SwiftNewLeaderAck` | replica → candidate | `cballot`, `MarshallDeputy SwiftRecoveryState` (per-cmd phase/dep/payload) |
| `SwiftSync` | new leader → all | `MarshallDeputy SwiftRecoveryState` (merged state from max-cballot subset) |

**Quorums** ([server.h:90-91](../src/deptran/swiftpaxos/server.h#L90)):
- `FastQuorum() = 3*N/4 + 1` (config (C1) from the paper, size-only counter)
- `SlowQuorum() = N/2 + 1` (majority)

For N=5: FQ=4, SQ=3. The leader is in every FQ and every SQ.

---

## 3. Fast-path / slow-path message pattern (SwiftPaxos)

For one command, no contention, no batching, the sequence on the wire (mirroring NSDI'24 paper Figure 1):

**Step 1 — Propagation (1δ).** Client broadcasts `SwiftPropose` to all N replicas. Each replica computes its own `dep` (last cmd on the touched key, [server.cc:31-47](../src/deptran/swiftpaxos/server.cc#L31)) and broadcasts `SwiftFastAck` carrying that dep to the other replicas.

**Step 2 — Fast-path commit (+1δ).** A replica commits a cmd locally when it has received `SwiftFastAck` from every member of a fast quorum (size = FastQuorum()), all reporting the same dep ([CheckCommit at server.cc:282-310](../src/deptran/swiftpaxos/server.cc#L282)). Total client-perceived delay: 2δ.

**Step 3 — Slow-path adoption (+1δ on disagreement).** When a non-leader receives the leader's `SwiftFastAck` and either (a) it disagreed on dep or (b) the slow-path predicate fires, it broadcasts `SwiftSlowAck` (light, no dep) adopting the leader's dep ([MaybeSendLightSlowAck at server.cc:195-244](../src/deptran/swiftpaxos/server.cc#L195)). This is the IMDEA fastAckFromLeader predicate `r.leader() != r.Id && (slow || (fast && neq))`. Slow-path commit fires when `leader_acked && |endorsers of leader_dep| >= SlowQuorum()`, where an endorser is a replica that sent a matching FastAck OR a LightSlowAck. Total delay: 3δ.

**Optional: batched broadcast.** When `batch: true`, `EnqueueFastAck` / `EnqueueLightSlowAck` push to per-server queues that drain on a 1ms-tick coroutine into a single `SwiftAcks` broadcast carrying many cmds' acks. The receiver's `OnBatchedAcks` unpacks back into per-cmd dispatches. Toggle via [config/none_swiftpaxos.yml](../config/none_swiftpaxos.yml) (`batch: false`) vs [config/none_swiftpaxos_batch.yml](../config/none_swiftpaxos_batch.yml) (`batch: true`).

---

## 4. Per-replica RPC accounting (one cmd, no batching, no contention)

For N = 2f+1 replicas, 1 client. Self-sends counted as local (not on wire).

### Raft

| Role | events | breakdown |
|---|---|---|
| Leader | **2N** | 1 Submit IN + (N-1) AE OUT + (N-1) AE-resp IN + 1 Reply OUT |
| Follower | **2** | 1 AE IN + 1 AE-resp OUT |
| Wire total | 4N - 2 | per-cmd messages on the wire |

For **N=5**: leader 10, follower 2, wire 18 (or 10 if client edge is in-process).

### SwiftPaxos (FastAck only — fast path, no LightSlowAck)

| Role | events | breakdown |
|---|---|---|
| Any replica | **2N - 1** | 1 Propose IN + (N-1) FastAck OUT + (N-1) FastAck IN |
| Wire total | N(2N-1)/2 | symmetric per-replica |

For **N=5**: per replica 9, total 22.5 ≈ 25 events on the wire (asymmetric self-skip rounding).

### SwiftPaxos with IMDEA-faithful LightSlowAck (current Janus impl)

Every non-leader broadcasts `SwiftSlowAck` on every leader-FastAck arrival (size-only quorum predicate is true for every non-leader):

| Role | events | breakdown |
|---|---|---|
| Leader | **2N - 1** | 1 Propose IN + (N-1) FastAck OUT + (N-1) FastAck IN + (N-1) LightSlowAck IN |
| Non-leader | **4N - 4** | 1 Propose IN + (N-1) FastAck OUT + (N-1) FastAck IN + (N-1) LightSlowAck OUT + (N-2) LightSlowAck IN |

For **N=5**: leader 13, non-leader 16. Each non-leader does **1.6× the per-cmd RPC work of the Raft leader**.

### With batching (`batch: true`, drain interval 1ms)

If the steady-state batch size is K cmds, each per-cmd wire RPC count drops by ≈K (one `SwiftAcks` envelope replaces K FastAcks/LightSlowAcks). At a saturation throughput of e.g. 5000 cmd/s with 1ms drain → K ≈ 5 → per-replica events drop from 16 to ~3.2 per cmd, comparable to Raft.

---

## 5. Where the bottleneck sits

### Raft is leader-bottlenecked

The leader does ~5× the per-cmd RPC work of any follower (N=5: 10 vs 2). Followers are largely idle. Throughput cap = (leader CPU capacity) / (10 events). Adding more followers does not help — they're already idle; the leader's CPU is the limit.

### SwiftPaxos is symmetric-bottlenecked

Every replica does roughly the same per-cmd work (~9 events FastAck-only, ~16 with LightSlowAck). Throughput cap = (any replica's CPU) / (per-replica events). Saturates uniformly across replicas.

### Implication on equal hardware

If every host has the same CPU capacity C events/sec:

| | events per cmd at the bottleneck node | max throughput |
|---|---|---|
| Raft | 10 (leader) | C/10 |
| SwiftPaxos (FastAck only) | 9 | C/9 |
| SwiftPaxos (with LightSlowAck) | 16 | C/16 |
| SwiftPaxos batched (K=5) | ~3.2 | C/3.2 |

So:
- **Raft beats unbatched SwiftPaxos on LAN max throughput by ~60%**, exactly because per-replica work is higher under IMDEA's "always send LightSlowAck" semantics.
- Batched SwiftPaxos can pull ahead of Raft because the per-cmd RPC count amortizes; but Raft also batches AppendEntries in this codebase ([RAFT_PIPELINE_OPTIMIZATION at server.cc:189](../src/deptran/raft/server.cc#L189)), so the comparison isn't trivial.

---

## 6. Why SwiftPaxos still wins on WAN (geo-replication)

Latency from client perspective:

| | message hops | client-perceived |
|---|---|---|
| Raft | client→leader, leader→follower, follower→leader, leader→client | **4δ** |
| SwiftPaxos (fast path) | client→all replicas, replicas→all peers (and back to client via local replica's commit) | **2δ** |
| SwiftPaxos (slow path) | + one more all-to-all round | 3δ |

In a closed-loop / fixed-concurrency workload, throughput per client = `1 / latency`. On WAN with δ = 30-100ms, the latency advantage compounds: a SwiftPaxos client can issue ~2× more cmds/sec than a Raft client.

Aggregate throughput in the **latency-bound** regime (moderate concurrency):
- Raft: K_clients / 4δ
- SwiftPaxos: K_clients / 2δ ≈ 2× Raft

In the **CPU-bound** regime (saturating concurrency, hits the curves in §5):
- Raft saturates at C/10
- SwiftPaxos saturates at C/16 (unbatched) or C/3.2 (batched)

The IMDEA paper's headline "up to 2.9× throughput vs Paxos" is in the latency-bound regime on multi-region EC2 ([Ryabinin et al., NSDI'24, §5.1](https://www.usenix.org/system/files/nsdi24-ryabinin.pdf), 5 regions, YCSB at moderate concurrency). The paper does not claim to beat Raft on LAN max throughput.

### Where the curves cross

For your sweep configuration (5 regions on AWS, adaptive bisect to find the saturation knee at p90 ≤ 1000ms), the crossover concurrency depends on cross-region δ and per-host CPU budget. Rough prediction:
- At low/moderate concurrency: SwiftPaxos < Raft latency, SwiftPaxos > Raft throughput. Both grow linearly with K_clients.
- At the knee: Raft saturates first if δ is small (LAN-like). SwiftPaxos saturates first if it's CPU-pegged on per-cmd work.
- At and above the knee: Raft sustained higher throughput on equal hardware.

---

## 7. Code map: IMDEA Go ↔ Janus C++

| Concept | IMDEA Go | Janus C++ |
|---|---|---|
| Message structs | `swift/defs.go:53-152` | `src/deptran/rcc_rpc.rpc:428-475` |
| `MFastAck` send | `swift/swift.go:381-406` (`handlePropose`) | [`src/deptran/swiftpaxos/server.cc` `OnPropose`](../src/deptran/swiftpaxos/server.cc) |
| Leader-FastAck handling + LightSlowAck trigger | `swift/swift.go:417-482` (`fastAckFromLeader`) | `MaybeSendLightSlowAck` |
| Slow-path commit predicate | `swift/swift.go:665-684` (`acceptFastAndSlowAck` + MsgSet) | `CheckCommit` |
| Recovery: NewLeader/Ack/Sync | `swift/recovery.go:15-288` | `OnNewLeaderRecv` / `OnNewLeaderAckRecv` / `OnSyncRecv` |
| Recovery state envelope | `MNewLeaderAckN` / `MSync` (`swift/defs.go:131-152`) | `SwiftRecoveryState` (Marshallable kind 17, [recovery_state.h](../src/deptran/swiftpaxos/recovery_state.h)) |
| Batcher | `swift/batcher.go` | `EnqueueFastAck` / `EnqueueLightSlowAck` / `DrainBatcher` (gated by `batch:` field in mode YAML) |
| Batched payload | `MAcks` / `MOptAcks` (`swift/defs.go:83-99`) | `SwiftBatchedAcks` (Marshallable kind 18, [batched_acks.h](../src/deptran/swiftpaxos/batched_acks.h)) |
| Per-key dep tracking | `swift/key.go` (`lightKeyInfo`) | `SwiftKeyInfo` |

### What's intentionally not implemented in Janus

- **`Checksum []SHash` / dependency-path field**: IMDEA carries it on `MFastAck`, but the server-side commit predicate is dep-only — checksum only matters for off-host clients accepting optimistic-execution results. Janus's coordinator is collocated with a replica, so there is no behavioral analog. Wire-format-only port would be straightforward; required only if a non-collocated client path is added.
- **Optimistic execution at the leader**: IMDEA's leader runs the cmd pre-commit and sends the result in `MReply`. Janus's coordinator gets the result post-commit via local `commit_callback`, so the mechanism would only help non-collocated clients.
- **Autonomous failure detector**: IMDEA's reference doesn't ship one (its `BeTheLeader` is an external admin trigger). Janus's `TriggerRecovery` is callable; per-deployment wire-up is left to the test harness.

---

## 8. Implications for the camera-ready sweep

1. Use [config/none_swiftpaxos.yml](../config/none_swiftpaxos.yml) (`batch: false`) for the headline SwiftPaxos number under IMDEA-faithful semantics. Throughput at the saturation knee will likely be lower than pre-`6a1af0b1` runs because the slow-path predicate is now stricter (was: any SQ of FastAcks; now: SQ of *endorsers of leader_dep*).
2. If the saturation throughput looks too low to compare meaningfully to Raft, switch to [config/none_swiftpaxos_batch.yml](../config/none_swiftpaxos_batch.yml) (`batch: true`) which routes via `SwiftBatchedAcks` and amortizes the per-cmd RPC count.
3. SwiftPaxos's wins should appear in: (a) latency at far-from-leader sites, (b) throughput at moderate concurrency where the system is latency-bound. SwiftPaxos's losses should appear at saturation against Raft.

---

## References

### Papers
- **SwiftPaxos** — Ryabinin, F., Gotsman, A., Sutra, P. *SwiftPaxos: Fast Geo-Replicated State Machines.* USENIX NSDI '24. https://www.usenix.org/system/files/nsdi24-ryabinin.pdf — protocol description, fast/slow path semantics, double-voting, recovery.
- **Fast Paxos** — Lamport, L. *Fast Paxos.* MSR-TR-2005-112 (2005). https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/tr-2005-112.pdf — antecedent for the fast-quorum intersection requirement (FQI) used by SwiftPaxos.
- **Raft** — Ongaro, D., Ousterhout, J. *In Search of an Understandable Consensus Algorithm.* USENIX ATC '14. https://raft.github.io/raft.pdf

### Code
- **IMDEA SwiftPaxos (reference Go impl)** — https://github.com/imdea-software/swiftpaxos
  - `swift/swift.go` — main protocol loop, handlers
  - `swift/recovery.go` — NewLeader/NewLeaderAck/Sync flow
  - `swift/batcher.go` — `MAcks`/`MOptAcks` batched wire format
  - `swift/defs.go` — message struct definitions and RPC IDs
  - `swift/dpath.go`, `swift/key.go` — per-key SHash chain (not ported to Janus)
  - `replica/quorum.go` — FQ/SQ size formulas
- **Janus SwiftPaxos** — `src/deptran/swiftpaxos/`, this repo. Brought to logical parity with IMDEA in commit `6a1af0b1` (2026-05-08). Earlier history under [src/deptran/swiftpaxos/](../src/deptran/swiftpaxos/).
- **Janus Raft** — `src/deptran/raft/`, this repo. Standard Raft with pipelined `AppendEntries` (`RAFT_PIPELINE_OPTIMIZATION`).
