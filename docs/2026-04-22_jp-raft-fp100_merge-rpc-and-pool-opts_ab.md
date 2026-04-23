# Jetpack+Raft fp100 — Merge-RPC and Pool Optimization A/B/C — 2026-04-22

Three-way comparison isolating the impact of the two jetpack optimizations that
landed in commit `62e1d7db` ("Jetpack pool opts + fused leader RPC"):

1. **Merge RPC** — fuse `Dispatch` + `RuleSpeculativeExecute` into a single
   leader-side RPC, reducing per-txn leader RPC count from 2 to 1. Flag-gated
   via `jetpack_merge_leader_rpc` in [config/rule_raft_merge.yml](../config/rule_raft_merge.yml).
2. **Pool opts** — `SimpleRWCommand::ExtractPoolKeys` on the pool hot path to
   skip a deep `SimpleRWCommand(cmd)` copy; `RevoveryCandidates::Entry`
   struct to stash `is_write` next to the cmd pointer.

Because the two optimizations were committed together, to isolate "merge only"
I built a transient binary at `a17b8d65` with `src/deptran/RW_command.{cc,h}`
and `src/deptran/scheduler.{cc,h}` reverted to `f8cb8fb4`. The other opt code
paths (`rule/`, `service.{cc,h}`, `rcc_rpc.rpc`, `config.{cc,h}`) stayed at
`a17b8d65`, so merge RPC is present and controlled purely by the YAML flag.

## Environment

- 5-host cluster, WAN_DELAY_MS=20 (40 ms injected RTT), SERVER_CORE_ID=17
  (pthread affinity on the server thread; no process-wide `taskset`), leader
  at zoo2, clients distributed round-robin across zoo1–5.
- Mode `-m 100` (fp100), `concurrent_500.yml` (500 outstanding per client
  site), `rw_1000000.yml`, duration 30 s per point.
- Methodology: new adaptive sweep (see
  [scripts/run_adaptive_sweep.sh](../scripts/run_adaptive_sweep.sh) at
  `48d298eb`): SLO = `zoo2 p90 <= 1000 ms`, `BISECT_TOL=1`, post-bisect
  dense `±2` probe, peak = `argmax(tput)` over rows with p90 ≤ SLO.
- All three sweeps were run back-to-back on the same zoo cluster state
  (no TLC jobs or other CPU hogs on zoo2) to minimize environmental drift
  between runs.

## Binaries

| Variant | Source | ExtractPoolKeys | DispatchWithRuleSpec | Config |
|---|---|:---:|:---:|---|
| **A — no opts** | `f8cb8fb4` | – | – | [rule_raft.yml](../config/rule_raft.yml) |
| **B — merge only** | `a17b8d65` with pool files reverted to `f8cb8fb4` | – | ✓ | [rule_raft_merge.yml](../config/rule_raft_merge.yml) |
| **C — merge + pool** | `a17b8d65` | ✓ | ✓ | [rule_raft_merge.yml](../config/rule_raft_merge.yml) |

Symbol-count verification (`nm build/deptran_server.X | grep -cE 'ExtractPoolKeys|DispatchWithRuleSpec'`):
A = 0 pool, 0 merge; B = 0 pool, 20 merge; C = 2 pool, 20 merge.

## What is N

`N` is the number of client sites `c01..cN` distributed round-robin across
zoo1–5 by [scripts/gen_client_config.sh](../scripts/gen_client_config.sh).
Each site runs **one** client thread with `concurrent_500.yml` ⇒ 500 outstanding
closed-loop requests (coroutines) per site. Total offered load ≈ `N × 500`
in-flight requests.

## Peak summary

| Variant | Peak tput (cmd/s) | @ N | zoo2 p50 (ms) | zoo2 p90 (ms) | zoo2 p99 (ms) | avg core-17 cpu | zoo2 core-17 |
|---|---:|---:|---:|---:|---:|---:|---:|
| **A — no opts** | 12 844 | 74 | 257 | **727** | 9 422 | 75.3 % | 99.9 % |
| **B — merge only** | **14 980** | 75 | 41.2 | **41.8** | 47.8 | 83.2 % | 95.4 % |
| **C — merge + pool** | 14 979 | 75 | 41.2 | **41.9** | 53.7 | 83.2 % | 95.7 % |

Headline:

- **A → B**: +16.6 % peak throughput, and p90 at peak collapses from
  **727 ms → 42 ms** — merge RPC is the dominant optimization.
- **B → C**: effectively zero change at peak. Pool opts give at most
  modest post-peak robustness; the leader's single-core budget is what binds.

## Per-variant sweep detail

Rows sorted by N ascending. `stopped=bisect-ok` / `dense-ok` = passes SLO,
`bisect-stop` / `dense-stop` = trips SLO (`zoo2 p90 > 1000 ms`).

### A — no opts (`f8cb8fb4`, `rule_raft.yml`)

