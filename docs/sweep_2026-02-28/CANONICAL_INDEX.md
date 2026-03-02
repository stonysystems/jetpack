# Canonical Dataset Index

One accepted dataset per backend/mode for the final report.
Superseded versions are in `archive/`.

| Backend | Mode | Canonical File | Peak (txn/s) | Failed Rows | Superseded Files | Reason | Date |
|---------|------|---------------|-------------|-------------|-----------------|--------|------|
| etcd | original | `etcd_original.tsv` | 7,709 @ c=150 | 0/11 | — | Only version | 2026-02-28 |
| etcd | fastpath-100 | `etcd_fastpath100.tsv` | 6,545 @ c=200 | 0/11 | — | Rerun 2026-03-02 fixed 3 failures | 2026-02-28 |
| etcd | adaptive | `etcd_adaptive.tsv` | 6,728 @ c=150 | 0/11 | v1_old, v2, v3 | Rerun 2026-03-02 fixed 2 failures | 2026-02-28 |
| MongoDB | original | `mongodb_original.tsv` | 3,681 @ c=75 | 0/11 | — | Rerun 2026-03-02 fixed 2 failures | 2026-02-28 |
| MongoDB | fastpath-100 | `mongodb_fastpath100.tsv` | 3,370 @ c=150 | 0/11 | — | Rerun 2026-03-02 fixed 1 failure | 2026-02-28 |
| MongoDB | adaptive | `mongodb_adaptive.tsv` | 3,773 @ c=75 | 0/11 | v2, v3 | Rerun 2026-03-02 fixed 2 failures | 2026-02-28 |
| ZooKeeper | original | `zookeeper_original.tsv` | 4,854 @ c=200 | 0/11 | — | Only version | 2026-02-28 |
| ZooKeeper | fastpath-100 | `zookeeper_fastpath100.tsv` | 5,922 @ c=300 | 0/11 | — | Rerun 2026-03-02 fixed 2 failures | 2026-02-28 |
| ZooKeeper | adaptive | `zookeeper_adaptive.tsv` | 5,408 @ c=300 | 0/11 | v1_old, v2, v3 | Zero failures | 2026-02-28 |

## Status

All 9 canonical datasets now have **zero failed rows**. The 12 previously failed
data points were rerun on 2026-03-02 (commit 8ba5d49e) and all succeeded.
See [FAILURE_LEDGER.md](FAILURE_LEDGER.md) for details.

Remaining: original-mode files still lack CPU/queue-depth metrics (pending Docker
image rebuild with the instrumentation fix from commit c1368ef4).
