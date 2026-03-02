# Canonical Dataset Index

One accepted dataset per backend/mode for the final report.
Superseded versions are in `archive/`.

| Backend | Mode | Canonical File | Peak (txn/s) | Failed Rows | Superseded Files | Reason | Date |
|---------|------|---------------|-------------|-------------|-----------------|--------|------|
| etcd | original | `etcd_original.tsv` | 7,709 @ c=150 | 0/11 | — | Only version | 2026-02-28 |
| etcd | fastpath-100 | `etcd_fastpath100.tsv` | 6,545 @ c=200 | 3/11 | — | Only version | 2026-02-28 |
| etcd | adaptive | `etcd_adaptive.tsv` | 6,672 @ c=200 | 2/11 | v1_old (lower peak 6,584), v2 (lowest peak 6,277), v3 (identical duplicate) | Highest peak, complete metrics | 2026-02-28 |
| MongoDB | original | `mongodb_original.tsv` | 3,183 @ c=200 | 2/11 | — | Only version | 2026-02-28 |
| MongoDB | fastpath-100 | `mongodb_fastpath100.tsv` | 3,370 @ c=150 | 1/11 | — | Only version | 2026-02-28 |
| MongoDB | adaptive | `mongodb_adaptive.tsv` | 3,773 @ c=75 | 2/11 | v2 (3 failures, lower peak 3,591), v3 (4 failures, lowest peak 2,961) | Highest peak, fewest failures | 2026-02-28 |
| ZooKeeper | original | `zookeeper_original.tsv` | 4,854 @ c=200 | 0/11 | — | Only version | 2026-02-28 |
| ZooKeeper | fastpath-100 | `zookeeper_fastpath100.tsv` | 4,723 @ c=100 | 2/11 | — | Only version | 2026-02-28 |
| ZooKeeper | adaptive | `zookeeper_adaptive.tsv` | 5,408 @ c=300 | 0/11 | v1_old (lower peak 5,169), v2 (4 failures, peak 4,370), v3 (identical duplicate) | Zero failures, highest peak, complete metrics | 2026-02-28 |

## Status

**Draft** — sweep is re-opened for quality review. Known issues:
- Some canonical files still contain zero-throughput rows without failure classification
  (recorded before `sweep_benchmark.sh` was updated with retry/status logic).
- Original-mode files lack CPU/queue-depth metrics (all zeros).
- MongoDB adaptive data has inconsistent peaks across versions.
