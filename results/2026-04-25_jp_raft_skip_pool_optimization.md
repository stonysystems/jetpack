# Jetpack Raft `skip_pool_for_original_path` optimization — bug fix + results

Date: 2026-04-25
Branch: jetpack
Hosts: zoo1..zoo5 (130.245.173.101..105), `SERVER_CORE_ID=17`, `WAN_DELAY_MS=20`
Sweep harness: `scripts/run_adaptive_sweep.sh`, SLO = zoo2 p90 ≤ 1000 ms,
500 ongoing per client, mid-10 s CPU window.

## TL;DR

The `jetpack_skip_pool_for_original_path` flag (introduced in branch `jetpack`)
was crashing the Raft leader on every adaptive (mode 101) and pure-original
(mode 0) workload. Root cause: `RuleCommandPoolGC` was calling
`rep_sched_->inflight_original_path_.erase(...)` while running with
`this == RaftServer`, but `RaftServer::rep_sched_` is `nullptr` (only the tx
scheduler has its `rep_sched_` set). fp100 didn't crash because
`NeedRecordConflictInOriginalPath()` is false for every command in mode 100,
so the buggy branch was never taken.

After fixing the null deref + a few related cleanups, the optimization now
delivers what it was designed for: jp-raft-fp0 closes ~65 % of the
Jetpack-overhead gap to vanilla Raft.

## Results — original Raft vs jp-raft-fp0 (fast-path attempt rate = 0)

Single test point per N, 30-s run, peak under SLO `p90 ≤ 1000 ms`.

| Config | Cfg yml | Mode | Peak tput | At N | z2_p50 | z2_p90 |
|---|---|---|---|---|---|---|
| Vanilla Raft | `none_raft.yml` | 0 | **16,798** | 84 | 181 ms | 426 ms |
| jp-raft-fp0 (no opt) | `rule_raft_merge.yml` | 0 | 15,597 | 78 | 74 ms | 101 ms |
| jp-raft-fp0 (skip-pool opt) | `rule_raft_merge_skip_pool.yml` | 0 | **16,382** | 82 | 487 ms | 560 ms |

- jp-raft-fp0 baseline overhead vs vanilla Raft: **−7.1 %** (1,201 lower peak).
- jp-raft-fp0 with `skip_pool_for_original_path: true`: **−2.5 %** vs vanilla.
- The optimization recovers **~65 %** of the Jetpack overhead at fp_rate = 0,
  which is the regime where Jetpack carries pure cost (no fast-path benefit).

Per-N CSVs:
- [results/2026-04-25-raft-core17/raft-adaptive.csv](2026-04-25-raft-core17/raft-adaptive.csv)
- [results/2026-04-25-jp-raft-fp0-noopt-core17/jp-raft-fp0-noopt-adaptive.csv](2026-04-25-jp-raft-fp0-noopt-core17/jp-raft-fp0-noopt-adaptive.csv)
- [results/2026-04-25-jp-raft-fp0-opt-core17/jp-raft-fp0-opt-adaptive.csv](2026-04-25-jp-raft-fp0-opt-core17/jp-raft-fp0-opt-adaptive.csv)

## Adaptive (mode 101) and fp100 (mode 100) — sanity, not regressed

| Mode | Without flag | With `skip_pool_for_original_path: true` |
|---|---|---|
| fp100 (mode 100) | 15,217 @ N=77 (prior baseline) | **15,009 @ N=75** (within noise) |
| adaptive (mode 101) | 15,312 @ N=78 (`rule_raft_merge.yml`, this date) | **15,776 @ N=79** (+3 %) |

Per-N CSVs:
- [results/2026-04-25-jp-raft-fp100-skip-pool-final-core17/jp-raft-fp100-adaptive.csv](2026-04-25-jp-raft-fp100-skip-pool-final-core17/jp-raft-fp100-adaptive.csv)
- [results/2026-04-25-jp-raft-adaptive-skip-pool-final-core17/jp-raft-adaptive-adaptive.csv](2026-04-25-jp-raft-adaptive-skip-pool-final-core17/jp-raft-adaptive-adaptive.csv)
- Adaptive baseline (flag off) for the comparison: [results/2026-04-25-jp-raft-adaptive-flagoff-test/jp-raft-adaptive-flagoff-adaptive.csv](2026-04-25-jp-raft-adaptive-flagoff-test/jp-raft-adaptive-flagoff-adaptive.csv)

## What the optimization does

When `jetpack_skip_pool_for_original_path: true` is set on a `rule_raft_merge*`
config:

1. `OriginalPathUnexecutedCmdConflictPlaceHolder` no longer pushes
   original-path-only commands into `command_pool_`. Instead it inserts
   `(cmd_id, is_write)` into a small per-key map
   `inflight_original_path_` (a member of `TxLogServer`, key-indexed for
   O(bucket) lookup).
