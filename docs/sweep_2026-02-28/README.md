# Sweep Benchmark Results (2026-02-28)

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

## Data Files

### etcd

| Mode | TSV | Markdown | Notes |
|------|-----|----------|-------|
| Original | [etcd_original.tsv](etcd_original.tsv) | [etcd_original.md](etcd_original.md) | |
| Fastpath-100 | [etcd_fastpath100.tsv](etcd_fastpath100.tsv) | [etcd_fastpath100.md](etcd_fastpath100.md) | |
| Adaptive | [etcd_adaptive.tsv](etcd_adaptive.tsv) | [etcd_adaptive.md](etcd_adaptive.md) | Latest |
| Adaptive v3 | [etcd_adaptive_v3.tsv](etcd_adaptive_v3.tsv) | [etcd_adaptive_v3.md](etcd_adaptive_v3.md) | |
| Adaptive v2 | [etcd_adaptive_v2.tsv](etcd_adaptive_v2.tsv) | [etcd_adaptive_v2.md](etcd_adaptive_v2.md) | |
| Adaptive v1 (old) | [etcd_adaptive_v1_old.tsv](etcd_adaptive_v1_old.tsv) | [etcd_adaptive_v1_old.md](etcd_adaptive_v1_old.md) | Superseded |

### MongoDB

| Mode | TSV | Markdown | Notes |
|------|-----|----------|-------|
| Original | [mongodb_original.tsv](mongodb_original.tsv) | [mongodb_original.md](mongodb_original.md) | |
| Fastpath-100 | [mongodb_fastpath100.tsv](mongodb_fastpath100.tsv) | [mongodb_fastpath100.md](mongodb_fastpath100.md) | |
| Adaptive | [mongodb_adaptive.tsv](mongodb_adaptive.tsv) | [mongodb_adaptive.md](mongodb_adaptive.md) | Latest |
| Adaptive v3 | [mongodb_adaptive_v3.tsv](mongodb_adaptive_v3.tsv) | [mongodb_adaptive_v3.md](mongodb_adaptive_v3.md) | |
| Adaptive v2 | [mongodb_adaptive_v2.tsv](mongodb_adaptive_v2.tsv) | [mongodb_adaptive_v2.md](mongodb_adaptive_v2.md) | |

### ZooKeeper

| Mode | TSV | Markdown | Notes |
|------|-----|----------|-------|
| Original | [zookeeper_original.tsv](zookeeper_original.tsv) | [zookeeper_original.md](zookeeper_original.md) | |
| Fastpath-100 | [zookeeper_fastpath100.tsv](zookeeper_fastpath100.tsv) | [zookeeper_fastpath100.md](zookeeper_fastpath100.md) | |
| Adaptive | [zookeeper_adaptive.tsv](zookeeper_adaptive.tsv) | [zookeeper_adaptive.md](zookeeper_adaptive.md) | Latest |
| Adaptive v3 | [zookeeper_adaptive_v3.tsv](zookeeper_adaptive_v3.tsv) | [zookeeper_adaptive_v3.md](zookeeper_adaptive_v3.md) | |
| Adaptive v2 | [zookeeper_adaptive_v2.tsv](zookeeper_adaptive_v2.tsv) | [zookeeper_adaptive_v2.md](zookeeper_adaptive_v2.md) | |
| Adaptive v1 (old) | [zookeeper_adaptive_v1_old.tsv](zookeeper_adaptive_v1_old.tsv) | [zookeeper_adaptive_v1_old.md](zookeeper_adaptive_v1_old.md) | Superseded |

## Scripts

- [`scripts/sweep_benchmark.sh`](../../scripts/sweep_benchmark.sh) - Run a concurrency sweep (with retry, failure classification, log saving)
- [`scripts/tsv_to_md.sh`](../../scripts/tsv_to_md.sh) - Regenerate Markdown tables from TSV files

## Known Issues

Some data points show 0 throughput due to Docker failures that were not retried or classified
in earlier sweep runs. These are noted in each Markdown file's "Failed/zero-throughput rows"
section. The updated `sweep_benchmark.sh` now classifies failures, retries, and saves logs.

## Analysis

See [`docs/latency_analysis.md`](../latency_analysis.md) for the consolidated performance analysis.
