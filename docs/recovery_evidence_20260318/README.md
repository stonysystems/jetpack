# Recovery Handshake Evidence — 2026-03-18

Evidence for Track 1: MongoDB / etcd / ZooKeeper failure-recovery handshake.

## Test Configuration

- **Commit:** a5f11448 (source), Docker images rebuilt from current checkout
- **Latency:** `RECOVERY_LATENCY_MS=20` (20ms one-way, 40ms RTT via tc/netem)
- **Topology:** `1c1s3r1p_wan.yml` (3 servers on 127.0.0.1-3)
- **Docker:** `--privileged` (required for tc/netem)
- **Date:** 2026-03-18

## Commands Used

```bash
# Rebuild images from current source (includes fastpath_stopped code)
docker build --network=host -t jetpack-etcd-evidence -f docker/etcd/Dockerfile .
docker build --network=host -t jetpack-mongodb-evidence -f docker/mongodb/Dockerfile .
docker build --network=host -t jetpack-zookeeper-evidence -f docker/zookeeper/Dockerfile .

# Run recovery tests
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-etcd-evidence recovery
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-mongodb-evidence recovery
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-zookeeper-evidence recovery
```

## Per-Backend Evidence

### etcd

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing etcd node at 127.0.0.1 (PID=9)` |
| New leader election | PASS | `New etcd leader elected: 127.0.0.3 (took 7102ms)` |
| `primary_elected` write | PASS | `etcd:primary_elected` in `/tmp/JM_Jetpack_0.0.0.0` |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected (4ms after signal)` |
| `fastpath_stopped` write | PASS | `jetpack:fastpath_stopped` in `/tmp/JM_Jetpack_0.0.0.0` (2 non-leader replicas) |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Cluster health during recovery | PASS | `etcd cluster: 2/3 nodes healthy` |

**Signal file contents (`JM_Jetpack_0.0.0.0`):**
```
etcd:primary_elected
jetpack:fastpath_stopped
jetpack:fastpath_stopped
```

**Result:** `pass` — full signal chain verified.
**Timing:** etcd downtime 7102ms, Jetpack recovery 82ms (at RTT=40ms).

### MongoDB

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing MongoDB node at 127.0.0.1` |
| New leader election | PASS | `New MongoDB primary elected: 127.0.0.3 (took 10479ms)` |
| `primary_elected` write | PASS | `mongo:primary_elected` in `/tmp/JM_Jetpack_0.0.0.0` |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected` |
| `fastpath_stopped` write | PASS | `jetpack:fastpath_stopped` in `/tmp/JM_Jetpack_0.0.0.0` (2 non-leader replicas) |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Cluster health during recovery | PASS | `MongoDB replica set: 2/3 nodes healthy` |

**Signal file contents (`JM_Jetpack_0.0.0.0`):**
```
mongo:primary_elected
jetpack:fastpath_stopped
jetpack:fastpath_stopped
```

**Result:** `pass` — full signal chain verified.
**Timing:** MongoDB downtime 10479ms, Jetpack recovery 82ms (at RTT=40ms).

### ZooKeeper

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing ZooKeeper node 1 (ip=127.0.0.1) with SIGKILL` |
| New leader election | PASS | `New ZooKeeper leader elected: 127.0.0.3:2183 (788ms)` |
| `primary_elected` write | PASS | `zookeeper:primary_elected` in `/tmp/JM_Jetpack_0.0.0.0` |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected` |
| `fastpath_stopped` write | PASS | `jetpack:fastpath_stopped` in `/tmp/JM_Jetpack_0.0.0.0` (2 non-leader replicas) |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Cluster health during recovery | PASS | `ZooKeeper ensemble: 2/3 nodes healthy` |

**Signal file contents (`JM_Jetpack_0.0.0.0`):**
```
zookeeper:primary_elected
jetpack:fastpath_stopped
jetpack:fastpath_stopped
```

**Result:** `pass` — full signal chain verified.
**Timing:** ZooKeeper downtime 788ms, Jetpack recovery 82ms (at RTT=40ms).

## Summary

| Backend    | Leader Kill | Election | primary_elected | RECOVERY | fastpath_stopped | recovery_finish | Cluster Health | Overall |
|------------|:-----------:|:--------:|:---------------:|:--------:|:----------------:|:---------------:|:--------------:|:-------:|
| etcd       | PASS        | PASS     | PASS            | PASS     | PASS             | PASS            | PASS           | pass    |
| MongoDB    | PASS        | PASS     | PASS            | PASS     | PASS             | PASS            | PASS           | pass    |
| ZooKeeper  | PASS        | PASS     | PASS            | PASS     | PASS             | PASS            | PASS           | pass    |

## What Is Demonstrated

1. Leader failure detection works for all three backends.
2. Backend cluster re-election works (etcd: 7.1s, MongoDB: 10.5s, ZK: 0.8s).
3. `primary_elected` signal is written and detected by Jetpack.
4. Jetpack enters RECOVERY and writes `jetpack:fastpath_stopped` immediately.
5. Two non-leader Jetpack replicas each emit `fastpath_stopped` (2 entries).
6. Recovery completes in ~82ms at RTT=40ms (matching expected 1ms + 2×RTT).
7. `recovery_finish` and `recovery_finish_after_failure` signals are emitted.
8. Backend clusters remain operational (2/3 healthy) throughout recovery.

## Note on Backend-Side Pause/Resume

The `fastpath_stopped` signal is now emitted by Jetpack and visible in the
signal files. The backend patches (`patches/{mongodb,etcd,zookeeper}-leader-signal.patch`)
include wait-for-fastpath_stopped logic, but in these tests the `primary_elected`
signal is written by the **test script** (external kill approach), not by the
backend source code patches. The backend source code patches apply when the
backend itself detects the new leader and writes `primary_elected` from within
its own process — this is the production code path but requires the patched
backend binaries. The test script approach validates the Jetpack side of the
handshake; the backend-side wait is validated by code review of the patches.

## Artifact Files

- `etcd_recovery_wan.log` — etcd recovery (pre-rebuild image, partial)
- `mongodb_recovery_wan.log` — MongoDB recovery (pre-rebuild image, partial)
- `zookeeper_recovery_wan.log` — ZooKeeper recovery (pre-rebuild image, partial)
- `etcd_recovery_wan_full.log` — etcd recovery (rebuilt image, full evidence)
- `mongodb_recovery_wan_full.log` — MongoDB recovery (rebuilt image, full evidence)
- `zookeeper_recovery_wan_full.log` — ZooKeeper recovery (rebuilt image, full evidence)
