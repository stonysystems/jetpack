# Phase 1D Low-Concurrency Sanity Reruns

This document records runbook-path low-concurrency reruns required by
`TODO.md` Phase 1D.

## 2026-03-10: Leaf 1 (`etcd OFF`, 3 attempts)

Command shape (runbook-compatible; documented env vars only):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_etcd.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-etcd benchmark
```

Artifact directory:
`docs/phase1d_low_concurrency_20260310_etcd_off/`

Metrics extracted from `All-efficient-attempts statistics` (`50pct`):

| Attempt | Status | Log | h1 p50 (ms) | h2-h5 p50 avg (ms) | Delta (ms) |
|---|---|---|---:|---:|---:|
| 1 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_off/etcd_off_r1.txt` | 22.64 | 62.65 | 40.01 |
| 2 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_off/etcd_off_r2.txt` | 42.79 | 82.86 | 40.07 |
| 3 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_off/etcd_off_r3.txt` | 42.59 | 82.66 | 40.07 |

Notes:
- All 3 attempts completed successfully (exit code `0`).
- `h2-h5 - h1` stays at `~40ms` in all attempts.
- Attempt 1 is an absolute-latency outlier versus attempts 2-3 and the published
  `etcd OFF` low-concurrency baseline, while preserving the expected delta model.
