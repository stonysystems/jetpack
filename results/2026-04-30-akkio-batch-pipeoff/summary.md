# 2026-04-30-akkio-batch-pipeoff — latency summary

AWS akkio re-run with **batching ON, pipelining OFF**.
Investigates whether disabling pipelining (which saturated the
leader's bound replication core regardless of offered load — see
`../2026-04-30-akkio-pipeline`) lets jetpack-fast-path / read-lease
re-engage and show their expected 1-RTT wins.

`tput (req/s)` = total commit samples in CSV ÷ 30 s.
For V0-random, samples are the union of 5 sub-runs (one per
leader DC), and tput is divided by 5× duration to give the per-
sub-run rate.

| variant | aggregate tput from .res (req/s) | notes |
|---|---|---|
| V0-random | 2973.5 | mean of 5 sub-runs |
| V1-raw | 2976.5 | from 5/5 server.res files |
| V3-lease | 2974.1 | from 5/5 server.res files |
| V4-jetpack-raft | 2965.8 | from 5/5 server.res files |
| V6-jetpack-raft-lease | 2971.9 | from 5/5 server.res files |

These match the offered load of ~2952 req/s within rounding — pipelining handles the full 3000-target on real AWS WAN.

## V0-random

_raft + batch (pipeline OFF), leader cycles z0..z4 (5 sub-runs)_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| z0 California | 338078 | 2253.9 | 157.1 | 326.6 | 469.6 | 554.1 | 923.1 | 1040.1 | 327.2 | 104.6 |
| z1 Oregon | 27018 | 180.1 | 147.9 | 312.0 | 460.2 | 510.6 | 690.4 | 770.4 | 315.8 | 95.7 |
| z2 Mumbai | 26962 | 179.7 | 148.6 | 348.8 | 470.2 | 534.1 | 675.4 | 691.8 | 354.4 | 89.7 |
| z3 Frankfurt | 26985 | 179.9 | 126.7 | 322.5 | 401.7 | 467.1 | 585.0 | 592.6 | 298.5 | 89.3 |
| z4 Stockholm | 26981 | 179.9 | 148.6 | 338.4 | 419.0 | 481.4 | 769.2 | 769.7 | 308.6 | 96.6 |
| **integrated** | 446024 | 2973.5 | 126.7 | 327.1 | 464.6 | 528.5 | 819.1 | 1040.1 | 325.3 | 102.5 |

## V1-raw

_raft + batch (pipeline OFF), leader=z0_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| z0 California | 67725 | 2257.5 | 156.5 | 220.9 | 281.4 | 378.2 | 523.1 | 524.1 | 227.4 | 45.0 |
| z1 Oregon | 5387 | 179.6 | 175.6 | 237.6 | 297.0 | 335.0 | 399.7 | 399.8 | 243.0 | 39.1 |
| z2 Mumbai | 5400 | 180.0 | 383.7 | 447.8 | 509.2 | 622.6 | 716.3 | 723.8 | 454.6 | 45.7 |
| z3 Frankfurt | 5416 | 180.5 | 311.1 | 373.5 | 435.9 | 559.5 | 768.2 | 774.0 | 381.6 | 50.3 |
| z4 Stockholm | 5368 | 178.9 | 330.2 | 392.1 | 454.3 | 507.9 | 537.1 | 542.2 | 397.8 | 40.3 |
| **integrated** | 89296 | 2976.5 | 156.5 | 236.5 | 403.8 | 516.7 | 622.7 | 774.0 | 261.6 | 84.6 |

## V3-lease

