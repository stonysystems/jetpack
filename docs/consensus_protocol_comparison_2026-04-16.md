# Consensus Protocol Comparison — 2026-04-16

Consolidated results from the full protocol benchmark suite on a 5-node cluster.

## Cluster & Environment

- 5 nodes: `130.245.173.101-105`
- Each host: 2× Xeon Silver 4216 (64 cores), 64 GB RAM
- WAN simulation: 20ms one-way delay (40ms RTT) via `WAN_DELAY_MS=20`
- Topology: `30c1s5r5p-zoo.yml` (30 clients, 5 replicas, 5 partitions)
- Workload: `rw_1000000.yml` (100% write, 1M key range, ~0 conflict rate)
- Duration: 30s per experiment (metrics from mid-10s)
- Server thread pinned to core 1, client threads on cores 0/2/3/5/6/7

## Protocol Coverage

| # | Label | Config | `-m` flag | Notes |
|---|---|---|---|---|
| 1 | Raft | `none_raft.yml` | 0 | Baseline, 2 RTT |
| 2 | Raft + Jetpack+Raft fp100 | `rule_raft.yml` | 100 | Jetpack 100% fast path |
| 3 | Raft + Jetpack+Raft adaptive | `rule_raft.yml` | 101 | Jetpack+Raft adaptive throttle |
| 4 | CURP (+Raft) | `none_curp.yml` | 200 | Leader checks log, witnesses check pool |
| 5 | SwiftPaxos | `none_swiftpaxos.yml` | 0 | Leader-optimized leaderless, hash-based |
| 6 | EPaxos (corrected) | `none_epaxos_corrected.yml` | 0 | Leaderless, dependency graph |
| 7 | CoPilot | `none_copilot.yml` | 0 | Dual-pilot protocol |
| 8 | Jetpack+CoPilot adaptive | `rule_copilot.yml` | 101 | Jetpack on CoPilot |
| 9 | Mencius | `none_mencius.yml` | 0 | Rotating leader |
| 10 | Jetpack+Mencius adaptive | `rule_mencius.yml` | 101 | Jetpack on Mencius |
| 11 | etcd | `none_etcd.yml` | 0 | External etcd backend (NOT TESTED — requires daemon) |
| 12 | ZooKeeper | `none_zookeeper.yml` | 0 | External ZK backend (NOT TESTED — requires daemon) |

**Tested**: 10 of 12 protocol configurations. etcd and ZooKeeper require external daemons which weren't available in this test run.

## Latency at c1 (Low Load, 1 RTT baseline = 40ms)

| Protocol | p50 (ms) | p90 (ms) | p99 (ms) | RTTs |
|---|---|---|---|---|
| Raft | 79.59 | 89.01 | 92.98 | 2.0 RTT |
| CoPilot | 102.18 | 103.04 | 103.49 | 2.5 RTT |
| Mencius | 122.63 | 123.98 | 125.10 | 3.0 RTT |
| **Jetpack+Raft fp100** | **40.64** | 40.78 | 40.91 | **1.0 RTT** |
| **Jetpack+Raft adaptive** | **40.59** | 40.67 | 40.74 | **1.0 RTT** |
| **CURP** | **40.63** | 40.71 | 41.04 | **1.0 RTT** |
| **SwiftPaxos** | **40.51** | 40.58 | 41.42 | **1.0 RTT** |
| **EPaxos (corrected)** | **40.42** | 40.52 | 40.69 | **1.0 RTT** |
| **Jetpack+CoPilot adaptive** | **40.71** | 40.83 | 41.11 | **1.0 RTT** |
| **Jetpack+Mencius adaptive** | **40.70** | 40.88 | 41.23 | **1.0 RTT** |

**Observations:**
- Baseline (non-Jetpack) protocols require 2+ RTTs: Raft=2, CoPilot=2.5, Mencius=3
- All fast-path protocols achieve **clean 1 RTT (40ms)** with p99 < 42ms
- Jetpack plugin delivers consistent 1 RTT regardless of base protocol
- CURP matches Jetpack+Raft fp100 exactly (same infrastructure, different leader check)
- SwiftPaxos and EPaxos achieve 1 RTT via their own mechanisms (hash agreement / dep agreement)

## Peak Throughput

