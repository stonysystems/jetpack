# zookeeper_adaptive_v1_old

| Field | Value |
|-------|-------|
| Image | `jetpack-zookeeper` |
| Mode | `rule_zookeeper.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Git commit | `31a95a57` |
| Source | [`zookeeper_adaptive_v1_old.tsv`](zookeeper_adaptive_v1_old.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 14.20 | 3.90 | 3.50 | 2.80 | 1.60 | 2.40 | 67 | 67 | 100.00 | 49.9877 | 8.6014 |
| 5 | 272.60 | 53.30 | 54.80 | 55.10 | 54.50 | 54.90 | 0 | 0 | 0 | 26.0134 | 13.4717 |
| 10 | 572.80 | 113.50 | 117.00 | 111.80 | 115.10 | 115.40 | 0 | 0 | 0 | 43.8818 | 26.8694 |
| 25 | 1466.00 | 292.90 | 289.60 | 297.80 | 293.60 | 292.10 | 0 | 0 | 0 | 63.0841 | 66.9478 |
| 50 | 1462.50 | 308.80 | 271.90 | 307.70 | 300.30 | 273.80 | 0 | 0 | 0 | 77.1748 | 137.0667 |
| 75 | 4418.00 | 881.70 | 872.80 | 890.50 | 880.40 | 892.60 | 0 | 0 | 0 | 83.3884 | 808.9171 |
| 100 | 0 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0 | 0 | 0 | 96.8387 | 5217.2588 |
| 150 | 4599.50 | 939.50 | 923.20 | 911.90 | 910.50 | 914.40 | 0 | 0 | 0 | 89.2388 | 4007.4701 |
| 200 | 4003.60 | 840.70 | 758.70 | 817.70 | 774.00 | 812.50 | 0 | 0 | 0 | 91.8717 | 6844.9397 |
| 300 | 5169.30 | 1044.50 | 1040.00 | 1020.80 | 1024.00 | 1040.00 | 0 | 0 | 0 | 97.4416 | 5501.1702 |
| 400 | 0 | 0.00 | 0.00 | 0.00 | 0.00 | 0.00 | 0 | 0 | 0 | 98.3333 | 5465.5661 |

### Failed/zero-throughput rows (2)

  - concurrency=100: 0 throughput
  - concurrency=400: 0 throughput

These rows were recorded before failure classification was added.
See [sweep_benchmark.sh](../../scripts/sweep_benchmark.sh) for the updated script with retry and failure tracking.
