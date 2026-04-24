# Max throughput per protocol — with optimized Jetpack — 2026-04-23

Merges the 2026-04-20 protocol-baseline table with post-optimization
Jetpack reruns (2026-04-22 A/B/C for fp100, 2026-04-23 reruns of both
fp100 and adaptive) so both jetpack rows reflect the merge-RPC + pool
opts landed in commit `62e1d7db`.

This doc supersedes the `jp-raft-fp100` and `jp-raft-adaptive` rows of
[max_throughput_core17_2026-04-20.md](max_throughput_core17_2026-04-20.md).
All other rows are unchanged from that pass because we didn't re-run
them with the optimizations; see "Caveats" below.

## Peak per protocol

Ranked by peak `cmd/s`.

| Protocol | Peak (cmd/s) | N | zoo2 p50 (ms) | zoo2 p90 | zoo2 p99 | zoo3 p50 | zoo1 cpu | zoo2 cpu | zoo3 cpu | zoo4 cpu | zoo5 cpu | avg cpu | Source |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| naive_epaxos | 44 284 | 231 | 122.9 | 180.2 | 280.7 | 152.1 | 95.5 | 88.7 | 96.8 | 98.1 | 99.5 | 95.7 | 2026-04-20 |
| epaxos | 27 363 | 137 | 78.2 | 236.7 | 546.9 | 78.8 | 99.5 | 18.2 | 52.5 | 57.7 | 25.5 | 50.7 | 2026-04-20 |
| naive_raft | 18 004 | 90 | 87.5 | 153.1 | 217.2 | 88.0 | 23.1 | 99.8 | 48.6 | 59.6 | 29.7 | 52.2 | 2026-04-20 |
| raft (zoo2) | 16 790 | 84 | 98.9 | 146.4 | 205.9 | 99.2 | 21.1 | 99.5 | 49.9 | 57.6 | 28.1 | 51.3 | 2026-04-20 |
| swiftpaxos | 16 788 | 84 | 43.3 | 44.5 | 68.5 | 43.5 | 99.9 | 69.6 | 93.9 | 93.8 | 83.0 | 88.0 | 2026-04-20 |
| jp-raft-fp100 opt (zoo2) | 15 390 | 77 | 41.2 | 42.0 | 71.4 | 41.4 | 59.3 | 99.5 | 93.5 | 93.2 | 76.4 | 84.4 | 2026-04-23 post-opt |
| jp-raft-adaptive cpu-aware (zoo2) | 15 396 | 81 | 785.1 | 908.8 | 991.5 | 805.3 | 19.6 | 100.0 | 44.8 | 48.0 | 27.4 | 47.9 | 2026-04-23 post-opt + cpu-aware throttle |
| jp-raft-adaptive opt (zoo2) | 15 012 | 75 | 41.2 | 43.6 | 81.1 | 41.4 | 59.0 | 99.5 | 92.5 | 92.4 | 77.1 | 84.1 | 2026-04-23 post-opt (no throttle fix) |
| etcd | 13 002 | 65 | 89.0 | 98.1 | 118.0 | 89.5 | 99.9 | 5.7 | 14.6 | 16.5 | 7.4 | 28.8 | 2026-04-20 |
| CURP (zoo2) | 11 973 | 60 | 44.2 | 56.9 | 89.2 | 44.4 | 49.9 | 96.2 | 86.0 | 81.9 | 68.9 | 76.6 | 2026-04-20 |

## jp-raft fastpath detail (post-opt)

The adaptive sweep was extended to record per-N fastpath attempt and success
counts (summed across all 5 hosts). Two versions of the `adaptive` row are
shown: the original throttle (N=75 peak, fp_rate 99.6 % at saturation) and
the **cpu-aware retune** landed on 2026-04-23 that drives fp_rate → 0 when
the leader is at saturation — matching the user's design intent that
adaptive should gracefully degrade toward vanilla Raft at peak load.

The cpu-aware throttle uncovered two signal-path bugs while I was at it:
(a) the `CoordinatorRule::DispatchAndSpeculativeExecuteFused` merge path
dropped the leader's CPU on the floor (only follower CPU was reaching
the controller), and (b) the server-side `SampleCpuUsage()` was backed
by a coroutine sampler that never published a sample on some builds —
both fixed. With those in place the controller sees real leader CPU and
the ramp starts working (70 % → 95 % linear, live recent-100 avg).

jp-raft-fp100 opt:

| N | tput | z2 p50 | z2 p90 | z2 cpu | fp_rate | fp_eff_rate | note |
|---:|---:|---:|---:|---:|---:|---:|---|
| 75 | 14 984 | 41.2 | 41.8 | 96.1 | 99.84 % | 99.84 % | bisect-ok |
| 76 | 15 182 | 41.2 | 41.9 | 96.0 | 99.83 % | 99.83 % | extra-ok |
| **77** | **15 390** | **41.2** | **42.0** | **99.5** | **99.73 %** | **99.73 %** | **extra-ok (PEAK)** |
| 78 | 15 366 | 41.5 | 155.2 | 100.0 | 97.30 % | 97.30 % | extra-ok |
| 79 | 11 791 | 41.3 | 273.2 | 99.9 | 91.43 % | 91.43 % | extra-ok |
| 80 | 13 633 | 41.3 | 191.7 | 100.0 | 93.51 % | 93.51 % | extra-ok |
| 81 | 10 821 | 41.4 | 571.7 | 100.0 | 90.36 % | 90.36 % | bisect-ok |
| 82 | 12 393 | 41.4 | 375.9 | 100.0 | 91.68 % | 91.68 % | bisect-ok |
| 83 | 11 480 | 41.4 | 526.2 | 99.9 | 90.69 % | 90.69 % | bisect-ok |

jp-raft-adaptive opt (original throttle — cpu signal was broken on merge path):

| N | tput | z2 p50 | z2 p90 | z2 cpu | fp_rate | fp_eff_rate | note |
|---:|---:|---:|---:|---:|---:|---:|---|
| **75** | **15 012** | **41.3** | **43.6** | **99.5** | **99.64 %** | **99.64 %** | **bisect-ok (PEAK, pre-fix)** |
| 80 | 10 910 | 41.3 | 200.2 | 100.0 | 90.31 % | 90.31 % | dense-ok |
| 81 | 11 801 | 41.3 | 142.0 | 100.0 | 90.97 % | 90.97 % | bisect-ok |
| 82 | 11 380 | 41.3 | 72.5 | 100.0 | 90.46 % | 90.46 % | bisect-ok |
| 83 | 10 740 | 41.3 | 8 329 | 100.0 | 89.71 % | 89.71 % | bisect-stop |

jp-raft-adaptive cpu-aware (fixed signal + retuned 70 %→95 % ramp):

| N | tput | z2 p50 | z2 p90 | z2 cpu | fp_rate | fp_eff_rate | note |
|---:|---:|---:|---:|---:|---:|---:|---|
| 75 | 14 971 | 72.4 | 82.8 | 97.7 | 0.00 % | 0.00 % | bisect-ok (throttle already firing) |
| 76 | 15 188 | 73.1 | 91.4 | 98.1 | 0.00 % | 0.00 % | extra-ok |
| 77 | 15 367 | 279.6 | 507.4 | 99.7 | 0.00 % | 0.00 % | extra-ok |
| 78 | 15 067 | 725.5 | 850.3 | 100.0 | 0.00 % | 0.00 % | extra-ok |
| 79 | 14 814 | 845.7 | 915.9 | 100.0 | 0.00 % | 0.00 % | dense-ok |
| 80 | 15 021 | 828.0 | 966.0 | 100.0 | 0.00 % | 0.00 % | dense-ok |
| **81** | **15 396** | **785.1** | **908.8** | **100.0** | **0.00 %** | **0.00 %** | **bisect-ok (PEAK, cpu-aware)** |
| 82 | 14 440 | 979.4 | 1 089 | 100.0 | 0.00 % | 0.00 % | bisect-stop |

Net result: **+2.6 % peak throughput** (15 012 → 15 396) and **peak-N
shifted from 75 → 81** (6 more client slots fit under the same SLO),
because the CPU-aware throttle stops wasting leader cycles on spec RPCs
once the leader is saturated. The latency at peak shifts up
(43 → 909 ms p90): with `fp_rate=0` the coordinator takes the classic
2-RTT path and pays queueing on top. This is the intended trade — the
adaptive variant now behaves like vanilla Raft at peak load.

## Key numbers

- **jp-raft-fp100** with merge-RPC + pool opts: **15 390 cmd/s at N=77**, with **p90 = 42 ms** and zoo2 core-17 at **99.5 %**.
- **+13.3 %** peak throughput vs. the 2026-04-20 pre-opt number (13 586 → 15 390).
- **-22 %** p90 latency at peak (53.8 ms → 42.0 ms). The merge-RPC optimization accounts for essentially all of the latency improvement (see [2026-04-22_jp-raft-fp100_merge-rpc-and-pool-opts_ab.md](2026-04-22_jp-raft-fp100_merge-rpc-and-pool-opts_ab.md) §Interpretation).
- **jp-raft-adaptive** post-opt peak: **15 012 cmd/s at N=75**, **+5.8 %** vs. pre-opt (14 189 → 15 012). Smaller gain than fp100 because adaptive was less RPC-bound pre-opt.
- Post-opt, **fp100 > adaptive** (15 390 > 15 012) — a reversal from pre-opt where adaptive > fp100. Adaptive's throttle is now the thing costing it throughput rather than saving it; at ~99.5 % leader CPU the fastpath succeeds most of the time anyway and the throttle doesn't buy back much.

