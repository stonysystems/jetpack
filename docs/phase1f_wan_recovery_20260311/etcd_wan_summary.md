# etcd WAN Recovery (Leaf 1) — 2026-03-11

Command path (runbook-compatible):

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 \
  jetpack-etcd recovery
```

Repetitions executed: 3

| Rep | Log | etcd downtime (script-level) | Jetpack downtime (script-level) | Jetpack internal `duration=` |
|---|---|---:|---:|---:|
| r1 | `etcd_wan_r1.txt` | 6568 ms | 4 ms | 82 ms |
| r2 | `etcd_wan_r2.txt` | 6729 ms | 4 ms | 81 ms |
| r3 | `etcd_wan_r3.txt` | 6817 ms | 3 ms | 82 ms |

Evidence chain confirmed in each run log:
- leader kill (`Killing etcd node ...`)
- backend re-election (`New etcd leader elected ...`)
- signal write (`Wrote primary_elected signal ...`)
- Jetpack recovery start (`Jetpack recovery started (found in logs)`)
- Jetpack recovery completion (`Jetpack recovery completed (duration=...)`)

Metric labeling for later matrix consolidation:
- `Jetpack downtime (script-level)`: detection-based elapsed time from signal write to script detection.
- `Jetpack internal duration`: in-process `JETPACK-RECOVERY ... COMPLETED duration=` value.
