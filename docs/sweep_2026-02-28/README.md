# Sweep Benchmark Results (2026-02-28)

**Status: FINAL (refreshed 2026-03-11)** — canonical 9-case artifacts were regenerated
from the accepted fresh-image pass `results/reproduce_20260310_164201/`
(accepted build commit `ff81e913`).

Concurrency sweep benchmarks for Jetpack across three backends (etcd, MongoDB,
ZooKeeper) and three modes (original, fastpath-100, adaptive).

## Configuration

| Parameter | Value |
|-----------|-------|
| Site config | `60c1s5r5p.yml` (60 clients, 1 site, 5 replicas, 5 processes) |
| Client config | `client_open.yml` |
| Latency | 20 ms |
| Duration | 30 s |
| Concurrency values | 1, 5, 10, 25, 50, 75, 100, 150, 200, 300, 400 |
| Max retries | 2 per point |
| Accepted sweep pass | `results/reproduce_20260310_164201/sweep/` |

## Canonical Data Files

### etcd

| Mode | TSV | Markdown | Peak (txn/s) | Status | Retry Sum |
|------|-----|----------|-------------|--------|-----------|
| Original | [etcd_original.tsv](etcd_original.tsv) | [etcd_original.md](etcd_original.md) | 7,743 @ c=150 | 11/11 OK | 0 |
| Fastpath-100 | [etcd_fastpath100.tsv](etcd_fastpath100.tsv) | [etcd_fastpath100.md](etcd_fastpath100.md) | 6,995 @ c=150 | 11/11 OK | 0 |
| Adaptive | [etcd_adaptive.tsv](etcd_adaptive.tsv) | [etcd_adaptive.md](etcd_adaptive.md) | 7,369 @ c=200 | 11/11 OK | 0 |

### MongoDB

| Mode | TSV | Markdown | Peak (txn/s) | Status | Retry Sum |
|------|-----|----------|-------------|--------|-----------|
| Original | [mongodb_original.tsv](mongodb_original.tsv) | [mongodb_original.md](mongodb_original.md) | 4,298 @ c=75 | 11/11 OK | 0 |
| Fastpath-100 | [mongodb_fastpath100.tsv](mongodb_fastpath100.tsv) | [mongodb_fastpath100.md](mongodb_fastpath100.md) | 3,380 @ c=200 | 11/11 OK | 0 |
| Adaptive | [mongodb_adaptive.tsv](mongodb_adaptive.tsv) | [mongodb_adaptive.md](mongodb_adaptive.md) | 3,873 @ c=75 | 11/11 OK | 1 |

### ZooKeeper

| Mode | TSV | Markdown | Peak (txn/s) | Status | Retry Sum |
|------|-----|----------|-------------|--------|-----------|
| Original | [zookeeper_original.tsv](zookeeper_original.tsv) | [zookeeper_original.md](zookeeper_original.md) | 5,564 @ c=150 | 11/11 OK | 0 |
| Fastpath-100 | [zookeeper_fastpath100.tsv](zookeeper_fastpath100.tsv) | [zookeeper_fastpath100.md](zookeeper_fastpath100.md) | 5,438 @ c=150 | 11/11 OK | 0 |
| Adaptive | [zookeeper_adaptive.tsv](zookeeper_adaptive.tsv) | [zookeeper_adaptive.md](zookeeper_adaptive.md) | 5,427 @ c=150 | 11/11 OK | 0 |

## Audit Artifacts

- [consolidated.csv](consolidated.csv) — 99 data rows, `99 OK / 0 PARTIAL / 0 FAILED`
- [CANONICAL_INDEX.md](CANONICAL_INDEX.md) — accepted dataset rationale + per-case peaks
- [FAILURE_LEDGER.md](FAILURE_LEDGER.md) — canonical retry/failure ledger with linked logs
- Per-run logs in [`logs/`](logs/)

## Superseded Datasets

Older datasets are preserved in [`archive/`](archive/) and in Git history.

## Scripts

- [`scripts/sweep_benchmark.sh`](../../scripts/sweep_benchmark.sh) - Run a concurrency sweep (with retry, failure classification, log saving, external CPU measurement)
- [`scripts/tsv_to_md.sh`](../../scripts/tsv_to_md.sh) - Regenerate Markdown tables from TSV files
- [`scripts/build_consolidated_csv.sh`](../../scripts/build_consolidated_csv.sh) - Regenerate consolidated CSV

## Analysis

See [`docs/latency_analysis.md`](../latency_analysis.md) for the benchmark analysis narrative.
