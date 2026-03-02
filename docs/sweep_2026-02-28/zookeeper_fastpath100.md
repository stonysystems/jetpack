# zookeeper_fastpath100

| Field | Value |
|-------|-------|
| Image | `jetpack-zookeeper` |
| Mode | `rule_zookeeper.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Git commit | `31a95a57` |
| Source | [`zookeeper_fastpath100.tsv`](zookeeper_fastpath100.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.00 | 7.60 | 8.00 | 7.70 | 8.20 | 7.50 | 185 | 185 | 100.00 | 40.0379 | 2.6293 |
| 5 | 271.50 | 54.10 | 54.40 | 54.80 | 54.50 | 53.70 | 0 | 0 | 0 | 91.7821 | 12.0988 |
| 10 | 570.10 | 113.20 | 114.40 | 115.30 | 113.00 | 114.20 | 0 | 0 | 0 | 59.5378 | 26.0171 |
| 25 | 1472.10 | 292.80 | 293.50 | 295.60 | 294.90 | 295.30 | 0 | 0 | 0 | 84.5512 | 70.3399 |
| 50 | 2670.10 | 562.60 | 511.30 | 555.20 | 511.20 | 529.80 | 0 | 0 | 0 | 92.8962 | 122.8263 |
| 75 | 4452.40 | 876.60 | 891.70 | 889.20 | 899.90 | 895.00 | 0 | 0 | 0 | 97.7840 | 5421.6473 |
| 100 | 4723.00 | 957.60 | 940.50 | 941.20 | 940.00 | 943.70 | 0 | 0 | 0 | 91.6666 | 1451.2959 |
| 150 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| 200 | 4034.00 | 810.50 | 825.60 | 801.80 | 809.80 | 786.30 | 0 | 0 | 0 | 89.6202 | 6867.9108 |
| 300 | 0 | 0.00 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 81.5789 | 2799.4947 |
| 400 | 4390.40 | 942.00 | 840.00 | 860.20 | 880.00 | 868.20 | 0 | 0 | 0 | 96.6666 | 5587.4698 |

### Failed/zero-throughput rows (2)

  - concurrency=150: 0 throughput
  - concurrency=300: 0 throughput

These rows were recorded before failure classification was added.
See [sweep_benchmark.sh](../../scripts/sweep_benchmark.sh) for the updated script with retry and failure tracking.
