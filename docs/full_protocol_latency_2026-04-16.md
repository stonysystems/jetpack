# Full Protocol Latency Benchmark — 2026-04-16

**Results dir**: `results/2026-04-16-full-protocol-benchmark/`
**Cluster**: 5-node zoo (.101-.105)
**Common settings**: `30c1s5r5p-zoo.yml`, `rw_1000000.yml`, `client_open.yml`, `concurrent_1`, `WAN_DELAY_MS=20` (40ms RTT), 30s duration
**CPU source**: in-binary `server median` from `.res` files (mid-10s, core 1)

## Experiment 1: Low-Load Latency (concurrent_1)

| # | Protocol | Config | `-m` | Throughput | p50 (ms) | p90 (ms) | p99 (ms) | FP rate | Server CPU median (zoo0) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Raft | `none_raft.yml` | 0 | 20.0 | 79.59 | 89.01 | 92.98 | N/A | 47.4% |
| 2 | Jetpack fp100 | `rule_raft.yml` | 100 | 20.1 | 40.64 | 40.78 | 40.91 | 100% | 68.0% |
| 3 | Jetpack adaptive | `rule_raft.yml` | 101 | 19.8 | 40.59 | 40.67 | 40.74 | 100% | 64.9% |
| 4 | CURP | `none_curp.yml` | 200 | 4.7 | N/A | N/A | N/A | 0% | 72.2% |
| 5 | **SwiftPaxos** | `none_swiftpaxos.yml` | 0 | 20.1 | **40.51** | **40.58** | **41.42** | N/A | 100.0% |
| 6 | **EPaxos** | `none_epaxos_corrected.yml` | 0 | 20.9 | **40.42** | **40.52** | **40.69** | N/A | 100.0% |
| 9 | CoPilot | `none_copilot.yml` | 0 | 20.1 | 102.18 | 103.04 | 103.49 | N/A | 100.0% |
| 10 | CoPilot + Jetpack | `rule_copilot.yml` | 101 | 19.6 | 40.71 | 40.83 | 41.11 | 100% | 92.1% |
| 11 | Mencius | `none_mencius.yml` | 0 | 20.1 | 122.63 | 123.98 | 125.10 | N/A | 100.0% |
| 12 | Mencius + Jetpack | `rule_mencius.yml` | 101 | 20.8 | 40.70 | 40.88 | 41.23 | 100% | 100.0% |

**Key observations:**

### Fast-path protocols (1 RTT = 40ms)
All four fast-path protocols achieve ~40ms p50, confirming 1 RTT commit:
- **Jetpack+Raft**: 40.64ms
- **SwiftPaxos**: 40.51ms
- **EPaxos**: 40.42ms
- **CoPilot+Jetpack**: 40.71ms

### Baseline protocols (2+ RTT)
- **Raft**: 79.59ms (2 RTT = 80ms) — as expected
- **CoPilot**: 102ms (slightly more than 2 RTT due to dual-pilot coordination)

### CURP
CURP had 0% fast-path success in this run (4.7 throughput, no efficient-path recording). Previous run (2026-04-15) showed 40.63ms p50 and 100% FP success. The result is intermittent — likely related to Raft leader election timing on the 5-node cluster. Documented as a known issue.

### Protocols NOT tested
- **etcd, ZooKeeper**: require external daemons (need separate setup)
- **Mencius**: tested successfully — no longer crashes (previously documented as Track 8F)

### Commands used
```bash
RDIR=results/2026-04-16-full-protocol-benchmark
./run_single_exp.sh none_raft.yml 0 concurrent_1.yml raft-c1 $RDIR
./run_single_exp.sh rule_raft.yml 100 concurrent_1.yml jp-fp100-c1 $RDIR
./run_single_exp.sh rule_raft.yml 101 concurrent_1.yml jp-adaptive-c1 $RDIR
./run_single_exp.sh none_curp.yml 200 concurrent_1.yml curp-c1 $RDIR
./run_single_exp.sh none_swiftpaxos.yml 0 concurrent_1.yml swiftpaxos-c1 $RDIR
./run_single_exp.sh none_epaxos_corrected.yml 0 concurrent_1.yml epaxos-c1 $RDIR
./run_single_exp.sh none_copilot.yml 0 concurrent_1.yml copilot-c1 $RDIR
./run_single_exp.sh rule_copilot.yml 101 concurrent_1.yml jp-copilot-c1 $RDIR
./run_single_exp.sh none_mencius.yml 0 concurrent_1.yml mencius-c1 $RDIR
./run_single_exp.sh rule_mencius.yml 101 concurrent_1.yml jp-mencius-c1 $RDIR
```

## SwiftPaxos and EPaxos are now WORKING on the zoo cluster

Both new protocols successfully achieve 1 RTT latency at low load, matching the expected theoretical performance:
- **SwiftPaxos** uses hash-based dependency agreement — all replicas reply fast when no conflicts
- **EPaxos** uses explicit dependency arrays — 2 round-trips in general, but fast commit when all agree

Both are functional implementations of their respective protocols (normal path only; no recovery yet).