| N | tput | z2 p50 | z2 p90 | z2 p99 | z3 p50 | z1 cpu | z2 cpu | z3 cpu | z4 cpu | z5 cpu | **avg** | note |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
|   1 |   200 |  41.6 |  42.3 |  42.7 |   –   |   0 |   7.4 |   0 |   0 |   0 |  **0.6** | baseline |
|  50 | 9 998 |  42.4 |  47.8 |  79.4 |  42.7 | 40.8 |  98.3 | 82.4 | 89.6 | 55.4 | **73.3** | ok |
|  73 | 12 589 | 234.5 | 540.5 | 7 713 | 235.8 | 42.1 | 100.0 | 84.5 | 89.6 | 60.2 | **75.3** | dense-ok |
|  74 | **12 844** | **256.5** | **726.9** | **9 422** | 254.9 | 43.5 |  99.9 | 84.1 | 89.9 | 59.0 | **75.3** | **PEAK** |
|  75 | 11 450 | 320.5 | 708.2 | 11 165 | 321.0 | 39.0 | 100.0 | 78.8 | 87.1 | 53.2 | **71.6** | bisect-ok |
|  76 | 10 362 | 336.4 | 1 099 | 12 004 | 333.3 | 37.3 | 100.0 | 75.1 | 84.6 | 49.6 | **69.3** | bisect-stop |
|  77 |  9 293 | 365.5 | 8 593 | 10 419 | 357.4 | 35.3 | 100.0 | 71.9 | 81.4 | 45.4 | **66.8** | dense-stop |
|  78 | 10 019 | 357.5 | 1 084 | 12 453 | 352.2 | 36.5 | 100.0 | 76.5 | 81.7 | 47.5 | **68.4** | bisect-stop |
|  81 |  8 624 | 414.1 | 10 565 | 12 369 | 420.3 | 30.8 | 100.0 | 66.1 | 74.9 | 43.5 | **63.1** | bisect-stop |
|  87 |  7 441 | 482.6 | 13 690 | 15 405 | 478.1 | 29.0 | 100.0 | 64.2 | 73.5 | 38.8 | **61.1** | bisect-stop |
| 100 |  4 504 | 777.1 | 27 720 | 30 531 | 789.3 | 15.7 | 100.0 | 40.9 | 44.5 | 22.3 | **44.7** | stop |

Peak is at N=74 but the leader is already at the saturation knee:
p50=257 ms, p99=9.4 s, zoo2 core-17 = 99.9 %. The system is delivering ~12.8 k
cmd/s but queueing heavily — it just happens to be under the p90 = 1000 ms SLO.

### B — merge only (`a17b8d65` + pool reverted, `rule_raft_merge.yml`)

| N | tput | z2 p50 | z2 p90 | z2 p99 | z3 p50 | z1 cpu | z2 cpu | z3 cpu | z4 cpu | z5 cpu | **avg** | note |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
|   1 |   201 |  41.1 |  41.8 |  42.2 |   –   |   0 |   2.3 |   0 |   0 |   0 |  **0.5** | baseline |
|  50 | 9 996 |  41.1 |  41.8 |  58.0 |  41.3 | 41.6 |  95.6 | 77.7 | 82.6 | 46.3 | **68.7** | ok |
|  75 | **14 980** | **41.2** | **41.9** | **47.8** |  41.3 | 58.9 |  95.4 | 92.4 | 92.8 | 76.6 | **83.2** | **PEAK** |
|  85 | 10 154 |  41.4 | 9 375 | 11 967 |  41.6 | 36.2 | 100.0 | 75.6 | 86.3 | 48.5 | **69.3** | dense-stop |
|  86 | 10 092 |  41.3 | 8 521 | 13 235 |  41.6 | 39.1 | 100.0 | 77.2 | 81.4 | 51.4 | **69.8** | dense-stop |
|  87 | 13 624 |  41.3 |  42.4 | 13 639 |  41.5 | 44.6 | 100.0 | 87.1 | 90.1 | 61.6 | **76.7** | bisect-ok (fluke, p99=13.6 s) |
|  88 |  9 169 |  41.3 | 10 371 | 12 865 |  41.6 | 37.5 | 100.0 | 72.0 | 81.2 | 52.1 | **68.6** | bisect-stop |
|  89 |  8 417 |  41.4 | 10 994 | 14 112 |  41.6 | 37.4 |  99.8 | 68.3 | 78.0 | 50.2 | **66.8** | dense-stop |
|  90 |  7 502 |  41.4 | 12 971 | 17 045 |  41.6 | 30.0 | 100.0 | 67.5 | 72.8 | 41.8 | **62.4** | bisect-stop |
|  93 |  7 920 |  41.4 | 13 741 | 15 516 |  41.6 | 31.2 |  99.9 | 65.7 | 78.7 | 44.2 | **63.9** | bisect-stop |
| 100 |  4 622 |  41.4 | 22 270 | 25 631 |  41.6 | 23.9 | 100.0 | 47.4 | 61.4 | 28.3 | **52.2** | stop |

The **p50** column is the most striking: across every N up to and past peak,
zoo2 p50 stays at ~41 ms, i.e. exactly the one-RTT floor. The system is not
queuing on the leader path at all — the fused RPC frees leader CPU so spec
execution and raft replication no longer contend. The N=87 row is a
single-point fluke where p90 happened to stay under SLO; p99 = 13.6 s on the
same row shows queueing did occur in the tail. All neighbouring Ns are
saturated, so the true peak is at N=75.

