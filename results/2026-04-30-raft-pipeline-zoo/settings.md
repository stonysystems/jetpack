# 2026-04-30-raft-pipeline-zoo — settings

Local-zoo experiment to validate the new pipelined-AppendEntries
optimization for raft (no batching). Baseline = the akkio-style
serial AE loop that sends one entry per AE and waits for the reply
before sending the next. Pipelined = the new HeartbeatLoop that
sends multiple AEs in flight, advances `next_index` optimistically,
and processes replies in async coroutines.

WAN is **simulated** via `WAN_DELAY_MS=100`. The `WAN_WAIT` macro is
applied only on the leader's *send* path in `commo.cc` — the follower's
reply travels back over real loopback (~0.1 ms). So effective simulated
RTT ≈ **100 ms** (one-way only, not 200 ms round-trip). All 5 replicas are on the local zoo cluster, so this measures
the effect of the protocol change in isolation from real-network
jitter / region-asymmetry.

## Cluster layout

5 raft replicas + 1 client process across 4 zoo machines (zoo-005
deliberately avoided per user request — it has higher background
load than zoo-001..004 and we want to keep the per-host CPU floor
clean).

| process | host       | role                                      |
|---------|------------|-------------------------------------------|
| s101    | zoo-001    | leader replica (locale 0; raft_leader_locale=0) |
| c01     | zoo-001    | client (open-loop, n_concurrent coros)    |
| s201    | zoo-002    | follower (locale 1)                        |
| s501    | zoo-002    | follower (locale 4) — colocated with s201  |
| s301    | zoo-003    | follower (locale 2)                        |
| s401    | zoo-004    | follower (locale 3)                        |

zoo-002 hosts two follower processes. Under simulated WAN, every
inter-replica RPC pays the same `WAN_DELAY_MS` regardless of physical
colocation, so this only adds CPU sharing, which is fine for
follower processes.

`/home` is NFS-shared across all zoo hosts, so the binary in
`/home/users/ztang/janus/build/` is automatically visible from
zoo-001..004. We only need to SSH once per host (each
`deptran_server` invocation hosts every process mapped to that host
in the YAML).

## Variants matrix (4 cells)

| label                  | RAFT_BATCH_OPTIMIZATION | RAFT_PIPELINE_OPTIMIZATION | binary                                    |
|------------------------|--------------------------|------------------------------|-------------------------------------------|
| V1-raw                 | OFF                      | OFF                          | `build/deptran_server.nobatch_nopipe`     |
| V1-pipeline            | OFF                      | ON  *(new)*                  | `build/deptran_server.nobatch_pipe`       |
| V2-batch               | ON                       | OFF                          | `build/deptran_server.batch_nopipe`       |
| V2-batch+pipeline      | ON                       | ON  *(new)*                  | `build/deptran_server.batch_pipe`         |

V1-raw is the worst-case baseline: 1 entry per AE, 1 in-flight per
follower → throughput per follower ≈ 1 / RTT. With 200 ms RTT this
hits the ~5 entries/sec ceiling we saw in akkio.

V1-pipeline drops the synchronous Wait. `kMaxInFlightPerFollower`
AEs per follower at most, optimistic `next_index` advance, async
reply via `Coroutine::CreateRun`.

This experiment was run at **cap=64** (capacity = 64/0.1s = 640
commits/s, comfortably above offered=500/s — sized to exit the
saturated regime that cap=32 produced on the first run).

The shipped default in `server.h` is `kMaxInFlightPerFollower = 8000`,
sized for the bandwidth-delay product of an AWS-WAN deployment at 20k
req/s with 200 ms real RTT (4000 + 2× headroom). The cap is a max,
not a preallocation, so the higher default has no cost at low load.

V2-batch is the existing workaround — pack `[next_index..lastLogIndex]`
into one AE per round-trip. Throughput is then bounded by leader CPU
+ commit-cadence × batch size.

V2-batch+pipeline composes both. With cap=32 and batches that grow
under load, in-flight × batch-size grows → expected ceiling well
above offered load.

## Build flags

The two flags are independent compile-time toggles defined in
`src/deptran/constants.h`:

```c
#ifndef RAFT_BATCH_OFF
#define RAFT_BATCH_OPTIMIZATION
#endif

#ifndef RAFT_PIPELINE_OFF
#define RAFT_PIPELINE_OPTIMIZATION
#endif
```

`waf` options:

| flag                             | result                          |
|----------------------------------|---------------------------------|
| (none, default)                  | both ON  → `batch_pipe` binary  |
| `--disable-raft-pipeline`        | batch ON, pipeline OFF          |
| `--disable-raft-batch`           | batch OFF, pipeline ON          |
| `--disable-raft-batch --disable-raft-pipeline` | both OFF (legacy)  |

## Pipelined HeartbeatLoop, in brief

