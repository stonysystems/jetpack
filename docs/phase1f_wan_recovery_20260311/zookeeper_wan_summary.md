# ZooKeeper WAN Recovery (Leaf 3) — 2026-03-11

Command path (runbook-compatible):

```bash
docker compose -f docker/zookeeper/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 \
  jetpack-zookeeper recovery
```

Repetitions executed: 3

| Rep | Log | ZooKeeper downtime (script-level) | Jetpack downtime (script-level) | Jetpack internal `duration=` |
|---|---|---:|---:|---:|
| r1 | `zookeeper_wan_r1.txt` | 774 ms | 83 ms | 81 ms |
| r2 | `zookeeper_wan_r2.txt` | 800 ms | 82 ms | 82 ms |
| r3 | `zookeeper_wan_r3.txt` | 773 ms | 83 ms | 81 ms |

Evidence chain confirmed in each run log:
- leader kill (`Killing ZooKeeper node ...`)
- backend re-election (`New ZooKeeper leader elected ...`)
- signal write (`Wrote primary_elected signal ...`)
- Jetpack recovery start (`Jetpack recovery started (found in logs)`)
- Jetpack recovery completion (`Jetpack recovery completed (duration=...)`)

Metric labeling for later matrix consolidation:
- `Jetpack downtime (script-level)`: detection-based elapsed time from signal write to script detection.
- `Jetpack internal duration`: in-process `JETPACK-RECOVERY ... COMPLETED duration=` value.
