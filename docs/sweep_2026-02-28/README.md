# Sweep Benchmark Results (2026-02-28)

**Status: FINAL** — Full 9-case rerun completed 2026-03-02 (commit 194c32c1).
See [CANONICAL_INDEX.md](CANONICAL_INDEX.md) for dataset details.

Concurrency sweep benchmarks for Jetpack across three backends (etcd, MongoDB, ZooKeeper)
and three modes (original, fastpath-100, adaptive).

## Configuration

| Parameter | Value |
|-----------|-------|
| Site config | `60c1s5r5p.yml` (60 clients, 1 site, 5 replicas, 5 processes) |
| Client config | `client_open.yml` |
| Latency | 20 ms |
| Duration | 30 s |
| Concurrency values | 1, 5, 10, 25, 50, 75, 100, 150, 200, 300, 400 |
| Max retries | 2 per point |
| Docker images rebuilt | 2026-03-02 (with CPU instrumentation) |

## Canonical Data Files

### etcd

| Mode | TSV | Markdown | Peak (txn/s) | Failed | CPU |
|------|-----|----------|-------------|--------|-----|
| Original | [etcd_original.tsv](etcd_original.tsv) | [etcd_original.md](etcd_original.md) | 7,687 @ c=200 | 0/11 | 4.8-9.5% |
| Fastpath-100 | [etcd_fastpath100.tsv](etcd_fastpath100.tsv) | [etcd_fastpath100.md](etcd_fastpath100.md) | 6,749 @ c=400 | 0/11 | 4.2-11.4% |
| Adaptive | [etcd_adaptive.tsv](etcd_adaptive.tsv) | [etcd_adaptive.md](etcd_adaptive.md) | 7,323 @ c=200 | 0/11 | 4.2-10.6% |

### MongoDB

| Mode | TSV | Markdown | Peak (txn/s) | Failed | CPU |
|------|-----|----------|-------------|--------|-----|
| Original | [mongodb_original.tsv](mongodb_original.tsv) | [mongodb_original.md](mongodb_original.md) | 3,799 @ c=100 | 0/11 | 4.2-7.1% |
| Fastpath-100 | [mongodb_fastpath100.tsv](mongodb_fastpath100.tsv) | [mongodb_fastpath100.md](mongodb_fastpath100.md) | 3,200 @ c=200 | 0/11 | 4.7-6.4% |
| Adaptive | [mongodb_adaptive.tsv](mongodb_adaptive.tsv) | [mongodb_adaptive.md](mongodb_adaptive.md) | 3,858 @ c=100 | 0/11 | 4.1-8.1% |

### ZooKeeper

| Mode | TSV | Markdown | Peak (txn/s) | Failed | CPU |
|------|-----|----------|-------------|--------|-----|
| Original | [zookeeper_original.tsv](zookeeper_original.tsv) | [zookeeper_original.md](zookeeper_original.md) | 5,648 @ c=150 | 0/11 | 3.6-7.7% |
| Fastpath-100 | [zookeeper_fastpath100.tsv](zookeeper_fastpath100.tsv) | [zookeeper_fastpath100.md](zookeeper_fastpath100.md) | 5,456 @ c=300 | 0/11 | 3.3-8.1% |
| Adaptive | [zookeeper_adaptive.tsv](zookeeper_adaptive.tsv) | [zookeeper_adaptive.md](zookeeper_adaptive.md) | 5,486 @ c=150 | 0/11 | 3.2-8.3% |

## Audit Artifacts

- [consolidated.csv](consolidated.csv) — 99 data rows, all OK status
- [CANONICAL_INDEX.md](CANONICAL_INDEX.md) — Dataset selection rationale
- [FAILURE_LEDGER.md](FAILURE_LEDGER.md) — History of pre-rerun failures
- Per-run logs in [`logs/`](logs/)

## Superseded Datasets

Older or inferior versions are preserved in [`archive/`](archive/). See
[CANONICAL_INDEX.md](CANONICAL_INDEX.md) for the reason each was superseded.

## Scripts

- [`scripts/sweep_benchmark.sh`](../../scripts/sweep_benchmark.sh) - Run a concurrency sweep (with retry, failure classification, log saving, external CPU measurement)
- [`scripts/run_full_sweep.sh`](../../scripts/run_full_sweep.sh) - Run all 9 backend/mode sweeps
- [`scripts/tsv_to_md.sh`](../../scripts/tsv_to_md.sh) - Regenerate Markdown tables from TSV files
- [`scripts/build_consolidated_csv.sh`](../../scripts/build_consolidated_csv.sh) - Regenerate consolidated CSV

## Analysis

See [`docs/latency_analysis.md`](../latency_analysis.md) for the consolidated performance analysis.
