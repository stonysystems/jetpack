# Codex Independent Evaluation Review Report

## 1. Scope

This pass executes the first high-priority leaf task from `TODO_codex.md`:
`Phase 1A: Low-Concurrency Latency Sanity Check`.

Included:
- Internal consistency check of documented low-concurrency latency claims in `docs/latency_analysis.md` and `result.md`.
- Numerical sanity check against the documented model (`Jetpack OFF: h2-h5 ~= h1 + 40ms`; `Jetpack ON fast path ~= 40ms`).

Not yet executed in this pass:
- Phase 1B/1C artifact sweep and recovery-claim audit.
- Phase 2 benchmark reruns.
- Phase 3 failure-recovery reruns.

## 2. Environment

- UTC timestamp (analysis pass): 2026-03-07T19:56:41Z
- Git branch: `jetpack`
- Git commit at start: `3c92ebec`
- Repository root: `/home/shuai/workspace/jetpack`
- Full-test-suite attempt status:
  - `./test_run.py` failed because `build/deptran_server` was missing, then hit a pre-existing `NameError` (`except Error`) in the script.
  - `python3 waf configure build -d` failed on Python 3.13 (`ModuleNotFoundError: imp` in waflib).
  - `python2 waf configure build -d -D` progressed but failed to compile due missing MongoDB C++ headers (`mongocxx/instance.hpp`).

## 3. Docs Reviewed

- `TODO_codex.md`
- `docs/latency_analysis.md`
- `result.md`
- `docs/benchmark_runbook.md`

## 4. Existing Claims Checked

Claims checked for low-concurrency (`concurrency=1`) latency behavior:

- Jetpack OFF:
  - etcd: `h1=43.6ms`, `h2-h5=83.7ms`
  - MongoDB: `h1=47.7ms`, `h2-h5=88.0ms`
  - ZooKeeper: `h1=45.5ms`, `h2-h5=86.0ms`
  - Expected relation: `h2-h5 ~= h1 + 40ms`
- Jetpack ON fast path:
  - etcd: `40.4-40.7ms`
  - MongoDB: `45.2-45.9ms`
  - ZooKeeper: `40.3-40.5ms`
  - Expected relation: all clients around one RTT (`~40ms`).

Consistency across docs:
- `docs/latency_analysis.md` and `result.md` report matching values for the six low-concurrency rows.

## 5. Sanity Check Review

Computed deltas from documented values:

| Backend | OFF h1 (ms) | OFF h2-h5 (ms) | OFF delta (ms) | OFF delta - 40ms | ON h1 (ms) | ON h2-h5 (ms) | ON h1 - 40ms | ON h2-h5 - 40ms | ON spread |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| etcd | 43.6 | 83.7 | 40.1 | +0.1 | 40.4 | 40.7 | +0.4 | +0.7 | 0.3 |
| MongoDB | 47.7 | 88.0 | 40.3 | +0.3 | 45.2 | 45.9 | +5.2 | +5.9 | 0.7 |
| ZooKeeper | 45.5 | 86.0 | 40.5 | +0.5 | 40.3 | 40.5 | +0.3 | +0.5 | 0.2 |

Assessment:
- OFF-mode deltas (`h2-h5 - h1`) are `40.1ms`, `40.3ms`, `40.5ms`, which is tightly consistent with the stated 40ms RTT model.
- ON-mode etcd and ZooKeeper values are very close to 40ms.
- ON-mode MongoDB is consistently higher by ~5-6ms versus the simple 40ms model; this is still directionally consistent with "~1 RTT" behavior but indicates backend/protocol overhead beyond the idealized bound.

Evidence-strength classification for this pass:
- Documented claim: YES.
- Artifact-backed from reviewed low-concurrency raw logs/TSV in this pass: PARTIAL.
  - The swept TSVs in `docs/sweep_2026-02-28/*.tsv` are throughput-oriented and do not directly expose the exact `43.6/83.7/...` latency table values.
  - Therefore, this pass validates internal numerical consistency of docs, but not full raw-log provenance for each latency number.

## 6. Benchmark Rerun Attempts

No benchmark rerun executed in this pass (scope limited to Phase 1A first leaf task).

## 7. Failure Recovery Rerun Attempts

No recovery rerun executed in this pass (scope limited to Phase 1A first leaf task).

## 8. Discrepancies and Risks

- MongoDB fast-path latency (`45.2-45.9ms`) is above the nominal `~40ms` expectation by ~5-6ms.
  - Risk: wording like "around 40ms" is acceptable but slightly optimistic for MongoDB.
- Exact provenance of low-concurrency latency table entries was not established from raw low-concurrency logs in this pass.
  - Risk: claims are internally consistent across docs, but artifact traceability remains incomplete until log-level verification.
- Regression tests could not be completed in this environment due missing build/runtime prerequisites.
  - Risk: this pass cannot claim runtime non-regression, only documentation-level consistency checks.

## 9. Conclusion

For the Phase 1A low-concurrency sanity check, the published numbers are internally consistent and satisfy the key OFF-mode RTT-delta rule (`h2-h5 ~= h1 + 40ms`) for all three backends. Jetpack ON behavior is consistent with one-RTT latency shape, with a moderate MongoDB overhead above the idealized 40ms target. Full artifact-backed verification of each latency datum remains pending.

## 10. Appendix: Commands and Evidence

Key commands used:

```bash
git pull
rg -n "h1|h2-h5|40ms|Jetpack OFF|Jetpack ON|etcd|MongoDB|ZooKeeper|low-concurrency|sanity" docs/latency_analysis.md result.md docs/benchmark_runbook.md
rg -n "43\.6|83\.7|47\.7|88\.0|45\.5|86\.0|40\.4|40\.7|45\.2|45\.9|40\.3|40\.5" docs result.md
./test_run.py
python3 waf configure build -d
python2 waf configure build -d -D
```

Numerical check command:

```bash
cat <<'EOF' | awk 'BEGIN{printf "backend\toff_h1\toff_h2\toff_delta\toff_delta_minus_40\ton_h1\ton_h2\ton_h1_minus_40\ton_h2_minus_40\ton_spread\n"} NR>1 {off_delta=$3-$2; printf "%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\n",$1,$2,$3,off_delta,off_delta-40,$4,$5,$4-40,$5-40,$5-$4}'
backend off_h1 off_h2 on_h1 on_h2
etcd 43.6 83.7 40.4 40.7
mongodb 47.7 88.0 45.2 45.9
zookeeper 45.5 86.0 40.3 40.5
EOF
```

Output:

```text
backend   off_h1 off_h2 off_delta off_delta_minus_40 on_h1 on_h2 on_h1_minus_40 on_h2_minus_40 on_spread
etcd      43.6   83.7   40.1      0.1               40.4  40.7  0.4            0.7            0.3
mongodb   47.7   88.0   40.3      0.3               45.2  45.9  5.2            5.9            0.7
zookeeper 45.5   86.0   40.5      0.5               40.3  40.5  0.3            0.5            0.2
```