| Protocol | Peak (cmd/s) | p50 at peak | Scalability |
|---|---|---|---|
| Raft | 5989.6 | 75.89 | ✓ Scales to c500 |
| Jetpack+Raft fp100 | 6004.3 | 42.03 | ✓ Scales to c500 |
| Jetpack+Raft adaptive | 6002.6 | 41.96 | ✓ Scales to c500 |
| SwiftPaxos | **6012.1** | **41.39** | ✓ Scales to c500 (winner) |
| EPaxos | 5996.1 | 41.23 | ✓ Scales to c500 |
| CoPilot | 4463.6 | 103.25 | ✗ Fails at c500 |
| Jetpack+CoPilot adaptive | 1480.7 | 41.56 | ✗ Fails at c150 |
| Mencius | 216.6 | low | ✗ Fails at c150 |
| Jetpack+Mencius adaptive | n/a | — | ✗ Fails at c50 |
| CURP | n/a | — | ✗ Known bug at c50+ |

**All 5 scalable protocols saturate at c200 (~5960 cmd/s), improving marginally to c500 (~6000 cmd/s).** This indicates a server-side CPU bottleneck on the single pinned core.

## Key Findings

### 1. Fast-path protocols deliver 2x latency improvement uniformly
All 7 fast-path variants (Jetpack on Raft/CoPilot/Mencius, CURP, SwiftPaxos, EPaxos) achieve ~40ms p50 vs the baseline's 80-122ms. The consistency across protocols confirms the 1 RTT commit mechanism works regardless of the underlying consensus.

### 2. Same throughput ceiling at ~6000 cmd/s
The 5 scalable protocols (Raft, Jetpack+Raft fp100/adaptive, SwiftPaxos, EPaxos) all cap at ~6000 cmd/s. This bottleneck is the single-core server thread, not the protocol — suggesting further throughput gains require multi-threading the server.

### 3. Latency advantage preserved at saturation
At the peak concurrency, Jetpack-based protocols maintain ~42ms p50 while Raft operates at ~76ms. The fast-path optimization doesn't degrade under load — latency stays near 1 RTT even when throughput saturates.

### 4. Stability matters more than protocol design at scale
Several theoretically-faster protocols (CoPilot, Mencius, CURP) fail or collapse at higher concurrency. The Raft-based implementations (with or without Jetpack) are the most stable.

### 5. SwiftPaxos is the highest-throughput
SwiftPaxos achieves 6012 cmd/s at c500 — slightly ahead of Jetpack (6004) and EPaxos (5996). All differences are within ~1% and may be noise.

## Commit Trail

All results and implementation commits on branch `jetpack`:

- `8644411b`: CURP implementation (Phase 1.0-1.4)
- `a2a04030`: CURP recovery skip + self-conflict fix
- `2ae8cc01`: SwiftPaxos scaffolding + RPCs
- `2f3b0981`: SwiftPaxos server + coordinator
- `95d3549a`: EPaxos (corrected) scaffolding + server
- `dca242e4`: Enable in-binary CPU monitor for all builds
- `1449a7db`: Latency experiment results
- `89d53a58`: Throughput sweep results
- `097ee45e`: Bisect throughput finalization
- `1d57e01d`: Mencius results added
- `819918fa`: map::find() optimization in CURP log scan

## Experiment Reproducibility

```bash
# Build once
docker build -f docker/zoo-build/Dockerfile -t jetpack-zoo-build .
docker create --name tmp jetpack-zoo-build
docker cp tmp:/output/deptran_server build/deptran_server
docker cp tmp:/output/lib build/docker_libs/
docker rm tmp

# Run latency experiments (c1)
RDIR=results/2026-04-16-full-protocol-benchmark
for proto in "none_raft.yml 0 raft" "rule_raft.yml 100 jp-fp100" \
             "rule_raft.yml 101 jp-adaptive" "none_curp.yml 200 curp" \
             "none_swiftpaxos.yml 0 swiftpaxos" "none_epaxos_corrected.yml 0 epaxos" \
             "none_copilot.yml 0 copilot" "rule_copilot.yml 101 jp-copilot" \
             "none_mencius.yml 0 mencius" "rule_mencius.yml 101 jp-mencius"; do
  read cfg mode label <<< "$proto"
  ./scripts/run_single_exp.sh $cfg $mode concurrent_1.yml $label-c1 $RDIR
done

# Run throughput sweep (c50, c150, c200, c300, c500)
for proto in "none_raft.yml 0 raft" "rule_raft.yml 100 jp-fp100" \
             "rule_raft.yml 101 jp-adaptive" "none_swiftpaxos.yml 0 swiftpaxos" \
             "none_epaxos_corrected.yml 0 epaxos"; do
  read cfg mode label <<< "$proto"
  for conc in 50 150 200 300 500; do
    ./scripts/run_single_exp.sh $cfg $mode concurrent_${conc}.yml $label-c${conc} $RDIR
  done
done
```
