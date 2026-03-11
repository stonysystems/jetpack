# mongodb_fastpath100

| Field | Value |
|-------|-------|
| Image | `jetpack-mongodb-phase1e-leaf3` |
| Mode | `rule_mongodb.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-10T22:18:57Z |
| Git commit | `f6de16b6` |
| Source | [`mongodb_fastpath100.tsv`](mongodb_fastpath100.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 40.20 | 8.20 | 8.00 | 7.80 | 7.80 | 8.40 | 402 | 402 | 100.00 | 8.4900 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc1_attempt0.log | 0 |
| 5 | 272.30 | 54.50 | 54.40 | 54.50 | 53.40 | 55.50 | 2723 | 2723 | 100.00 | 9.0100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc5_attempt0.log | 0 |
| 10 | 572.40 | 113.30 | 113.90 | 115.10 | 113.90 | 116.20 | 5724 | 5724 | 100.00 | 9.1600 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc10_attempt0.log | 0 |
| 25 | 1470.70 | 293.20 | 293.30 | 294.00 | 295.30 | 294.90 | 14707 | 14693 | 99.90 | 8.4100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc25_attempt0.log | 0 |
| 50 | 2602.30 | 502.30 | 503.40 | 536.20 | 528.00 | 532.40 | 26023 | 2098 | 8.06 | 9.6600 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc50_attempt0.log | 0 |
| 75 | 2678.10 | 563.40 | 550.70 | 527.80 | 505.60 | 530.60 | 26781 | 1 | 0 | 9.7300 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc75_attempt0.log | 0 |
| 100 | 2751.90 | 587.30 | 517.10 | 556.80 | 550.70 | 540.00 | 27519 | 0 | 0 | 10.4900 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc100_attempt0.log | 0 |
| 150 | 3163.80 | 649.60 | 651.50 | 619.70 | 620.90 | 622.10 | 31638 | 0 | 0 | 11.8100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc150_attempt0.log | 0 |
| 200 | 3380.00 | 660.00 | 679.90 | 680.00 | 680.10 | 680.00 | 33800 | 0 | 0 | 12.1300 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc200_attempt0.log | 0 |
| 300 | 2960.00 | 620.00 | 580.00 | 560.00 | 600.00 | 600.00 | 29600 | 0 | 0 | 12.8100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc300_attempt0.log | 0 |
| 400 | 2720.00 | 520.00 | 540.00 | 580.00 | 560.00 | 520.00 | 27200 | 0 | 0 | 13.4100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3_rule_mongodb/conc400_attempt0.log | 0 |