_raft + batch + read-lease (pipeline OFF), leader=z0_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| z0 California | 67635 | 2254.5 | 0.1 | 182.1 | 259.9 | 412.6 | 451.4 | 471.6 | 135.0 | 112.7 |
| z1 Oregon | 5428 | 180.9 | 18.0 | 200.1 | 276.0 | 381.8 | 459.3 | 490.4 | 152.7 | 111.8 |
| z2 Mumbai | 5361 | 178.7 | 227.3 | 410.0 | 486.4 | 545.6 | 699.2 | 713.3 | 362.6 | 112.5 |
| z3 Frankfurt | 5410 | 180.3 | 152.7 | 335.8 | 418.1 | 556.6 | 693.6 | 703.6 | 291.3 | 116.1 |
| z4 Stockholm | 5390 | 179.7 | 171.5 | 354.8 | 433.7 | 564.8 | 786.3 | 796.9 | 309.3 | 115.4 |
| **integrated** | 89224 | 2974.1 | 0.1 | 190.0 | 352.4 | 478.5 | 638.9 | 796.9 | 169.8 | 134.2 |

## V4-jetpack-raft

_rule_raft + batch (jetpack fast-path, pipeline OFF), leader=z0_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| z0 California | 67380 | 2246.0 | 157.6 | 172.9 | 210.5 | 305.4 | 349.0 | 357.9 | 181.7 | 27.3 |
| z1 Oregon | 5441 | 181.4 | 150.4 | 152.3 | 182.8 | 299.1 | 344.7 | 346.7 | 161.5 | 29.9 |
| z2 Mumbai | 5355 | 178.5 | 227.4 | 228.7 | 231.5 | 508.5 | 546.8 | 731.4 | 250.4 | 68.5 |
| z3 Frankfurt | 5397 | 179.9 | 152.4 | 153.2 | 157.1 | 430.2 | 473.6 | 657.1 | 174.0 | 65.1 |
| z4 Stockholm | 5402 | 180.1 | 169.8 | 172.2 | 174.7 | 450.1 | 505.3 | 639.8 | 191.8 | 64.9 |
| **integrated** | 88975 | 2965.8 | 150.4 | 172.9 | 228.7 | 394.2 | 496.0 | 731.4 | 184.8 | 41.5 |

## V6-jetpack-raft-lease

_rule_raft + batch + read-lease (pipeline OFF), leader=z0_

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
|---|---|---|---|---|---|---|---|---|---|---|
| z0 California | 67467 | 2248.9 | 0.1 | 171.6 | 196.1 | 293.4 | 379.3 | 431.1 | 114.6 | 92.1 |
| z1 Oregon | 5422 | 180.7 | 18.1 | 152.0 | 154.3 | 281.2 | 328.1 | 403.5 | 110.5 | 74.3 |
| z2 Mumbai | 5425 | 180.8 | 227.7 | 228.4 | 229.9 | 486.4 | 538.6 | 658.2 | 245.6 | 59.1 |
| z3 Frankfurt | 5439 | 181.3 | 152.3 | 154.0 | 154.5 | 411.9 | 496.3 | 692.1 | 166.5 | 51.5 |
| z4 Stockholm | 5403 | 180.1 | 169.1 | 172.8 | 173.2 | 433.5 | 516.9 | 551.2 | 185.5 | 52.8 |
| **integrated** | 89156 | 2971.9 | 0.1 | 171.6 | 228.0 | 355.1 | 480.5 | 692.1 | 129.8 | 92.6 |

## Headline (integrated row, all variants)

| variant | samples | tput (req/s) | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | avg (ms) |
|---|---|---|---|---|---|---|---|
| V0-random | 446024 | 2973.5 | 327.1 | 464.6 | 528.5 | 819.1 | 325.3 |
| V1-raw | 89296 | 2976.5 | 236.5 | 403.8 | 516.7 | 622.7 | 261.6 |
| V3-lease | 89224 | 2974.1 | 190.0 | 352.4 | 478.5 | 638.9 | 169.8 |
| V4-jetpack-raft | 88975 | 2965.8 | 172.9 | 228.7 | 394.2 | 496.0 | 184.8 |
| V6-jetpack-raft-lease | 89156 | 2971.9 | 171.6 | 228.0 | 355.1 | 480.5 | 129.8 |

