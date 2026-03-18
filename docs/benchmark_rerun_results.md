# Benchmark Rerun Results — 2026-03-18

Fresh end-to-end evaluation reproduction from the current checkout.

## Configuration

- **Commit:** 9dd1edbc
- **Entrypoint:** `./scripts/reproduce_evaluation.sh`
- **Date:** 2026-03-18
- **Docker images:** Built fresh from current checkout (not pre-existing)
- **Latency:** tc/netem, LATENCY_MS=20 (benchmark), RECOVERY_LATENCY_MS=20 (recovery)
- **Results directory:** `results/reproduce_20260318/`

## Build Metadata

| Backend    | Image ID (short)       | Commit     | Built At                    |
|------------|------------------------|------------|-----------------------------|
| etcd       | efb8c1fca67c           | 9dd1edbc   | 2026-03-18T07:17:13-04:00   |
| mongodb    | 1af4649324e1           | 9dd1edbc   | 2026-03-18T07:17:15-04:00   |
| zookeeper  | 618bb01be77b           | 9dd1edbc   | 2026-03-18T07:17:17-04:00   |

## Per-Phase Results

### Phase 1: Build Fresh Images

**Status: PASS**

All three backend Docker images built successfully from the current checkout.
Build used `docker compose build` for each backend.

### Phase 2: Low-Concurrency Sanity Runs

**Status: PASS (18/18)**

| Backend    | Jetpack Off | Jetpack On |
|------------|:-----------:|:----------:|
| etcd       | 3/3 PASS    | 3/3 PASS   |
| mongodb    | 3/3 PASS    | 3/3 PASS   |
| zookeeper  | 3/3 PASS    | 3/3 PASS   |

Each run: concurrent=1, duration=10s, tc/netem 20ms one-way latency.
Command: `docker run --rm --privileged -e MODE_CONFIG=<mode> -e CONCURRENT_CONFIG=concurrent_1.yml -e TEST_DURATION=10 jetpack-<backend> benchmark`

### Phase 3: Full 9-Case Throughput Sweep

**Status: PASS (9/9)**

All 9 sweep cases completed successfully (3 backends × 3 modes).
Each case sweeps 11 concurrency levels (1, 5, 10, 25, 50, 75, 100, 150,
200, 300, 400) with 30s per point, tc/netem 20ms one-way latency.

| Backend    | Mode        | Peak Throughput | Status |
|------------|-------------|----------------:|--------|
| etcd       | original    |      7498 txn/s | PASS   |
| etcd       | fastpath100 |      6732 txn/s | PASS   |
| etcd       | adaptive    |      7010 txn/s | PASS   |
| mongodb    | original    |      3928 txn/s | PASS   |
| mongodb    | fastpath100 |      3026 txn/s | PASS   |
| mongodb    | adaptive    |      3676 txn/s | PASS   |
| zookeeper  | original    |      5501 txn/s | PASS   |
| zookeeper  | fastpath100 |      5445 txn/s | PASS   |
| zookeeper  | adaptive    |      5503 txn/s | PASS   |

Total sweep duration: ~3.5 hours (07:58–11:27).
Command: `./scripts/reproduce_evaluation.sh --sweep-only`
Raw TSV files: `results/reproduce_20260318/sweep/`

### Phase 4: WAN Recovery Tests

**Status: PASS (9/9)**

| Backend    | Rep 1 | Rep 2 | Rep 3 | Avg Recovery |
|------------|------:|------:|------:|-------------:|
| etcd       | 87ms  | 82ms  | 81ms  | 83ms         |
| mongodb    | 84ms  | 84ms  | 82ms  | 83ms         |
| zookeeper  | 81ms  | 82ms  | 81ms  | 81ms         |

**Protocol downtime (new leader election):**

| Backend    | Rep 1   | Rep 2   | Rep 3   |
|------------|--------:|--------:|--------:|
| etcd       | 6735ms  | 7927ms  | 6693ms  |
| mongodb    | 10806ms | 10590ms | 10441ms |
| zookeeper  | 773ms   | 788ms   | 793ms   |

Expected Jetpack recovery at RTT=40ms: 1ms (poll) + 2 × 40ms = 81ms.
Observed: 81-87ms. **Consistent with expected model.**

Command: `docker compose run --rm -e RECOVERY_LATENCY_MS=20 jetpack-<backend> recovery`

## Overall Status

| Phase | Description               | Status          |
|-------|---------------------------|-----------------|
| 1     | Build fresh images        | PASS            |
| 2     | Sanity runs (18)          | PASS (18/18)    |
| 3     | Throughput sweep (9)      | PASS (9/9)      |
| 4     | WAN recovery (9)          | PASS (9/9)      |

**Overall: PASS — All 4 phases completed successfully.**

The rerun confirms:
- Fresh images build and run correctly from the current checkout.
- All 6 backend/mode combinations pass low-concurrency sanity checks.
- All 9 throughput sweep cases complete with valid throughput data.
- WAN recovery timing matches the published model (81-87ms at RTT=40ms).
- The `fastpath_stopped` signal is present in rebuilt images (see
  `docs/recovery_evidence_20260318/` for signal file evidence).

## Artifact Files

- `results/reproduce_20260318/build/` — Build logs and image metadata
- `results/reproduce_20260318/sanity/` — 18 sanity run logs
- `results/reproduce_20260318/sweep/` — 9 sweep TSV result files
- `results/reproduce_20260318/recovery/` — 9 recovery test logs
- `results/reproduce_20260318/SUMMARY.md` — Auto-generated summary
- `docs/sweep_2026-02-28/logs/` — Raw per-concurrency-level benchmark logs