### C — merge + pool (`a17b8d65`, `rule_raft_merge.yml`)

| N | tput | z2 p50 | z2 p90 | z2 p99 | z3 p50 | z1 cpu | z2 cpu | z3 cpu | z4 cpu | z5 cpu | **avg** | note |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
|   1 |   201 |  41.2 |  41.8 |  42.2 |   –   |   0 |   1.8 |   0 |   0 |   0 |  **0.4** | baseline |
|  50 | 9 986 |  41.1 |  41.8 |  50.9 |  41.3 | 40.5 |  95.4 | 79.6 | 84.3 | 44.7 | **68.9** | ok |
|  75 | **14 979** | **41.2** | **41.9** | **53.7** |  41.3 | 57.7 |  95.7 | 93.0 | 93.9 | 75.7 | **83.2** | **PEAK** |
|  81 | 13 064 |  41.4 | 181.7 | 10 839 |  41.6 | 46.3 | 100.0 | 86.0 | 90.7 | 61.8 | **76.9** | bisect-ok |
|  82 | 12 174 |  41.3 | 232.0 | 11 487 |  41.5 | 42.4 | 100.0 | 85.7 | 90.1 | 61.4 | **75.9** | bisect-ok |
|  83 | 10 660 |  41.4 | 674.0 | 12 536 |  41.6 | 39.3 | 100.0 | 79.1 | 85.8 | 60.5 | **72.9** | bisect-ok |
|  84 | 10 694 |  41.4 | 6 577 | 12 179 |  41.6 | 39.8 | 100.0 | 79.4 | 86.9 | 55.4 | **72.3** | bisect-stop |
|  85 |  9 648 |  41.3 | 10 376 | 12 434 |  41.6 | 37.4 | 100.0 | 74.6 | 81.9 | 49.9 | **68.8** | dense-stop |
|  86 | 10 164 |  41.3 | 9 732 | 12 892 |  41.5 | 36.7 | 100.0 | 78.2 | 84.2 | 52.6 | **70.3** | dense-stop |
|  87 |  7 283 |  41.4 | 12 294 | 16 907 |  41.7 | 29.2 | 100.0 | 63.1 | 74.3 | 41.7 | **61.7** | bisect-stop |
| 100 |  5 022 |  41.4 | 20 679 | 23 579 |  41.7 | 22.8 | 100.0 | 52.7 | 57.9 | 32.8 | **53.2** | stop |

Compared with B, C behaves more gracefully past the peak: at N=81–83 it stays
under SLO (p90 rising 182 → 232 → 674 ms) whereas B was saturated at every
neighbour of 75 except the one N=87 fluke. The pool opt appears to widen the
"still-useful" operating range by ~5 clients, even though peak tput itself is
unchanged within run-to-run noise.

## Interpretation

**Merge RPC does essentially everything.** The win is both
throughput (+16.6 %) and tail latency (p90 at peak: 727 ms → 42 ms). The
mechanism is that fusing `Dispatch` and `RuleSpeculativeExecute` removes one
leader-side RPC per txn, cutting leader RPC volume from 2 to 1 and freeing
core-17 cycles for raft replication. At N=75 after the fuse, the leader is
running at 95 % (down from 99.9 % for A at a lower N), so the leader's single
core is no longer the sharp constraint it used to be at 13 k tput.

**Pool opts do not improve peak.** At N=75 both B and C are identical to two
decimal places (14 980 vs 14 979). The hot path the pool opts touch is not
what's gating throughput once the merge RPC is in place. Pool opts _do_ give
~5 clients of post-peak stability (C stays under SLO to N=83 vs B's one-fluke
behaviour past 75), which is a small but real quality-of-saturation win.

**Where next.** At B/C's peak the leader is at 95 % on core 17. To push past
~15 k cmd/s we'd need to either (a) parallelise leader work beyond one core
(multi-partition, or unpinning with cache-warmth trade-off), or (b) reduce
per-request leader cycles further (e.g. pipeline the spec reply with the
raft append-entries response to shave another RPC hop).

## Raw data

- Sweep A: `results/2026-04-22-jp-raft-fp100-A-noopt/jp-raft-fp100-adaptive.csv`
- Sweep B: `results/2026-04-22-jp-raft-fp100-B-mergeonly/jp-raft-fp100-adaptive.csv`
- Sweep C: `results/2026-04-23-jp-raft-fp100-C-full/jp-raft-fp100-adaptive.csv`

(These are gitignored; the summary tables in this doc are the canonical form
checked into the repo.)

## Prior reference

For the 2026-04-20 baseline numbers this supersedes — 13 586 at N=68 on the
pre-opt binary — see [max_throughput_core17_2026-04-20.md](max_throughput_core17_2026-04-20.md).
Today's A matches within run-to-run noise (12 844 vs 13 586, ≈5 % lower),
validating that the pre-opt result was representative.
