# MongoDB WAN Recovery (Leaf 2) — 2026-03-11

Command path (runbook-compatible):

```bash
docker compose -f docker/mongodb/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 \
  jetpack-mongodb recovery
```

Repetitions executed: 3

| Rep | Log | MongoDB downtime (script-level) | Jetpack downtime (script-level) | Jetpack internal `duration=` |
|---|---|---:|---:|---:|
| r1 | `mongodb_wan_r1.txt` | 23209 ms | 92 ms | 83 ms |
| r2 | `mongodb_wan_r2.txt` | 10741 ms | 88 ms | 83 ms |
| r3 | `mongodb_wan_r3.txt` | 21684 ms | 92 ms | 82 ms |

Evidence chain confirmed in each run log:
- leader kill (`Killing MongoDB node ...`)
- backend re-election (`New MongoDB primary elected ...`)
- signal write (`Wrote primary_elected signal ...`)
- Jetpack recovery start (`Jetpack recovery started (found in logs)`)
- Jetpack recovery completion (`Jetpack recovery completed (duration=...)`)

Metric labeling for later matrix consolidation:
- `Jetpack downtime (script-level)`: detection-based elapsed time from signal write to script detection.
- `Jetpack internal duration`: in-process `JETPACK-RECOVERY ... COMPLETED duration=` value.
