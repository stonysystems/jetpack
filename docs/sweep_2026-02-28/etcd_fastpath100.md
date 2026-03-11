# etcd_fastpath100

| Field | Value |
|-------|-------|
| Image | `jetpack-etcd-phase1e-leaf2` |
| Mode | `rule_etcd.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-10T21:02:48Z |
| Git commit | `f6de16b6` |
| Source | [`etcd_fastpath100.tsv`](etcd_fastpath100.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.50 | 7.80 | 7.70 | 7.90 | 8.30 | 7.80 | 395 | 395 | 100.00 | 5.1200 | 2.6017 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc1_attempt0.log | 0 |
| 5 | 273.20 | 54.80 | 54.30 | 54.80 | 54.60 | 54.70 | 2732 | 2732 | 100.00 | 6.6200 | 12.7712 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc5_attempt0.log | 0 |
| 10 | 570.20 | 112.20 | 113.40 | 115.90 | 115.00 | 113.70 | 5702 | 5702 | 100.00 | 5.7300 | 14.7815 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc10_attempt0.log | 0 |
| 25 | 1472.50 | 292.70 | 296.00 | 294.40 | 293.00 | 296.40 | 10633 | 10633 | 100.00 | 7.4600 | 101.4575 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc25_attempt0.log | 0 |
| 50 | 2967.40 | 593.30 | 594.00 | 590.80 | 594.50 | 594.80 | 17785 | 16875 | 94.88 | 6.9300 | 128.3225 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc50_attempt0.log | 0 |
| 75 | 4465.00 | 895.40 | 896.10 | 884.10 | 894.70 | 894.70 | 3816 | 3729 | 97.72 | 8.0500 | 200.8285 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc75_attempt0.log | 0 |
| 100 | 5959.50 | 1192.50 | 1189.00 | 1191.00 | 1187.50 | 1199.50 | 0 | 0 | 0 | 7.5300 | 379.7940 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc100_attempt0.log | 0 |
| 150 | 6995.20 | 1414.20 | 1424.60 | 1360.20 | 1425.50 | 1370.70 | 0 | 0 | 0 | 8.9100 | 318.8516 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc150_attempt0.log | 0 |
| 200 | 6686.30 | 1377.90 | 1353.60 | 1357.70 | 1302.40 | 1294.70 | 0 | 0 | 0 | 8.2700 | 610.4863 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc200_attempt0.log | 0 |
| 300 | 6932.30 | 1430.00 | 1371.10 | 1391.20 | 1400.00 | 1340.00 | 0 | 0 | 0 | 10.5100 | 552.5616 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc300_attempt0.log | 0 |
| 400 | 5983.90 | 1199.60 | 1200.00 | 1200.00 | 1200.00 | 1184.30 | 0 | 0 | 0 | 11.8400 | 553.6087 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd-phase1e-leaf2_rule_etcd/conc400_attempt0.log | 0 |