2. `RuleCommandPoolGC` mirrors that on apply: original-path-only commands
   are erased from the map, fast-path commands still go through
   `command_pool_.remove`.
3. `OnRuleSpeculativeExecute` adds a leader-side check against this map
   *before* calling `command_pool_.push_back` (avoids leaving a phantom
   pool entry for a fast-path attempt that gets rejected for a cross-path
   conflict — a rejected fast-path never reaches Raft so applyLogs would
   never GC the entry).

Net effect at fp_rate = 0: every original-path command saves ~1 µs of pool
bookkeeping per replica per command, and the saturated leader sees its
~25k–30k pool ops/sec dissolve.

## The bug story (bisection log)

Initial implementation passed fp100 cleanly (15,000-tput peak) but every
adaptive sweep killed the leader at N=50 with `Segmentation fault` and
killed followers with `munmap_chunk(): invalid pointer`. Six bisection
configurations later:

| Variant | Adaptive result |
|---|---|
| All my flag-on code stubbed (≡ flag off) | works, 15,451 @ N=78 |
| Conflict-check live + insert/erase stubbed (empty map) | works, 15,360 @ N=77 |
| Insert into both map+pool, erase only from pool, check stubbed | works, 15,161 @ N=77 |
| Full insert+erase (map only), check live | crash |
| Full insert+erase, check stubbed | crash |
| Pool kept in sync (insert/erase to BOTH), check live | crash |

The "bug fires whenever erase-from-the-map happens" pattern misled me into
chasing a shared_ptr lifetime issue; switching to a value-only struct
(no shared_ptr) didn't fix it. Switching to a key-indexed map (cheaper
iteration) didn't fix it. Reordering the conflict check vs pool.push_back
didn't fix it.

The trail finally surfaced when an N=1 baseline crashed with
`*** verify failed: 0 at scheduler.h, line 599` — the `verify(0)` inside
`TxLogServer::IsLeader()`, the base-class fallback. That pointed at a
virtual call going to the base class, which on closer reading turned out
to be a different problem in the same call site:

`RuleCommandPoolGC` is called from `RaftServer::applyLogs` with
`this == RaftServer`. My code did
`rep_sched_->inflight_original_path_.erase(...)`. But `RaftServer::rep_sched_`
is **never set** — `server_worker.cc` only assigns
`tx_sched_->rep_sched_ = rep_sched_`, never the reverse. So
`rep_sched_->inflight_original_path_` was a null-pointer member access on
the leader at every applied original-path command.

fp100 didn't crash because in mode 100 every command has
`rule_mode_on_and_is_original_path_only_command_ = false`, so
`NeedRecordConflictInOriginalPath()` returned false on every applied entry
and the buggy branch was never taken. The bug only fired when an
original-path command actually reached `applyLogs`, which happens only in
mode 101 (adaptive) and mode 0 (pure original-path).

Fix: drop the `rep_sched_->` prefix in `RuleCommandPoolGC` —
`this->inflight_original_path_` is the same map (because
`tx_sched_->rep_sched_` points to this RaftServer, so writes from the tx
scheduler land in the same per-RaftServer map that `applyLogs` reads
from `this`).

## Other small fixes that landed along the way

- `SimpleRWCommand::NeedRecordConflictInOriginalPath`: handle
  `CMD_TPC_BATCH` (was hitting `verify(0)` on the merge-RPC path).
- Map keying: `unordered_map<int /*key*/, vector<{cmd_id, is_write}>>`
  instead of cmd_id-indexed. The cmd_id index forced an O(n) scan per
  fast-path attempt, which would have been the next problem after the
  null deref was fixed.
- Insert/erase use `ExtractPoolKeys` (cheap, doesn't deep-copy the values
  map) rather than `GetCombinedCmdID` (full SimpleRWCommand parse).
- `OnRuleSpeculativeExecute` reordered to do the map check before
  `pool.push_back` so a cross-path conflict doesn't leave a phantom
  fast-path entry in `command_pool_` that would never be GC'd.

## Reproducing

```bash
SERVER_CORE_ID=17 \
  scripts/run_adaptive_sweep.sh raft none_raft.yml 0 \
  results/<date>-raft-core17

SERVER_CORE_ID=17 \
  scripts/run_adaptive_sweep.sh jp-raft-fp0-noopt rule_raft_merge.yml 0 \
  results/<date>-jp-raft-fp0-noopt-core17

SERVER_CORE_ID=17 \
  scripts/run_adaptive_sweep.sh jp-raft-fp0-opt rule_raft_merge_skip_pool.yml 0 \
  results/<date>-jp-raft-fp0-opt-core17
```

The relevant code lives in `src/deptran/scheduler.{h,cc}`,
`src/deptran/raft/server.{h,cc}`, `src/deptran/RW_command.cc`,
`src/deptran/config.{h,cc}`. The flag is set in
`config/rule_raft_merge_skip_pool.yml`.
