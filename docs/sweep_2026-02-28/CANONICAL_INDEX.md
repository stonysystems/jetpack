# Canonical Dataset Index

Accepted dataset for the 9-case throughput matrix.

All canonical files in this folder were refreshed from the accepted pass
`results/reproduce_20260310_164201/sweep/` (accepted build commit `ff81e913`).

| Backend | Mode | Canonical File | Peak (txn/s) | Status | Retry Sum | Source Date |
|---------|------|---------------|-------------|--------|-----------|-------------|
| etcd | original | `etcd_original.tsv` | 7,743 @ c=150 | 11/11 OK | 0 | 2026-03-10 |
| etcd | fastpath-100 | `etcd_fastpath100.tsv` | 6,995 @ c=150 | 11/11 OK | 0 | 2026-03-10 |
| etcd | adaptive | `etcd_adaptive.tsv` | 7,369 @ c=200 | 11/11 OK | 0 | 2026-03-10 |
| MongoDB | original | `mongodb_original.tsv` | 4,298 @ c=75 | 11/11 OK | 0 | 2026-03-10 |
| MongoDB | fastpath-100 | `mongodb_fastpath100.tsv` | 3,380 @ c=200 | 11/11 OK | 0 | 2026-03-10 |
| MongoDB | adaptive | `mongodb_adaptive.tsv` | 3,873 @ c=75 | 11/11 OK | 1 | 2026-03-10 |
| ZooKeeper | original | `zookeeper_original.tsv` | 5,564 @ c=150 | 11/11 OK | 0 | 2026-03-10 |
| ZooKeeper | fastpath-100 | `zookeeper_fastpath100.tsv` | 5,438 @ c=150 | 11/11 OK | 0 | 2026-03-10 |
| ZooKeeper | adaptive | `zookeeper_adaptive.tsv` | 5,427 @ c=150 | 11/11 OK | 0 | 2026-03-11 |

## Status

- **99/99 rows OK** across all 9 canonical TSV files.
- **0 PARTIAL, 0 FAILED** rows in canonical TSVs.
- **Retry sum = 1** across canonical TSVs (MongoDB adaptive `c=1`, succeeded on retry).
- **Consolidated CSV**: [`consolidated.csv`](consolidated.csv) (99 rows).
- **Retry/failure log links**: [`FAILURE_LEDGER.md`](FAILURE_LEDGER.md).

## Notes

- `error_summary` contains `;timeout` in many OK rows because current
  `detect_failure_signature()` matches benchmark text containing `"timeout:"`.
  Status and retry columns remain authoritative for success/failure.
- Historical pre-refresh datasets and reruns remain available in this folder
  (for example `rerun_results.tsv`) and Git history.
