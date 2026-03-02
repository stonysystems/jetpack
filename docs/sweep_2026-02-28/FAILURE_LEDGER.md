# Failure Ledger

Every zero-throughput row in the 9 canonical sweep files. These rows were recorded
before `sweep_benchmark.sh` was updated with retry logic and failure classification,
so no Docker logs were saved for these runs.

## Summary

| # | Backend | Mode | Concurrency | Observed | Suspected Root Cause | Rerun Status |
|---|---------|------|-------------|----------|---------------------|-------------|
| 1 | etcd | fastpath-100 | 50 | 0 txn/s, all processes 0 | Docker process crash or resource exhaustion at moderate concurrency | PENDING |
| 2 | etcd | fastpath-100 | 75 | 0 txn/s, all processes 0 | Docker process crash or resource exhaustion at moderate concurrency | PENDING |
| 3 | etcd | fastpath-100 | 300 | 0 txn/s, all processes 0 | High-concurrency resource exhaustion (fd/memory) | PENDING |
| 4 | etcd | adaptive | 150 | 0 txn/s, all processes 0 | Mid-range concurrency failure; etcd fastpath=100 fails at nearby points (50,75) | PENDING |
| 5 | etcd | adaptive | 300 | 0 txn/s, all processes 0 | High-concurrency resource exhaustion | PENDING |
| 6 | MongoDB | original | 50 | 0 txn/s, all processes 0 | MongoDB connection pool exhaustion (2500 conns via `#define AWS`) | PENDING |
| 7 | MongoDB | original | 75 | 0 txn/s, all processes 0 | MongoDB connection pool exhaustion | PENDING |
| 8 | MongoDB | fastpath-100 | 50 | 0 txn/s, all processes 0 | MongoDB connection pool or Docker resource limits | PENDING |
| 9 | MongoDB | adaptive | 5 | 0 txn/s, all processes 0 | Low-concurrency startup race; Docker process may not have initialized | PENDING |
| 10 | MongoDB | adaptive | 200 | 0 txn/s, all processes 0 | High-concurrency Docker resource exhaustion | PENDING |
| 11 | ZooKeeper | fastpath-100 | 150 | 0 txn/s, all processes 0 | Docker resource limits at moderate-high concurrency | PENDING |
| 12 | ZooKeeper | fastpath-100 | 300 | 0 txn/s, all processes 0 | High-concurrency resource exhaustion | PENDING |

## Analysis

### Pattern 1: High-concurrency failures (c >= 150)
Points 3, 5, 10, 11, 12 all fail at concurrency >= 150. Likely cause: Docker container
runs 5 server processes + backend on a single host, exhausting file descriptors, memory,
or CPU. The updated `sweep_benchmark.sh` now retries these and saves logs.

### Pattern 2: Mid-range failures (c = 50-75)
Points 1, 2, 6, 7, 8 fail at concurrency 50-75. These are surprising — the same
backend/mode combinations succeed at higher concurrency (e.g., etcd fastpath succeeds
at c=100,200 but fails at c=50,75). This suggests transient Docker startup issues
rather than sustained resource pressure. Retrying with the updated script should resolve most.

### Pattern 3: Low-concurrency MongoDB adaptive (c = 5)
Point 9 is an anomaly — MongoDB adaptive fails at c=5 but succeeds at c=1 and c=10.
This could be a startup race condition where the replica set isn't fully initialized
before clients begin sending transactions.

### Pattern 4: Backend-specific
- **etcd**: 5 failures, concentrated in fastpath-100 mode (3/5)
- **MongoDB**: 5 failures, spread across all 3 modes
- **ZooKeeper**: 2 failures, only in fastpath-100 mode
- **Original mode (all backends)**: Only MongoDB has failures (2 points)
- **ZooKeeper adaptive**: Zero failures (highest quality dataset)

## Next Steps

1. Rerun all 12 failed points using the updated `sweep_benchmark.sh` (which now retries
   up to 2 times and saves Docker logs).
2. For each rerun, classify the failure signature from saved logs: OOM, fd exhaustion,
   connection failure, segfault, timeout, or empty output.
3. For persistent failures, investigate Docker resource limits (`ulimit -n`, memory caps).
4. Rerun adjacent concurrency values around each fixed point to verify the throughput
   curve is continuous.
