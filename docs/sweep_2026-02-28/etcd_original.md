# etcd_original

| Field | Value |
|-------|-------|
| Image | `jetpack-etcd-phase1e-leaf2` |
| Mode | `none_etcd.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-10T20:47:10Z |
| Git commit | `f6de16b6` |
| Source | [`etcd_original.tsv`](etcd_original.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 40.10 | 8.00 | 7.90 | 7.90 | 8.00 | 8.30 | 0 | 0 | 0 | 5.9500 | .4960 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc1_attempt0.log | 0 |
| 5 | 272.70 | 54.40 | 53.90 | 55.40 | 54.50 | 54.50 | 0 | 0 | 0 | 6.3800 | 1.0800 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc5_attempt0.log | 0 |
| 10 | 566.00 | 112.90 | 114.20 | 112.90 | 113.00 | 113.00 | 0 | 0 | 0 | 5.6800 | 1.6660 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc10_attempt0.log | 0 |
| 25 | 1466.90 | 293.20 | 293.60 | 294.10 | 291.20 | 294.80 | 0 | 0 | 0 | 7.0500 | 2.0640 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc25_attempt0.log | 0 |
| 50 | 2963.80 | 591.50 | 593.20 | 594.30 | 591.10 | 593.70 | 0 | 0 | 0 | 6.6000 | 2.9080 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc50_attempt0.log | 0 |
| 75 | 4449.10 | 891.80 | 884.90 | 890.10 | 891.50 | 890.80 | 0 | 0 | 0 | 7.1100 | 2.1900 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc75_attempt0.log | 0 |
| 100 | 5936.90 | 1194.50 | 1186.30 | 1183.30 | 1182.40 | 1190.40 | 0 | 0 | 0 | 8.6100 | 2.6040 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc100_attempt0.log | 0 |
| 150 | 7743.20 | 1579.80 | 1544.20 | 1549.20 | 1571.40 | 1498.60 | 0 | 0 | 0 | 8.0400 | 7.1580 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc150_attempt0.log | 0 |
| 200 | 7605.10 | 1594.90 | 1499.70 | 1517.90 | 1508.40 | 1484.20 | 0 | 0 | 0 | 9.2900 | 51.7000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc200_attempt0.log | 0 |
| 300 | 7261.40 | 1492.90 | 1443.00 | 1440.00 | 1440.60 | 1444.90 | 0 | 0 | 0 | 9.2400 | 176.7000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc300_attempt0.log | 0 |
| 400 | 7352.70 | 1521.30 | 1484.90 | 1446.60 | 1453.70 | 1446.20 | 0 | 0 | 0 | 10.2600 | 94.7200 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_none_etcd/conc400_attempt0.log | 0 |
