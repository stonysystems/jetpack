# WAN Recovery Matrix (Accepted Rerun Pass) — 2026-03-11

This consolidates the accepted 9-run WAN recovery rerun pass used for documentation
reconciliation.

Runbook command shape used per backend:

```bash
docker compose -f docker/<backend>/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 \
  jetpack-<backend> recovery
```

Metric definitions:
- `Backend downtime (script)`: from leader kill to new leader/primary detection.
- `Jetpack script-detected downtime`: from `primary_elected` signal write to script completion detection.
- `Jetpack internal duration`: `duration=...ms` from `JETPACK-RECOVERY.*COMPLETED` log line.
- RTT formula comparison uses **Jetpack internal duration** only.

| Backend (rep) | Backend downtime (script) | Jetpack script-detected downtime | Jetpack internal duration |
|---|---:|---:|---:|
| etcd (r1) | 6568ms | 4ms | 82ms |
| etcd (r2) | 6729ms | 4ms | 81ms |
| etcd (r3) | 6817ms | 3ms | 82ms |
| MongoDB (r1) | 23209ms | 92ms | 83ms |
| MongoDB (r2) | 10741ms | 88ms | 83ms |
| MongoDB (r3) | 21684ms | 92ms | 82ms |
| ZooKeeper (r1) | 774ms | 83ms | 81ms |
| ZooKeeper (r2) | 800ms | 82ms | 82ms |
| ZooKeeper (r3) | 773ms | 83ms | 81ms |

Source logs:
- `docs/phase1f_wan_recovery_20260311/etcd_wan_r{1,2,3}.txt`
- `docs/phase1f_wan_recovery_20260311/mongodb_wan_r{1,2,3}.txt`
- `docs/phase1f_wan_recovery_20260311/zookeeper_wan_r{1,2,3}.txt`
