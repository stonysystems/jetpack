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

## 2026-03-10: Leaf 2 (`etcd ON`, 3 attempts)

Command shape (runbook-compatible; documented env vars only):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_etcd.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-etcd benchmark
```

Artifact directory:
`docs/phase1d_low_concurrency_20260310_etcd_on/`

Metrics extracted from `All-efficient-attempts statistics` (`50pct`) and
`Fastpath statistics`:

| Attempt | Status | Log | h1 p50 (ms) | h2-h5 p50 avg (ms) | Delta (ms) | FP attempted | FP succeeded | FP rate (%) |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_on/etcd_on_r1.txt` | 22.78 | 40.41 | 17.63 | 391 | 391 | 100.00 |
| 2 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_on/etcd_on_r2.txt` | 40.26 | 40.42 | 0.16 | 404 | 404 | 100.00 |
| 3 | Completed | `docs/phase1d_low_concurrency_20260310_etcd_on/etcd_on_r3.txt` | 22.65 | 40.42 | 17.77 | 373 | 373 | 100.00 |

Notes:
- All 3 attempts completed successfully (exit code `0`).
- Fast-path attempts remained `100%` successful in all attempts.
- `h2-h5` remained stable around `~40.4ms`, while `h1` was bimodal (`~22.7ms` in attempts
  1 and 3 vs `~40.3ms` in attempt 2), so this leaf is operationally complete but not yet
  absolutely stable across repeated runs.

## 2026-03-10: Leaf 3 (`mongodb OFF`, 3 attempts)

Command shape (runbook-compatible; documented env vars only):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

Artifact directory:
`docs/phase1d_low_concurrency_20260310_mongodb_off/`

Metrics extracted from `All-efficient-attempts statistics` (`50pct`) and
`Fastpath statistics`:

| Attempt | Status | Exit | Log | h1 p50 (ms) | h2-h5 p50 avg (ms) | Delta (ms) | FP attempted | FP succeeded |
|---|---|---:|---|---:|---:|---:|---:|---:|
| 1 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_off/mongodb_off_r1.txt` | 7.27 | 46.53 | 39.26 | 0 | 0 |
| 2 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_off/mongodb_off_r2.txt` | 7.12 | 46.15 | 39.03 | 0 | 0 |
| 3 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_off/mongodb_off_r3.txt` | 7.28 | 46.27 | 38.99 | 0 | 0 |

Notes:
- All 3 attempts completed on the default command path (no `MONGODB_ENDPOINTS` override).
- `h2-h5 - h1` stayed at about `~39ms` in all attempts.
- Absolute latencies are much lower than the previously published MongoDB OFF baseline
  (`h1 ~47.7ms`, `h2-h5 ~88.0ms`), so docs reconciliation remains required in later leaves.

## 2026-03-10: Leaf 4 (`mongodb ON`, 3 attempts)

Command shape (runbook-compatible; documented env vars only):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

Artifact directory:
`docs/phase1d_low_concurrency_20260310_mongodb_on/`

Metrics extracted from `All-efficient-attempts statistics` (`50pct`) and
`Fastpath statistics`:

| Attempt | Status | Exit | Log | h1 p50 (ms) | h2-h5 p50 avg (ms) | Delta (ms) | FP attempted | FP succeeded | FP rate (%) |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_on/mongodb_on_r1.txt` | 7.45 | 41.39 | 33.94 | 389 | 389 | 100.00 |
| 2 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_on/mongodb_on_r2.txt` | 7.76 | 41.49 | 33.73 | 370 | 370 | 100.00 |
| 3 | Completed | 0 | `docs/phase1d_low_concurrency_20260310_mongodb_on/mongodb_on_r3.txt` | 7.33 | 41.44 | 34.11 | 380 | 380 | 100.00 |

Notes:
- Initial pre-fix rerun encountered a primary-dependent startup failure when
  `start_mongodb_replset` elected a non-`127.0.0.1` primary and verification
  still targeted `mongodb://127.0.0.1:27017`.
- Fixed in `docker/mongodb/run-mongodb-test.sh` by setting `MONGODB_ENDPOINTS`
  to a replica-set URI after replica-set startup and using that URI for
  verification and write-concern setup in multi/benchmark modes.
- Post-fix verification logs show the replica-set URI path:
  `mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=jetpack-rs`.
- All 3 post-fix attempts completed with `100%` fast-path success.
