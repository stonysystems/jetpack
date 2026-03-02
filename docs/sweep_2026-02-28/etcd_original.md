# etcd_original

| Field | Value |
|-------|-------|
| Image | `jetpack-etcd` |
| Mode | `none_etcd.yml` |
| Site config | 60c1s5r5p.yml (60 clients) |
| Latency / Duration | 20ms, Duration: 30s |
| Date | 2026-03-02T18:32:30Z |
| Git commit | `194c32c1` |
| Source | [`etcd_original.tsv`](etcd_original.tsv) |

| concurrency | total_throughput | h1 | h2 | h3 | h4 | h5 | fp_attempted | fp_succeeded | fp_rate | cpu_leader_avg | queue_depth_avg | status | error_summary | log_path | retry_count |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.90 | 7.90 | 8.10 | 7.90 | 7.90 | 8.10 | 0 | 0 | 0 | 4.7500 | .7980 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc1_attempt0.log | 0 |
| 5 | 272.40 | 54.60 | 54.10 | 55.00 | 54.30 | 54.40 | 0 | 0 | 0 | 6.6600 | 1.2500 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc5_attempt0.log | 0 |
| 10 | 568.00 | 115.10 | 114.40 | 112.70 | 113.10 | 112.70 | 0 | 0 | 0 | 5.7700 | 1.2840 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc10_attempt0.log | 0 |
| 25 | 1471.70 | 291.40 | 292.60 | 295.80 | 296.40 | 295.50 | 0 | 0 | 0 | 5.3500 | 2.3460 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc25_attempt0.log | 0 |
| 50 | 2974.70 | 596.20 | 594.00 | 598.90 | 594.50 | 591.10 | 0 | 0 | 0 | 6.0500 | 2.6300 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc50_attempt0.log | 0 |
| 75 | 4458.40 | 892.40 | 894.90 | 894.10 | 889.40 | 887.60 | 0 | 0 | 0 | 9.4900 | 4.4660 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc75_attempt0.log | 0 |
| 100 | 5949.40 | 1193.00 | 1194.50 | 1186.80 | 1187.80 | 1187.30 | 0 | 0 | 0 | 9.0800 | 7.6420 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc100_attempt0.log | 0 |
| 150 | 7616.40 | 1579.50 | 1440.30 | 1505.90 | 1530.50 | 1560.20 | 0 | 0 | 0 | 8.4100 | 8.0540 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc150_attempt0.log | 0 |
| 200 | 7686.60 | 1678.50 | 1529.50 | 1578.00 | 1521.00 | 1379.60 | 0 | 0 | 0 | 8.0900 | 7.1340 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc200_attempt0.log | 0 |
| 300 | 6977.20 | 1467.70 | 1345.90 | 1372.60 | 1400.00 | 1391.00 | 0 | 0 | 0 | 7.8500 | 18.9120 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc300_attempt0.log | 0 |
| 400 | 6915.20 | 1489.70 | 1381.10 | 1359.90 | 1360.50 | 1324.00 | 0 | 0 | 0 | 8.7800 | 88.5000 | OK | ;timeout | docs/sweep_2026-02-28/logs/jetpack-etcd_none_etcd/conc400_attempt0.log | 0 |