`src/deptran/raft/server.cc:HeartbeatLoop` under
`#ifdef RAFT_PIPELINE_OPTIMIZATION`:

- Per follower, two new fields in `server.h` track
  `sent_index_[follower]` (optimistic send watermark, ≥ next_index_-1)
  and `in_flight_count_[follower]` (#AEs sent but reply not yet
  applied; capped at `kMaxInFlightPerFollower = 64`).
- Loop body: wait on the per-follower replication event with
  `HEARTBEAT_INTERVAL` timeout (unchanged), update commit index
  (unchanged), then **drain**: in a tight loop, grab `mtx_`, check the
  in-flight cap, pick the next entry (`sent + 1`) or emit one heartbeat
  if caught up, advance `sent_index_` optimistically, drop the lock,
  spawn a per-AE coroutine.
- Per-AE coroutine: calls `commo()->SendAppendEntries2(...)`, waits
  on its own `IntEvent`, then takes `mtx_` and applies the reply
  (term step-down on higher term, decrement `next_index_` and rewind
  `sent_index_` on reject, monotonic advance of `next_index_` /
  `match_index_` on accept, `last_ae_send_us_` lease anchor on
  accept). Calls `NotifyReplicationEvents()` so the heartbeat loop
  re-drains if the in-flight cap had been blocking it.
- Reject-rewind: `next_index_` decrements by 1 (existing semantics);
  in addition `sent_index_ = next_index_ - 1` so the next drain
  re-sends from the new `next_index_`. Pipelined replies arrive
  out-of-order so all next/match advances are now monotonic-only —
  no overwrite by stale replies.
- Composition with batch: inside the drain, when
  `RAFT_BATCH_OPTIMIZATION` is also defined, each AE carries the
  full `[send_idx..lastLogIndex]` batch and `sent_index_` jumps to
  `lastLogIndex` in one step — same as the legacy batch path, just
  with the cap-bounded async send wrapper.

## Workload

- Workload: `config/rw_1000000.yml` — read+write key-value with 1M
  keys.
- Mode: `0` (none / pure replication, no transactions).
- Duration: `30 s`.
- Client: open-loop. `rate = n_concurrent`, `max_undone = n_concurrent`
  → each coroutine sends 1 req/s, all coros can have 1 in-flight at
  once. Matches the akkio fix for the early-burst-then-stall problem.
- `n_concurrent`: 500 coroutines on `c01` (matches akkio).

## Per-host parameters

- `WAN_DELAY_MS=100` exported on every replica before launch
  (read by `s_main.cc` to seed `wan_delay_us`, applied by
  `WAN_WAIT` macro at every send in `commo.cc`).
- `SERVER_CORE_ID=1` for thread pinning consistency (matches
  the existing zoo experiment scripts; doesn't affect protocol
  behavior at this latency).

## Expected outcomes

Capacity model (100 ms RTT, 5 replicas in lockstep, majority = 3/5):

| variant            | per-follower capacity    | server commit capacity | per-cmd latency floor |
|--------------------|--------------------------|-------------------------|------------------------|
| V1-raw             | 1 / RTT = 10 req/s       | 10 req/s                | ~100 ms (1 RTT)        |
| V1-pipeline (cap=64) | 64 / RTT = 640 req/s   | 640 req/s               | ~100 ms                |
| V2-batch           | unbounded (1 AE/RTT carries all queued entries) | offered-load-bounded   | ~100 ms                |
| V2-batch+pipeline  | unbounded                 | offered-load-bounded   | ~100 ms                |

Offered load = 500 req/s. With V1-raw, capacity 10/s ≪ offered → severe
saturation; under `max_undone=500` backpressure, Little's law predicts
W = L/λ = 500/10 = 50 s (we see ~12.5 s because the run ends before
steady state is reached). With V1-pipeline cap=64, capacity 640/s >
offered → no saturation; W ≈ RTT ≈ 100 ms. V2-batch and V2-batch+pipeline
are similarly offered-load-bounded.

If V1-pipeline lands close to V1-raw, something's wrong with the
pipelining. If V1-pipeline lands close to V2-batch, the optimization
is working as designed.

## Reproducing

```
cd /home/users/ztang/janus
bash results/2026-04-30-raft-pipeline-zoo/run.sh build       # waf x4
bash results/2026-04-30-raft-pipeline-zoo/run.sh prep        # write zoo YAML
bash results/2026-04-30-raft-pipeline-zoo/run.sh run         # all 4 variants
bash results/2026-04-30-raft-pipeline-zoo/run.sh summary     # parse log/ → summary.md
```

`run.sh all` does build → prep → run → summary in sequence.

CSV files (`<variant>-<host>.csv`) and stdout `.res` files end up
under `log/`. The summary script reads CSV `End2End-Latency` and
writes per-host + integrated rows like akkio's `summary.md`.
