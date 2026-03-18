# Recovery Handshake Evidence — 2026-03-18

Evidence for Track 1: MongoDB / etcd / ZooKeeper failure-recovery handshake.

## Test Configuration

- **Commit:** 6685c059 (source code), Docker images built from earlier commit
- **Latency:** `RECOVERY_LATENCY_MS=20` (20ms one-way, 40ms RTT via tc/netem)
- **Topology:** `1c1s3r1p_wan.yml` (3 servers on 127.0.0.1-3)
- **Docker:** `--privileged` (required for tc/netem)
- **Date:** 2026-03-18

## Commands Used

```bash
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery
docker run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-zookeeper recovery
```

## Per-Backend Evidence

### etcd

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing etcd node at 127.0.0.1 (PID=9)` |
| New leader election | PASS | `New etcd leader elected: 127.0.0.3 (took 7147ms)` |
| `primary_elected` write | PASS | `Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0` + `etcd:primary_elected` in signal file |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected (4ms after signal)` + `Jetpack recovery started` |
| `fastpath_stopped` write | NOT TESTED | Docker image predates fastpath_stopped code |
| Backend pause/resume | NOT TESTED | Requires rebuilt image with fastpath_stopped wait |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Heartbeat during pause | N/A | etcd cluster maintained 2/3 healthy nodes throughout |

**Result:** `partial` — signal chain through recovery works; fastpath_stopped
handshake not exercised (image predates code change).

**Timing:** etcd downtime 7147ms, Jetpack recovery 82ms (at RTT=40ms).

### MongoDB

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing MongoDB node at 127.0.0.1 (PID=11)` |
| New leader election | PASS | `New MongoDB primary elected: 127.0.0.2 (took 10864ms)` |
| `primary_elected` write | PASS | `Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0` + `mongo:primary_elected` in signal file |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected (85ms after signal)` + `Jetpack recovery started` |
| `fastpath_stopped` write | NOT TESTED | Docker image predates fastpath_stopped code |
| Backend pause/resume | NOT TESTED | Requires rebuilt image with fastpath_stopped wait |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Heartbeat during pause | N/A | MongoDB replica set maintained 2/3 healthy nodes throughout |

**Result:** `partial` — signal chain through recovery works; fastpath_stopped
handshake not exercised (image predates code change).

**Timing:** MongoDB downtime 10864ms, Jetpack recovery 82ms (at RTT=40ms).

### ZooKeeper

| Step | Evidence | Log Line |
|------|----------|----------|
| Leader failure | PASS | `Killing ZooKeeper node 1 (ip=127.0.0.1, pid=26) with SIGKILL` |
| New leader election | PASS | `New ZooKeeper leader elected: 127.0.0.3:2183 (874ms)` |
| `primary_elected` write | PASS | `Wrote primary_elected signal to /tmp/JM_Jetpack_0.0.0.0` + `zookeeper:primary_elected` in signal file |
| Jetpack enters RECOVERY | PASS | `Jetpack recovery detected (83ms after signal)` + `Jetpack recovery started` |
| `fastpath_stopped` write | NOT TESTED | Docker image predates fastpath_stopped code |
| Backend pause/resume | NOT TESTED | Requires rebuilt image with fastpath_stopped wait |
| Recovery complete | PASS | `Jetpack recovery completed (duration=82ms)` |
| `recovery_finish` signals | PASS | `jetpack:recovery_finish` + `jetpack:recovery_finish_after_failure` |
| Heartbeat during pause | N/A | ZooKeeper ensemble maintained 2/3 healthy nodes throughout |

**Result:** `partial` — signal chain through recovery works; fastpath_stopped
handshake not exercised (image predates code change).

**Timing:** ZooKeeper downtime 880ms, Jetpack recovery 82ms (at RTT=40ms).

## Summary

| Backend    | Leader Kill | Election | primary_elected | RECOVERY | fastpath_stopped | Pause/Resume | recovery_finish | Overall |
|------------|:-----------:|:--------:|:---------------:|:--------:|:----------------:|:------------:|:---------------:|:-------:|
| etcd       | PASS        | PASS     | PASS            | PASS     | NOT TESTED       | NOT TESTED   | PASS            | partial |
| MongoDB    | PASS        | PASS     | PASS            | PASS     | NOT TESTED       | NOT TESTED   | PASS            | partial |
| ZooKeeper  | PASS        | PASS     | PASS            | PASS     | NOT TESTED       | NOT TESTED   | PASS            | partial |

## What Is Demonstrated

1. Leader failure detection works for all three backends.
2. Backend cluster re-election works (etcd: 7.1s, MongoDB: 10.9s, ZK: 0.9s).
3. `primary_elected` signal is written and detected by Jetpack.
4. Jetpack enters RECOVERY and runs the 4-phase recovery protocol.
5. Recovery completes in ~82ms at RTT=40ms (matching expected 1ms + 2×RTT).
6. `recovery_finish` and `recovery_finish_after_failure` signals are emitted.
7. Backend clusters remain operational (2/3 healthy) throughout recovery.

## What Is NOT Demonstrated

The `fastpath_stopped` handshake (code added in commit c421ef50) is NOT
exercised because the Docker images were built before that commit. To fully
demonstrate the handshake, the images must be rebuilt from the current source.

Specifically, these steps require rebuilt images:
- Jetpack emitting `jetpack:fastpath_stopped` after setting RECOVERY status
- Backend waiting for `fastpath_stopped` before resuming request processing
- Heartbeat/election traffic continuing during the backend wait window

## Artifact Files

- `etcd_recovery_wan.log` — Full etcd recovery test output
- `mongodb_recovery_wan.log` — Full MongoDB recovery test output
- `zookeeper_recovery_wan.log` — Full ZooKeeper recovery test output
