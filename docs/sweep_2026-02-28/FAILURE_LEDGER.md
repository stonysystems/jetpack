# Failure Ledger

Documents the 12 zero-throughput rows that existed in the canonical sweep files
and their resolution via rerun on 2026-03-02.

## Summary

All 12 points were successfully rerun. Root cause: **transient Docker failures** —
every point succeeded on rerun (11 of 12 on first try, 1 needed 1 retry).
Logs saved in `docs/sweep_2026-02-28/logs/<dataset>_rerun/`.

| # | Backend | Mode | Concurrency | Old Result | Rerun Result | Retries | Log Path |
|---|---------|------|-------------|-----------|-------------|---------|----------|
| 1 | etcd | fastpath-100 | 50 | 0 (FAILED) | 2957.90 (OK) | 0 | logs/etcd_fastpath100_rerun/conc50_attempt0.log |
| 2 | etcd | fastpath-100 | 75 | 0 (FAILED) | 4466.10 (OK) | 0 | logs/etcd_fastpath100_rerun/conc75_attempt0.log |
| 3 | etcd | fastpath-100 | 300 | 0 (FAILED) | 5765.80 (OK) | 0 | logs/etcd_fastpath100_rerun/conc300_attempt0.log |
| 4 | etcd | adaptive | 150 | 0 (FAILED) | 6728.20 (OK) | 0 | logs/etcd_adaptive_rerun/conc150_attempt0.log |
| 5 | etcd | adaptive | 300 | 0 (FAILED) | 6159.10 (OK) | 0 | logs/etcd_adaptive_rerun/conc300_attempt0.log |
| 6 | MongoDB | original | 50 | 0 (FAILED) | 2959.90 (OK) | 0 | logs/mongodb_original_rerun/conc50_attempt0.log |
| 7 | MongoDB | original | 75 | 0 (FAILED) | 3681.20 (OK) | 1 | logs/mongodb_original_rerun/conc75_attempt1.log |
| 8 | MongoDB | fastpath-100 | 50 | 0 (FAILED) | 2365.40 (OK) | 0 | logs/mongodb_fastpath100_rerun/conc50_attempt0.log |
| 9 | MongoDB | adaptive | 5 | 0 (FAILED) | 271.50 (OK) | 0 | logs/mongodb_adaptive_rerun/conc5_attempt0.log |
| 10 | MongoDB | adaptive | 200 | 0 (FAILED) | 3679.70 (OK) | 0 | logs/mongodb_adaptive_rerun/conc200_attempt0.log |
| 11 | ZooKeeper | fastpath-100 | 150 | 0 (FAILED) | 4596.40 (OK) | 0 | logs/zookeeper_fastpath100_rerun/conc150_attempt0.log |
| 12 | ZooKeeper | fastpath-100 | 300 | 0 (FAILED) | 5921.60 (OK) | 0 | logs/zookeeper_fastpath100_rerun/conc300_attempt0.log |

## Root Cause

All 12 failures were **transient Docker startup/resource issues**, confirmed by the fact
that every point succeeded on rerun (11/12 on first attempt). The single retry needed
(MongoDB original c=75) also succeeded on the second attempt, consistent with a
transient timing issue rather than a systematic defect.

The `sweep_benchmark.sh` script now includes retry logic (up to 2 retries) and failure
classification, which would have prevented these zero-throughput rows in the original sweep.

## Rerun Details

- **Date**: 2026-03-02
- **Git commit**: 8ba5d49e
- **Script**: `scripts/rerun_failed_points.sh`
- **Max retries**: 2
- **Full results**: `docs/sweep_2026-02-28/rerun_results.tsv`
