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

**Status: SKIPPED**

The full throughput sweep (9 cases × 11 concurrency levels × 30s each =
~50 minutes per case, ~7.5 hours total) was not run in this session due to
time constraints. The sweep requires sustained compute for accurate
throughput measurement and should be run in a dedicated session.

This phase is **required** for a complete reproduction. Without it, the
rerun cannot claim to match or update the published throughput numbers in
`docs/sweep_2026-02-28/`.

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
| 3     | Throughput sweep (9)      | SKIPPED         |
| 4     | WAN recovery (9)          | PASS (9/9)      |

**Overall: PARTIAL — Phase 3 (throughput sweep) was skipped.**

The rerun confirms:
- Fresh images build and run correctly from the current checkout.
- All 6 backend/mode combinations pass low-concurrency sanity checks.
- WAN recovery timing matches the published model (81-87ms at RTT=40ms).
- The `fastpath_stopped` signal is present in rebuilt images (see
  `docs/recovery_evidence_20260318/` for signal file evidence).

The rerun does NOT confirm:
- Published throughput numbers from `docs/sweep_2026-02-28/` (sweep not run).
- Full concurrency scaling behavior.

## Artifact Files

- `results/reproduce_20260318/build/` — Build logs and image metadata
- `results/reproduce_20260318/sanity/` — 18 sanity run logs
- `results/reproduce_20260318/recovery/` — 9 recovery test logs
- `results/reproduce_20260318/SUMMARY.md` — Auto-generated summary