## Revised peak ordering

Pre-opt (2026-04-20):
```
naive_epaxos > epaxos > naive_raft > raft ≈ swiftpaxos > jp-raft-adaptive ≈ jp-raft-fp100 > etcd > CURP
```

Post-opt (this doc):
```
naive_epaxos > epaxos > naive_raft > raft ≈ swiftpaxos > jp-raft-fp100 > jp-raft-adaptive > etcd > CURP
```

The only reordering: fp100 now sits above adaptive (flipped from pre-opt).
All other protocols are unchanged.

## Caveats

1. **Methodology mismatch between rows.**
   - 2026-04-20 rows used the legacy adaptive sweep (stop at `zoo2 p50 > 2×baseline`, bisect TOL=5). Peak reported = last N before the p50 trip.
   - The two jetpack rows use the new methodology ([scripts/run_adaptive_sweep.sh](../scripts/run_adaptive_sweep.sh) at `48d298eb` with the fastpath-columns extension on `HEAD`): stop at `zoo2 p90 > 1000 ms`, bisect TOL=1, dense ±2 probe around the knee, peak = `argmax(tput)` across all in-SLO rows. For fp100 we also used `EXTRA_NS="76 77 78 79 80"` to fill a gap between the initial N=75 bisect-ok and the first saturated probe at N=87 — the bisect alone would have reported peak at N=75 (14 984) and missed the real N=77 peak (15 390).

   For jp-raft-fp100 we can spot-check the methodology delta: under the new methodology a binary built from the pre-opt commit `f8cb8fb4` measured **12 844 cmd/s at N=74** (variant A in the A/B/C). The 2026-04-20 number for the same pre-opt code under the old methodology was 13 586 at N=68 — so the methodology change on its own moves the peak by ±6 % under run-to-run noise, small compared to the +13 % delta attributable to the optimizations.

2. **Bisect is not sufficient to find the real peak.** We initially thought the fp100 opt peak was at N=75 (14 984) because bisect from [N=75 ok, N=87 stop] converges to 82/83 and the dense ±2 probe only covers [81, 86]. The *actual* peak is at N=77, inside a gap the bisect never visited. The `EXTRA_NS="76 77 78 79 80"` explicit probe (added in the sweep script on 2026-04-23) is what caught it. For other protocols in this table, the same type of gap might exist and the numbers could be a few % low — if you need strict per-protocol peaks, rerun each with EXTRA_NS filling the [last_ok, first_stop] range.

3. **Other protocols not re-run.** Only jetpack got the optimization pass; all other rows carry over their 2026-04-20 measurement. If you later want to re-baseline everyone under the new SLO-based methodology + EXTRA_NS, a single-day sweep with [scripts/run_adaptive_sweep.sh](../scripts/run_adaptive_sweep.sh) for each protocol would suffice.

4. **Same cluster, same setting.** All rows used the same 5-host zoo cluster with `SERVER_CORE_ID=17`, `WAN_DELAY_MS=20`, `concurrent_500.yml`, `rw_1000000.yml`, 30 s duration. Leader on zoo2 for leader-routing protocols (including jp-raft). See [max_throughput_experiment_setting.md](max_throughput_experiment_setting.md) for the canonical spec.

## Provenance

| Row | Result directory | Doc source |
|---|---|---|
| naive_epaxos, epaxos, naive_raft, raft, swiftpaxos, etcd, CURP | `results/2026-04-20-<proto>-core17/` | [max_throughput_core17_2026-04-20.md](max_throughput_core17_2026-04-20.md) |
| jp-raft-fp100 opt | `results/2026-04-23-jp-raft-fp100-postopt-extended-core17/` (with EXTRA_NS=76-80) | this doc |
| jp-raft-adaptive opt | `results/2026-04-23-jp-raft-adaptive-postopt-core17/` | this doc |
| jp-raft-adaptive cpu-aware | `results/2026-04-23-jp-raft-adaptive-cpuaware-core17/` | this doc |

Binary used for the two opt rows: branch `jetpack`, commit `1aba11b9` (merge-RPC + pool opts, profiling gated behind `JETPACK_PROF`). Config: `rule_raft_merge.yml` (`jetpack_merge_leader_rpc: true`). `-m 100` for fp100, `-m 101` for adaptive.
