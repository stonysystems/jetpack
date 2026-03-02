# mongodb_adaptive

| Field | Value |
|-------|-------|
| Image | `jetpack-mongodb` |
| Mode | `rule_mongodb.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-02T20:49:22Z |
| Git commit | `194c32c1` |
| Source | [`mongodb_adaptive.tsv`](mongodb_adaptive.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 40.00 | 8.00 | 7.80 | 7.70 | 7.90 | 8.60 | 379 | 379 | 100.00 | 6.0400 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc1_attempt0.log | 0 |
| 5 | 274.10 | 55.70 | 54.70 | 54.40 | 55.30 | 54.00 | 2217 | 2217 | 100.00 | 6.6500 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc5_attempt0.log | 0 |
| 10 | 563.30 | 111.40 | 111.40 | 113.00 | 113.70 | 113.80 | 4574 | 4574 | 100.00 | 6.9800 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc10_attempt0.log | 0 |
| 25 | 1465.50 | 293.90 | 295.60 | 291.10 | 292.50 | 292.40 | 11876 | 11859 | 99.85 | 7.6000 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc25_attempt0.log | 0 |
| 50 | 2964.80 | 590.40 | 600.30 | 592.50 | 591.20 | 590.40 | 6252 | 5312 | 84.96 | 9.8700 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc50_attempt0.log | 0 |
| 75 | 3849.90 | 818.90 | 774.90 | 758.80 | 767.50 | 729.80 | 2167 | 1449 | 66.86 | 9.1800 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc75_attempt0.log | 0 |
| 100 | 3858.30 | 781.40 | 779.10 | 789.00 | 722.80 | 786.00 | 2058 | 1587 | 77.11 | 9.2300 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc100_attempt2.log | 2 |
| 150 | 3670.30 | 727.50 | 721.60 | 791.10 | 724.70 | 705.40 | 1839 | 1512 | 82.21 | 9.4500 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc150_attempt1.log | 1 |
| 200 | 3542.10 | 757.80 | 705.90 | 720.40 | 678.10 | 679.90 | 1809 | 1566 | 86.56 | 10.5800 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc200_attempt0.log | 0 |
| 300 | 3200.00 | 680.00 | 660.00 | 620.00 | 600.00 | 640.00 | 1629 | 1436 | 88.15 | 13.9000 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc300_attempt1.log | 1 |
| 400 | 1659.80 | 320.00 | 340.00 | 320.00 | 340.00 | 339.80 | 812 | 648 | 79.80 | 16.0000 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb_rule_mongodb/conc400_attempt0.log | 0 |
