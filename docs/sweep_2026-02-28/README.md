# Sweep Benchmark Results (2026-02-28)

**Status: DRAFT** — under quality review. See [CANONICAL_INDEX.md](CANONICAL_INDEX.md) for
the accepted dataset per backend/mode and supersession rationale.

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

## Canonical Data Files

### etcd

| Mode | TSV | Markdown | Peak (txn/s) | Failed |
|------|-----|----------|-------------|--------|
| Original | [etcd_original.tsv](etcd_original.tsv) | [etcd_original.md](etcd_original.md) | 7,709 @ c=150 | 0/11 |
| Fastpath-100 | [etcd_fastpath100.tsv](etcd_fastpath100.tsv) | [etcd_fastpath100.md](etcd_fastpath100.md) | 6,545 @ c=200 | 3/11 |
| Adaptive | [etcd_adaptive.tsv](etcd_adaptive.tsv) | [etcd_adaptive.md](etcd_adaptive.md) | 6,672 @ c=200 | 2/11 |

### MongoDB

| Mode | TSV | Markdown | Peak (txn/s) | Failed |
|------|-----|----------|-------------|--------|
| Original | [mongodb_original.tsv](mongodb_original.tsv) | [mongodb_original.md](mongodb_original.md) | 3,183 @ c=200 | 2/11 |
| Fastpath-100 | [mongodb_fastpath100.tsv](mongodb_fastpath100.tsv) | [mongodb_fastpath100.md](mongodb_fastpath100.md) | 3,370 @ c=150 | 1/11 |
| Adaptive | [mongodb_adaptive.tsv](mongodb_adaptive.tsv) | [mongodb_adaptive.md](mongodb_adaptive.md) | 3,773 @ c=75 | 2/11 |

### ZooKeeper

| Mode | TSV | Markdown | Peak (txn/s) | Failed |
|------|-----|----------|-------------|--------|
| Original | [zookeeper_original.tsv](zookeeper_original.tsv) | [zookeeper_original.md](zookeeper_original.md) | 4,854 @ c=200 | 0/11 |
| Fastpath-100 | [zookeeper_fastpath100.tsv](zookeeper_fastpath100.tsv) | [zookeeper_fastpath100.md](zookeeper_fastpath100.md) | 4,723 @ c=100 | 2/11 |
| Adaptive | [zookeeper_adaptive.tsv](zookeeper_adaptive.tsv) | [zookeeper_adaptive.md](zookeeper_adaptive.md) | 5,408 @ c=300 | 0/11 |

## Superseded Datasets

Older or inferior versions are preserved in [`archive/`](archive/). See
[CANONICAL_INDEX.md](CANONICAL_INDEX.md) for the reason each was superseded.

## Scripts

- [`scripts/sweep_benchmark.sh`](../../scripts/sweep_benchmark.sh) - Run a concurrency sweep (with retry, failure classification, log saving)
- [`scripts/tsv_to_md.sh`](../../scripts/tsv_to_md.sh) - Regenerate Markdown tables from TSV files

## Known Issues

- Some canonical files still contain zero-throughput rows recorded before failure
  classification was added. These are noted in each Markdown file.
- Original-mode files lack CPU/queue-depth metrics (all zeros).
- The updated `sweep_benchmark.sh` now classifies failures, retries, and saves logs.

## Analysis

See [`docs/latency_analysis.md`](../latency_analysis.md) for the consolidated performance analysis.
