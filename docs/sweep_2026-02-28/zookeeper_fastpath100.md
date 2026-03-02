# zookeeper_fastpath100

| Field | Value |
|-------|-------|
| Image | `jetpack-zookeeper` |
| Mode | `rule_zookeeper.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-02T21:41:53Z |
| Git commit | `194c32c1` |
| Source | [`zookeeper_fastpath100.tsv`](zookeeper_fastpath100.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 41.30 | 8.30 | 8.30 | 7.90 | 8.00 | 8.80 | 413 | 413 | 100.00 | 4.1800 | 2.7301 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc1_attempt0.log | 0 |
| 5 | 271.30 | 53.50 | 54.80 | 54.90 | 54.20 | 53.90 | 2713 | 2713 | 100.00 | 7.2600 | 12.7890 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc5_attempt0.log | 0 |
| 10 | 573.70 | 114.10 | 115.20 | 114.40 | 115.50 | 114.50 | 5737 | 5737 | 100.00 | 9.2400 | 25.4055 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc10_attempt0.log | 0 |
| 25 | 1467.70 | 291.70 | 293.00 | 292.70 | 294.60 | 295.70 | 13495 | 13495 | 100.00 | 9.3300 | 66.4539 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc25_attempt0.log | 0 |
| 50 | 2959.20 | 595.50 | 590.60 | 591.90 | 592.40 | 588.80 | 16616 | 16616 | 100.00 | 6.4500 | 138.5513 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc50_attempt0.log | 0 |
| 75 | 4458.60 | 896.40 | 892.60 | 891.80 | 889.60 | 888.20 | 47 | 47 | 100.00 | 11.2900 | 410.5087 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc75_attempt0.log | 0 |
| 100 | 4743.00 | 961.40 | 945.40 | 943.00 | 945.00 | 948.20 | 0 | 0 | 0 | 9.4700 | 935.1416 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc100_attempt0.log | 0 |
| 150 | 4729.90 | 958.80 | 943.00 | 943.00 | 941.00 | 944.10 | 0 | 0 | 0 | 9.5300 | 3819.3746 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc150_attempt0.log | 0 |
| 200 | 5436.40 | 1106.70 | 1078.50 | 1086.90 | 1081.00 | 1083.30 | 0 | 0 | 0 | 11.9400 | 5045.6490 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc200_attempt0.log | 0 |
| 300 | 5456.40 | 1086.00 | 1098.50 | 1079.80 | 1079.40 | 1112.70 | 0 | 0 | 0 | 11.9000 | 4745.2596 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc300_attempt0.log | 0 |
| 400 | 4930.80 | 1023.80 | 988.50 | 979.00 | 968.50 | 971.00 | 0 | 0 | 0 | 14.2700 | 5417.5591 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc400_attempt0.log | 0 |
