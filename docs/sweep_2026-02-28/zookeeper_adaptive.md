# zookeeper_adaptive

| Field | Value |
|-------|-------|
| Image | `jetpack-zookeeper` |
| Mode | `rule_zookeeper.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-02T21:56:26Z |
| Git commit | `194c32c1` |
| Source | [`zookeeper_adaptive.tsv`](zookeeper_adaptive.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.30 | 8.00 | 7.60 | 7.70 | 8.00 | 8.00 | 393 | 393 | 100.00 | 6.6300 | 2.6624 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc1_attempt0.log | 0 |
| 5 | 272.70 | 54.50 | 53.80 | 53.90 | 55.30 | 55.20 | 2727 | 2727 | 100.00 | 7.2900 | 12.6260 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc5_attempt0.log | 0 |
| 10 | 567.20 | 115.00 | 112.00 | 112.80 | 113.10 | 114.30 | 5672 | 5672 | 100.00 | 7.5900 | 25.3887 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc10_attempt0.log | 0 |
| 25 | 1462.80 | 291.30 | 293.90 | 290.70 | 292.80 | 294.10 | 13430 | 13430 | 100.00 | 6.0900 | 66.0173 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc25_attempt0.log | 0 |
| 50 | 2958.30 | 587.80 | 590.90 | 592.10 | 595.70 | 591.80 | 14633 | 14633 | 100.00 | 5.4800 | 143.6791 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc50_attempt0.log | 0 |
| 75 | 4459.10 | 892.90 | 893.40 | 889.50 | 894.50 | 888.80 | 252 | 252 | 100.00 | 5.7900 | 327.4907 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc75_attempt0.log | 0 |
| 100 | 5054.20 | 1027.90 | 1006.40 | 1006.50 | 1008.20 | 1005.20 | 0 | 0 | 0 | 6.7200 | 1022.2242 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc100_attempt0.log | 0 |
| 150 | 5486.00 | 1097.50 | 1090.60 | 1092.20 | 1118.70 | 1087.00 | 0 | 0 | 0 | 5.9300 | 3084.9261 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc150_attempt0.log | 0 |
| 200 | 4620.80 | 943.10 | 926.10 | 911.60 | 917.40 | 922.60 | 0 | 0 | 0 | 6.9300 | 4969.5728 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc200_attempt0.log | 0 |
| 300 | 5380.30 | 1063.80 | 1071.10 | 1096.50 | 1069.50 | 1079.40 | 0 | 0 | 0 | 8.6900 | 5090.6952 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc300_attempt0.log | 0 |
| 400 | 5422.80 | 1120.60 | 1076.80 | 1083.20 | 1067.10 | 1075.10 | 0 | 0 | 0 | 9.4400 | 5927.9521 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper_rule_zookeeper/conc400_attempt0.log | 0 |
