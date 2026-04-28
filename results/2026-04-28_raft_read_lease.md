# Raft read-lease — 1-RTT linearizable reads

Date: 2026-04-28
Cluster: zoo1..zoo5, `SERVER_CORE_ID=17`, `WAN_DELAY_MS=20` (40 ms RTT)

## TL;DR

Reads in `cc:none + ab:raft` mode currently go through the full Raft
log-replication path (Dispatch → leader → AppendEntries quorum → leader
→ client = 2 RTT). When the new `raft_read_lease: true` flag is on, a
single-key read piece arriving at the partition leader is served from
the leader's local mdb if a lease is currently held, skipping the
replication round-trip. Sanity-test result on a read-only workload at
N=1 with the client co-located with the leader on zoo2:

| | tput | p50 | p90 | p99 |
|---|---|---|---|---|
| `none_raft.yml` (lease off) | 201 | 36 ms | 47 ms | 51 ms |
| `none_raft_lease.yml` (lease on) | 200 | **0.15 ms** | **0.23 ms** | **0.29 ms** |

5,088 lease hits, 1 miss across the 30 s run. Throughput is unchanged
because at N=1 the client side is what bounds the rate; at larger N
the saved 1 RTT per read translates into higher peak throughput too.

The figures are extreme here because the client is co-located with the
leader (the N=1 baseline shape — client and leader on the same host).
For a client on a remote host the lease-on path is still 1 RTT
(client → leader RPC) vs. 2 RTT for lease-off — i.e. the latency
roughly halves rather than going to zero.

## What was added

- **Config flag** `raft_read_lease: true` in the protocol yaml
  ([config/none_raft_lease.yml](../config/none_raft_lease.yml) is the
  canonical example). Independent of `cc:rule` / Jetpack / CURP — works
  with `cc:none + ab:raft` directly. `Config::IsRaftReadLease()`
  accessor.

- **Lease state on the leader**
  ([src/deptran/raft/server.{h,cc}](../src/deptran/raft/server.h)).
  Each `RaftServer` keeps:
  * `last_ae_send_us_[follower]` — per-follower SEND timestamp (NOT the
    ack timestamp — see safety argument below).
  * `lease_expires_us_` — monotonically advancing deadline updated by
    `RecomputeLeaseLocked()` after every successful AppendEntries
    quorum: anchor = the (n-1)/2-th most recent send among followers,
    deadline = anchor + `kReadLeaseDurationUs`.
  * `leader_warmup_until_us_` — set on `setIsLeader(true)` to
    `now + kReadLeaseDurationUs`; the leader cannot serve lease-protected
    reads inside the warm-up window. This guarantees that any lease
    held by a previous leader has definitely expired before this leader
    starts honouring its own lease (no two leaders can ever serve
    overlapping windows).

- **Read fast-path on the leader**
  ([src/deptran/none/scheduler.cc::SchedulerNone::Dispatch](../src/deptran/none/scheduler.cc#L9-L40)).
  After the existing local-mdb dispatch (which already populates
  `ret_output`), if the flag is on, the cmd decodes as a single-key read
  via `SimpleRWCommand::ExtractPoolKeys`, and the leader holds a valid
  lease, the function returns `SUCCESS` immediately — skipping
  `OnCommit` and therefore the Raft `Submit` round-trip. Lease misses
  (warm-up not elapsed, lease lapsed, ExtractPoolKeys fails, or this
  server isn't the leader) silently fall through to the existing
  replicated path. Writes always take the replicated path.

- **Numbers**: `kReadLeaseDurationUs = 100,000` (100 ms). Bounded
  - **above** by RTT (40 ms) — must exceed RTT so the lease window
    measured at lease-stamp time still has positive remaining validity;
  - **below** by the smallest follower election timeout minus a clock
    skew budget. Followers (locale_id != 1) use `_prio = 20` in the
    existing election-timeout formula → 500–1000 ms timeouts → 100 ms
    is safely below that with a 400 ms margin.

  Adjust if `WAN_DELAY_MS` or `_prio` change.

## Safety argument (linearizability)

The lease invariant is:

> While the leader's `lease_expires_us_` is in the future and the
> warm-up window has elapsed, no other replica can have been elected
> leader for the same partition, so the leader's local mdb state is
> the authoritative view for any committed write.

Why it holds:

- The lease anchor for a follower is the time the leader **sent** the
  AE to that follower. The follower does not reset its election timer
  until it **receives** the AE, which is at least the anchor moment
  (and possibly later by up to one_way_latency). So a follower's
  earliest possible vote is `anchor + min_election_timeout` — strictly
  later than `anchor + kReadLeaseDurationUs` because
  `kReadLeaseDurationUs < min_election_timeout - skew_budget`.
- The `(n-1)/2`-th most recent send is the anchor used for the lease
  deadline. By construction `(n-1)/2 + 1 = quorum` followers have
  received an AE no later than that anchor, so a quorum's election
  timers don't expire before `anchor + kReadLeaseDurationUs`. A
  competing leader needs a quorum of votes; therefore no competing
  leader can have been elected during the window.
- The warm-up at `setIsLeader(true)` covers the case where the
  previous leader's lease was still in flight at the moment this
  replica was elected: the warm-up of `kReadLeaseDurationUs` is
  sufficient because the previous leader's lease was bounded by the
  same constant.

Single-shard scope: the lease is per-partition. Multi-shard reads
(out of scope for this change) would need lease validity at the
moment of dispatch on every touched shard.

## Reproducing

```bash
python3 waf configure build

# lease OFF (existing baseline):
SERVER_CORE_ID=17 \
  scripts/run_single_exp.sh none_raft.yml 0 concurrent_500.yml \
  leaseoff-N1 results/<date>-readlease 1c1s5r5p-zoo2.yml \
  rw_readonly_1000000.yml

# lease ON:
SERVER_CORE_ID=17 \
  scripts/run_single_exp.sh none_raft_lease.yml 0 concurrent_500.yml \
  leaseon-N1 results/<date>-readlease 1c1s5r5p-zoo2.yml \
  rw_readonly_1000000.yml

# Compare All-efficient-attempts statistics in the zoo2 .res files.
```

`scripts/run_single_exp.sh` now takes an optional 7th argument for
the workload yaml (default `rw_1000000.yml`); use
`rw_readonly_1000000.yml` for read-only sweeps.
