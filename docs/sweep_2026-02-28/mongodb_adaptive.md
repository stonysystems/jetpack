# mongodb_adaptive

| Field | Value |
|-------|-------|
| Image | `jetpack-mongodb-phase1e-leaf3-adaptive` |
| Mode | `rule_mongodb.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-10T22:57:39Z |
| Git commit | `f6de16b6` |
| Source | [`mongodb_adaptive.tsv`](mongodb_adaptive.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.90 | 8.00 | 7.60 | 8.30 | 8.10 | 7.90 | 372 | 372 | 100.00 | 8.5000 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc1_attempt1.log | 1 |
| 5 | 272.30 | 54.50 | 53.90 | 55.20 | 55.10 | 53.60 | 2222 | 2222 | 100.00 | 9.0900 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc5_attempt0.log | 0 |
| 10 | 567.80 | 113.40 | 113.30 | 113.30 | 113.10 | 114.70 | 4601 | 4601 | 100.00 | 9.2400 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc10_attempt0.log | 0 |
| 25 | 1465.00 | 295.70 | 292.60 | 293.50 | 292.20 | 291.00 | 14650 | 14650 | 100.00 | 8.1800 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc25_attempt0.log | 0 |
| 50 | 2970.80 | 592.50 | 595.70 | 600.60 | 590.30 | 591.70 | 8561 | 5660 | 66.11 | 11.2600 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc50_attempt0.log | 0 |
| 75 | 3872.60 | 824.90 | 730.40 | 799.80 | 763.90 | 753.60 | 2269 | 1690 | 74.48 | 11.5800 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc75_attempt0.log | 0 |
| 100 | 3694.90 | 797.20 | 737.80 | 686.30 | 716.70 | 756.90 | 1872 | 1457 | 77.83 | 11.5900 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc100_attempt0.log | 0 |
| 150 | 3785.90 | 792.60 | 735.50 | 724.30 | 746.20 | 787.30 | 1954 | 1629 | 83.36 | 12.5100 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc150_attempt0.log | 0 |
| 200 | 3590.60 | 720.10 | 719.90 | 720.20 | 693.40 | 737.00 | 1816 | 1570 | 86.45 | 12.0400 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc200_attempt0.log | 0 |
| 300 | 3279.30 | 700.00 | 679.30 | 620.00 | 640.00 | 640.00 | 1617 | 1384 | 85.59 | 12.7500 | 1.0000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc300_attempt0.log | 0 |
| 400 | 2773.40 | 620.00 | 560.00 | 520.00 | 520.00 | 553.40 | 1458 | 1289 | 88.40 | 12.0600 | 1.0002 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc400_attempt0.log | 0 |
