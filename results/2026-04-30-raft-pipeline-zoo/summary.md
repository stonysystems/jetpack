# 2026-04-30-raft-pipeline-zoo — latency summary

Generated from `log/*.csv` (End2End-Latency column, milliseconds).

`tput (req/s)` = total commit samples in CSV ÷ 30 s nominal duration.

5 replicas on zoo-001..004 (s501 colocated with s201 on zoo-002),
WAN_DELAY_MS=100 → ~100 ms simulated RTT (WAN_WAIT applied only on
leader's send path; reply uses real loopback), n_concurrent=500.

Only zoo1 hosts the client (c01); follower hosts (zoo2-zoo4)
have empty CSVs by design — they're shown as 0-sample rows for completeness.

## V1-raw

_no batch, no pipeline (legacy serial loop)_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| zoo1 | 232 | 7.7 | 201.8 | 12555.0 | 22442.8 | 24670.6 | 24891.8 | 24916.4 | 12557.5 | 7165.2 |
| zoo2 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo3 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo4 | 0 | 0 | – | – | – | – | – | – | – | – |
| **integrated** | 232 | 7.7 | 201.8 | 12555.0 | 22442.8 | 24670.6 | 24891.8 | 24916.4 | 12557.5 | 7165.2 |

## V1-pipeline

_no batch, pipelined (cap=64 in-flight per follower)_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| zoo1 | 12712 | 423.7 | 100.5 | 111.6 | 139.4 | 690.9 | 863.2 | 893.2 | 137.1 | 95.3 |
| zoo2 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo3 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo4 | 0 | 0 | – | – | – | – | – | – | – | – |
| **integrated** | 12712 | 423.7 | 100.5 | 111.6 | 139.4 | 690.9 | 863.2 | 893.2 | 137.1 | 95.3 |

## V2-batch

_batch + no pipeline_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| zoo1 | 12373 | 412.4 | 102.8 | 142.4 | 177.4 | 194.7 | 202.2 | 206.3 | 144.7 | 22.4 |
| zoo2 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo3 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo4 | 0 | 0 | – | – | – | – | – | – | – | – |
| **integrated** | 12373 | 412.4 | 102.8 | 142.4 | 177.4 | 194.7 | 202.2 | 206.3 | 144.7 | 22.4 |

## V2-batch+pipeline

_batch + pipelined (cap=64 in-flight per follower)_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| zoo1 | 12197 | 406.6 | 100.4 | 103.2 | 108.7 | 119.5 | 120.5 | 120.6 | 104.4 | 3.7 |
| zoo2 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo3 | 0 | 0 | – | – | – | – | – | – | – | – |
| zoo4 | 0 | 0 | – | – | – | – | – | – | – | – |
| **integrated** | 12197 | 406.6 | 100.4 | 103.2 | 108.7 | 119.5 | 120.5 | 120.6 | 104.4 | 3.7 |

## Headline (integrated row, all variants)

| variant | samples | tput (req/s) | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | avg (ms) |
|---|---|---|---|---|---|---|---|
| V1-raw | 232 | 7.7 | 12555.0 | 22442.8 | 24670.6 | 24891.8 | 12557.5 |
| V1-pipeline | 12712 | 423.7 | 111.6 | 139.4 | 690.9 | 863.2 | 137.1 |
| V2-batch | 12373 | 412.4 | 142.4 | 177.4 | 194.7 | 202.2 | 144.7 |
| V2-batch+pipeline | 12197 | 406.6 | 103.2 | 108.7 | 119.5 | 120.5 | 104.4 |

