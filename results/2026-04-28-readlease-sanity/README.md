# Raft read-lease sanity sweep

Date: 2026-04-28
Cluster: zoo1..zoo5, `SERVER_CORE_ID=17`, `WAN_DELAY_MS=20`, 30 s per
data point, 500 ongoing per client, single-shard 5-replica Raft.
Workload: `rw_readonly_1000000.yml` (1 M-key uniform reads).
Layout: `1c1s5r5p-zoo2.yml` (single client co-located with the leader
on zoo2).

Companion design / safety / reproduction doc:
[../2026-04-28_raft_read_lease.md](../2026-04-28_raft_read_lease.md).

## Summary table

Per-cmd `End-to-End-Latency` distribution from zoo2's `.res` file
(`All-efficient-attempts statistics` line):

| run | cfg | tput | p0 | p50 | p90 | p99 | avg | count |
|---|---|---|---|---|---|---|---|---|
| `leaseoff-N1` | `none_raft.yml` | 201 | 21.4 ms | 36.0 ms | 46.6 ms | 50.8 ms | 36.1 ms | 2013 |
| `leaseon-N1-v5` | `none_raft_lease.yml` | 200 | 0.10 ms | **0.15 ms** | **0.23 ms** | **0.29 ms** | 0.17 ms | 2000 |

5,088 lease hits, 1 lease miss across the lease-on run (debug counters
in v3/v4 logs). Throughput is unchanged at N=1 because the client side
is what bounds the rate; the latency drop is the relevant signal. With
the client co-located with the leader, the lease-hit path skips the
network entirely (sub-millisecond local mdb dispatch), so the gap
looks extreme; for a remote client the lease still saves 1 of 2 RTTs
(latency roughly halves).

## Files in this folder

The folder accumulates several iteration runs from the implementation
session. The headline comparison is **`leaseoff-N1-*`** (lease off,
unmodified `none_raft.yml` baseline) versus **`leaseon-N1-v5-*`**
(lease on, after fixing the lease-duration constant — see below).

| run prefix | which iteration |
|---|---|
| `leaseoff-N1` | lease off baseline (no flag) |
| `leaseon-N1` | first lease-on attempt; lease never fires (lease duration too short) |
| `leaseon-N1-v2` | second attempt with debug logs added; build was stale, identical to v1 |
| `leaseon-N1-v3` | first run with diagnostic counters; revealed `miss(no_lease)` on every read |
| `leaseon-N1-v4` | added per-call `READ_LEASE_DIAG` log; revealed lease was 5–224 µs past expiry |
| `leaseon-N1-v5` | bumped `kReadLeaseDurationUs` from 20 ms to 100 ms — works |

The intermediate runs are kept for diagnostic context; only the v5 row
above is the final result.

## Per-replica artifacts

For each run (`leaseoff-N1`, `leaseon-N1-v5`, etc) the harness writes
five `.res` (server log), five `.csv` (per-cmd latency samples), and
five `-cpustat.txt` (per-second core-17 CPU samples) — one per replica
zoo1..zoo5. The leader is zoo2 throughout.

## Bug timeline (one-liner per iteration)

- **v1**: lease never fires; lease duration 20 ms, AE RTT 40 ms ⇒ at
  the moment the leader stamps the lease (RTT after the anchor SEND),
  the lease window has already lapsed by 20 ms. Diagnosis required
  per-call instrumentation (v3 → v4).
- **v2**: build was a no-op (waf cache confused after previous `rm -rf
  build`); rebuilding with `python3 waf configure build` from the repo
  root clears it. Re-ran with the same `leaseon` label as v3/v4 once the
  build was fresh.
- **v3**: counter logs in `SchedulerNone::Dispatch` confirm
  `lookup`/`write`/`no_raft` misses are zero; every miss is `no_lease`.
- **v4**: diagnostic log inside `HasReadLease` shows the lease
  consistently expired 5–224 µs ago at read time, and
  `last_ae_send_us_` map has all 4 followers tracked. The bottleneck is
  lease_duration < AE RTT.
- **v5**: bumped `kReadLeaseDurationUs` from 20,000 to 100,000 µs.
  Lease now valid most of the time; 5,088 hits / 1 miss across 30 s.

## How to reproduce just the headline comparison

```bash
SERVER_CORE_ID=17 \
  scripts/run_single_exp.sh none_raft.yml 0 concurrent_500.yml \
  leaseoff-N1 results/<date>-readlease 1c1s5r5p-zoo2.yml \
  rw_readonly_1000000.yml

SERVER_CORE_ID=17 \
  scripts/run_single_exp.sh none_raft_lease.yml 0 concurrent_500.yml \
  leaseon-N1 results/<date>-readlease 1c1s5r5p-zoo2.yml \
  rw_readonly_1000000.yml
```

Compare the `All-efficient-attempts statistics` line in the zoo2
`.res` file from each run.
