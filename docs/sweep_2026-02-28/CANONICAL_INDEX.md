# Canonical Dataset Index

One accepted dataset per backend/mode for the final report.
Superseded versions are in `archive/`.

| Backend | Mode | Canonical File | Peak (txn/s) | Failed Rows | CPU Metric | Reason | Date |
|---------|------|---------------|-------------|-------------|------------|--------|------|
| etcd | original | `etcd_original.tsv` | 7,687 @ c=200 | 0/11 | external /proc/stat | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| etcd | fastpath-100 | `etcd_fastpath100.tsv` | 6,749 @ c=400 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| etcd | adaptive | `etcd_adaptive.tsv` | 7,323 @ c=200 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| MongoDB | original | `mongodb_original.tsv` | 3,799 @ c=100 | 0/11 | external /proc/stat | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| MongoDB | fastpath-100 | `mongodb_fastpath100.tsv` | 3,200 @ c=200 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| MongoDB | adaptive | `mongodb_adaptive.tsv` | 3,858 @ c=100 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| ZooKeeper | original | `zookeeper_original.tsv` | 5,648 @ c=150 | 0/11 | external /proc/stat | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| ZooKeeper | fastpath-100 | `zookeeper_fastpath100.tsv` | 5,456 @ c=300 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |
| ZooKeeper | adaptive | `zookeeper_adaptive.tsv` | 5,486 @ c=150 | 0/11 | in-process leader | Full 9-case rerun 2026-03-02 | 2026-03-02 |

## Status

All 9 canonical datasets were generated from a **single consistent rerun** on 2026-03-02
using the current sweep script (`scripts/sweep_benchmark.sh`) with retry logic, failure
classification, and per-run log saving. All data points have real CPU measurements.

- **99/99 data points OK** (zero failed rows across all 9 datasets)
- **CPU metrics present for all modes** including original (`none_*.yml`)
  - Rule modes: in-process leader CPU from RPC responses
  - Original mode: external `/proc/stat` measurement during benchmark
- **Git commit**: 194c32c1
- **Docker images rebuilt**: 2026-03-02 (with CPU instrumentation from c1368ef4)
- **Consolidated CSV**: [`consolidated.csv`](consolidated.csv) (99 rows, all OK)
- **Previous history**: See [FAILURE_LEDGER.md](FAILURE_LEDGER.md) for the 12 pre-rerun failures
