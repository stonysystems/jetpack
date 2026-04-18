# Full Protocol Comparison (with CURP + etcd reruns) — 2026-04-18

**Results dirs**: `results/2026-04-16-bisection/` (Raft, Jetpack+Raft fp100/adaptive, SwiftPaxos, EPaxos), `results/2026-04-18-curp-etcd-rerun/` (CURP, etcd).

**Cluster**: 5-node zoo (.101-.105), pinned server core 1, WAN_DELAY_MS=20 (40ms RTT), `rw_1000000.yml`, `client_open.yml`, 30s per point.

**Why this rerun**: CURP at c≥10 was broken before commit `a1d6b8b2` (non-leader hosts saw the real leader as a "witness" and got NO votes that collapsed the fast-path quorum). With that fix, CURP now behaves as designed. etcd was also benchmarked end-to-end (5-node etcd cluster spun up via `scripts/start_etcd_cluster.sh`; Janus talks to local etcd via port 2379).

## Latency at c=1 (all 7 protocols)

30 clients × 1 concurrent per worker = 30 in-flight.

| Protocol | p50 (ms) | Type |
|---|---:|---|
| Raft | 79.59 | 2 RTT |
| Jetpack+Raft fp100 | 40.64 | 1 RTT ✓ |
| Jetpack+Raft adaptive | 40.59 | 1 RTT ✓ |
| **CURP** | **40.59 / 41.27 / 40.71 / 40.76 / 40.89 (all hosts)** | 1 RTT ✓ |
| SwiftPaxos | 40.51 | 1 RTT ✓ |
| EPaxos | 40.42 | 1 RTT ✓ |
| **etcd** | **84.46 / 85.23 / 85.13 / 85.06 / 86.17 (all hosts)** | 2 RTT |

CURP c=1 p50 is now uniform across all 5 hosts (~41 ms). etcd's 2-RTT is expected — etcd client lib runs its own Raft commit path on top of the local etcd daemon.

## Max-throughput bisection — peak per protocol

For each protocol, swept client count N ∈ {30, 40, 45, 50, 55, 60, 70, 80, 90, 100} at concurrent=500. Stopped per-protocol when max server CPU ≥ 99% or zoo0/zoo3 p50 > 2× c=1 baseline.

| Protocol | Peak tput (cmd/s) | Saturation N | Max CPU | Avg CPU (5 hosts) | p50 (zoo3) |
|---|---:|---:|---:|---:|---:|
| **EPaxos** | **19990.6** | 100 | 98.99% | 73.1% | 42.53 ms |
| Raft | 13984.4 | 70 | 89.90% | 45.7% | 87.15 ms |
| SwiftPaxos | 11968.4 | 60 | 98.99% | 92.1% | 42.58 ms |
| **CURP** (after `a1d6b8b2`) | **10973.3** | 55 | 91.75% | 73.7% | 42.67 ms |
| etcd | 8000.1 | 40 | 97.0% | 32.2% | 95.75 ms |
| Jetpack+Raft fp100 | 8997.9 | 45 | 92.78% | 70.9% | 42.52 ms |
| Jetpack+Raft adaptive | 7993.4 | 40 | 93.94% | 57.2% | 42.17 ms |

**Peak ordering**: EPaxos > Raft > SwiftPaxos > **CURP** > Jetpack+Raft fp100 > etcd ≥ Jetpack+Raft adaptive.

**New insights from the reruns**:

1. **CURP is now competitive with SwiftPaxos in throughput and gives 1-RTT latency.** Peak 10973 @ N=55 vs SwiftPaxos 11968 @ N=60 — CURP is within 9% at a lower saturation N. Both achieve 42ms p50 across all hosts.

2. **CURP still peaks lower than vanilla Raft.** Raft 13984 vs CURP 10973 — CURP's speculative broadcast still costs non-leader CPU (`command_pool_.push_back` on every witness), so its non-leader replicas work harder (avg CPU 73.7% vs Raft's 45.7%). That extra work means CURP's max-CPU host (zoo3, the leader) pins sooner than Raft's leader does.

3. **CURP beats Jetpack+Raft fp100 on peak throughput** (10973 vs 8998, +22%), because CURP skips the spec RPC to the leader. The leader in CURP only does Raft replication, whereas in Jetpack+Raft fp100 it does both.

4. **etcd peaks at 8000 cmd/s @ N=40.** The bottleneck is the single etcd-client connection pool on zoo0 (loc_id=0 is the only replica that opens the pool, per `deptran/etcd/server.h`). zoo0 pins at 97-99% CPU while the other 4 Janus replicas stay idle (4-23% CPU). So etcd's Janus-layer peak is zoo0's own pinned core; the underlying etcd cluster has more capacity but we don't exploit it.

5. **Latency difference at peak is significant**:
   - CURP / Jetpack+Raft / SwiftPaxos / EPaxos: 42 ms p50 (1 RTT).
   - Raft: 87 ms p50 (2 RTT).
   - etcd: 95-112 ms p50 (2 RTT + etcd-internal latency).

## Per-N sweep detail

### CURP (new)

| N | Total | Max CPU | p50 (zoo3) |
|---:|---:|---:|---:|
| 30 | 6008.9 | 72.73 | 41.94 |
| 40 | 8005.2 | 87.76 | 42.13 |
| 45 | 8996.1 | 89.36 | 42.16 |
| 50 | 9992.4 | 92.00 | 41.96 |
| 55 | 10973.3 | 91.75 | 42.67 |
| 60 | 11287.5 | **100.00** | 42.37 ← STOP |

### etcd (new)

| N | Total | Max CPU (zoo0) | p50 (zoo0) |
|---:|---:|---:|---:|
| 30 | 5989.3 | 85.00 | 88.80 |
| 40 | 8000.1 | 97.00 | 95.08 |
| 45 | 9005.1 | **99.00** | 111.66 ← STOP |

Notice etcd's zoo0 CPU climbs 85% → 97% → 99% while other hosts stay < 24%. Asymmetric because only loc_id=0 (zoo0) opens the etcd connection pool in the current `deptran/etcd/server.h` implementation.

## CPU efficiency (cmd/s per max-CPU-percent on the busiest replica)

| Protocol | Peak / max CPU |
|---|---:|
| EPaxos | 202 |
| Raft | 156 |
| SwiftPaxos | 121 |
| CURP | 120 |
| Jetpack+Raft fp100 | 97 |
| Jetpack+Raft adaptive | 85 |
| etcd | 83 |

EPaxos remains the per-CPU-percent champion (distributes proposer duty across 5 replicas). CURP lands in the same band as SwiftPaxos — both do per-replica conflict tracking on every command, so their per-replica cost is higher than Raft's followers-just-replicate pattern.

## Commands used

```bash
# Latency c=1
./scripts/run_single_exp.sh none_curp.yml 200 concurrent_1.yml curp-c1 results/2026-04-18-curp-etcd-rerun 30c1s5r5p-zoo.yml
./scripts/run_single_exp.sh none_etcd.yml 0 concurrent_1.yml etcd-c1 results/2026-04-18-curp-etcd-rerun 30c1s5r5p-zoo.yml

# etcd cluster lifecycle
./scripts/start_etcd_cluster.sh
./scripts/stop_etcd_cluster.sh

# Bisection (runs both CURP and etcd, stops at saturation)
bash /tmp/curp_etcd_sweep.sh   # or adapt scripts/run_bisection_sweep.sh
```
