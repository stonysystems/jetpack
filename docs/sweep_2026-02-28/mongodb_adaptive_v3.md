# mongodb_adaptive_v3

| Field | Value |
|-------|-------|
| Image | `jetpack-mongodb` |
| Mode | `rule_mongodb.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Git commit | `31a95a57` |
| Source | [`mongodb_adaptive_v3.tsv`](mongodb_adaptive_v3.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 40.80 | 7.70 | 7.80 | 8.30 | 8.40 | 8.60 | 382 | 382 | 100.00 | 71.2774 | 1.0000 |
| 5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 10 | 571.00 | 114.50 | 113.40 | 114.60 | 114.10 | 114.40 | 4661 | 4654 | 99.84 | 98.8234 | 1.0000 |
| 25 | 1462.50 | 292.80 | 293.50 | 292.40 | 292.20 | 291.60 | 11455 | 11452 | 99.97 | 99.9363 | 1.0000 |
| 50 | 1197.40 | 246.40 | 295.80 | 235.70 | 186.20 | 233.30 | 1365 | 306 | 22.41 | 82.9836 | 1.0000 |
| 75 | 2960.80 | 594.40 | 555.50 | 640.60 | 547.00 | 623.30 | 1733 | 1030 | 59.43 | 83.1194 | 1.0000 |
| 100 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 150 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 200 | 2459.80 | 499.90 | 480.00 | 480.00 | 500.00 | 499.90 | 1246 | 1033 | 82.90 | 87.8934 | 1.0000 |
| 300 | 2847.30 | 695.50 | 480.00 | 514.60 | 559.80 | 597.40 | 1452 | 1276 | 87.87 | 90.7306 | 1.0000 |
| 400 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

### Failed/zero-throughput rows (4)

  - concurrency=5: 0 throughput
  - concurrency=100: 0 throughput
  - concurrency=150: 0 throughput
  - concurrency=400: 0 throughput

These rows were recorded before failure classification was added.
See [sweep_benchmark.sh](../../scripts/sweep_benchmark.sh) for the updated script with retry and failure tracking.
