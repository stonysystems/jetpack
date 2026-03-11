# zookeeper_fastpath100

| Field | Value |
|-------|-------|
| Image | `jetpack-zookeeper-phase1e-leaf4` |
| Mode | `rule_zookeeper.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-10T23:58:16Z |
| Git commit | `f6de16b6` |
| Source | [`zookeeper_fastpath100.tsv`](zookeeper_fastpath100.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.70 | 8.00 | 8.00 | 7.80 | 7.90 | 8.00 | 397 | 397 | 100.00 | 6.7800 | 2.6728 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc1_attempt0.log | 0 |
| 5 | 274.40 | 54.70 | 55.50 | 53.60 | 56.30 | 54.30 | 2744 | 2744 | 100.00 | 7.2600 | 12.6361 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc5_attempt0.log | 0 |
| 10 | 569.90 | 114.90 | 113.40 | 113.50 | 115.30 | 112.80 | 5699 | 5699 | 100.00 | 7.6600 | 25.6373 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc10_attempt0.log | 0 |
| 25 | 1464.90 | 293.20 | 291.40 | 292.50 | 295.20 | 292.60 | 13332 | 13332 | 100.00 | 8.2600 | 66.7683 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc25_attempt0.log | 0 |
| 50 | 2969.60 | 589.80 | 594.10 | 596.00 | 592.30 | 597.40 | 15457 | 15457 | 100.00 | 10.4600 | 143.4062 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc50_attempt0.log | 0 |
| 75 | 4461.50 | 892.50 | 891.30 | 890.30 | 893.80 | 893.60 | 95 | 93 | 97.89 | 9.1400 | 383.3618 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc75_attempt0.log | 0 |
| 100 | 5344.60 | 1085.00 | 1061.80 | 1063.40 | 1068.90 | 1065.50 | 0 | 0 | 0 | 9.5000 | 1055.9229 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc100_attempt0.log | 0 |
| 150 | 5438.10 | 1094.90 | 1089.00 | 1084.20 | 1085.10 | 1084.90 | 0 | 0 | 0 | 9.8200 | 2601.9185 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc150_attempt0.log | 0 |
| 200 | 5403.70 | 1110.80 | 1071.60 | 1081.40 | 1074.20 | 1065.70 | 0 | 0 | 0 | 10.2800 | 5130.7517 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc200_attempt0.log | 0 |
| 300 | 5027.40 | 1035.00 | 1010.20 | 996.50 | 992.80 | 992.90 | 0 | 0 | 0 | 11.5300 | 5369.5590 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc300_attempt0.log | 0 |
| 400 | 5314.80 | 1052.20 | 1057.20 | 1076.10 | 1064.70 | 1064.60 | 0 | 0 | 0 | 12.4500 | 5791.4737 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-zookeeper-phase1e-leaf4_rule_zookeeper/conc400_attempt0.log | 0 |
