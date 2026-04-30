# Akkio AWS latency experiment — batch ON, pipeline OFF (2026-04-30)

Driver: [`run.sh`](run.sh) (next to this file).

## Background and motivation

Two prior experiments establish the context:

- **`../2026-04-29-akkio/`**: AWS at 500 req/s offered, no pipelining
  (legacy). V1-raw and V3-lease saturated at ~11 req/s + 25 s p50
  because of the leader's serial AE loop. V4-jetpack-raft hit
  ~138 req/s + p50 172 ms with **fast-path engaging at ~32% rate**
  (leader CPU was 87%, below the FP_HI=95 throttle).

- **`../2026-04-30-akkio-pipeline/`**: AWS at 3000 req/s offered with
  pipelining ON (cap=8000). All variants pushed to ~2970 req/s
  aggregate, but **leader-core CPU pegged at 100%** at every offered
  load (3000 / 2000 / 1500 / 1000). The saturation suppressed the
  jetpack adaptive throttle (0 fast-path attempts on V4/V5) and the
  read-lease (lease window 100ms < 154ms commit-RTT). So jetpack and
  lease ended up looking identical to vanilla raft.

The investigation traced the CPU saturation to **pipelining itself**:
each pipelined AE is a separate RPC, so per-follower AE rate scales
with offered load (X req/s = X AE/s/follower) instead of the
1/RTT cap of the legacy serial loop or the batched mode. At 3000 req/s
that's ~5000 AEs/sec on the leader doing marshall+rrr+coro spawn+
callback work — easily 100% of one core.

**This run isolates the effect.** Same 3000 req/s offered load, but
pipelining is OFF. Batching alone delivers high throughput with
low AE rate (~5 AE/s/follower with N entries each). If the
hypothesis is right, the leader should have CPU headroom, the
adaptive throttle should disengage, and jetpack-fast-path /
read-lease should each show their 1-RTT advantages.

## Variants

| # | label | mode YAML | leader | sub-runs |
|---|---|---|---|---|
| V0 | V0-random | `none_raft.yml` | cycles z0..z4 | 5 |
| V1 | V1-raw | `none_raft.yml` | server0 (z0) | 1 |
| V3 | V3-lease | `none_raft_lease.yml` | server0 (z0) | 1 |
| V4 | V4-jetpack-raft | `rule_raft.yml` | server0 (z0) | 1 |
| V6 | V6-jetpack-raft-lease | `rule_raft_lease.yml` *(new)* | server0 (z0) | 1 |

9 experiments total (5 V0 sub-runs + 4 single-run variants).

All variants use the same binary: `batch_nopipe` (RAFT_BATCH_OPTIMIZATION
on, RAFT_PIPELINE_OPTIMIZATION off). The differentiator is the cc/ab
protocol path.

V2 (raft + batch) and V5 (jetpack + batch) from the previous matrix
are not run separately because **all variants here use batch=ON**;
V1 ≡ "what V2 was in akkio terms". V6 stacks read-lease on top of
jetpack — both optimizations active.

## Code changes shipped before this run

- `kReadLeaseDurationUs`: 100 ms → **250 ms** (commit `507809dc`).
  Without this V3-lease's lease window had zero overlap with the
  present on AWS (commit-RTT to Frankfurt is 154 ms > 100 ms lease).
  250 ms gives ~96 ms of useful window per refresh while staying
  safely below the 500 ms min election timeout.
- Pipelining is OFF in this binary (`--disable-raft-pipeline`), so
  HeartbeatLoop reverts to the legacy synchronous request→Wait→reply
  path at 1 entry/AE. With batching ON, each AE carries the full
  pending batch (~600 entries at 3000 req/s × 200 ms commit-RTT).

## Headline questions

1. **At 3000 req/s offered, leader-core CPU?** Hypothesis: **<50%**.
   Without pipelining, AE rate is `5 / RTT × 5 followers ≈ 25 AE/s`,
   each carrying many entries. Order-of-magnitude lower than the
   ~5000 AE/s the pipelined run produced. The bound replication core
   should have plenty of slack.

2. **Does V4-jetpack-raft show its 1-RTT advantage?** *Per-DC, yes.
   Integrated, mostly no.* Fast-path saves one client-leader RTT.
   For z0 California (client colocated with leader), there is no
   client-leader RTT to save → V4 z0 p50 ≈ V1 z0 p50. For remote DCs
   the savings are ~150 ms. Since z0 has 75% of the samples (from
   the 75/25 client distribution), the integrated p50 will be
   dominated by z0 → V4 ≈ V1 *integrated*. The interesting comparison
   is the per-DC breakdown for z2 / z3 / z4.

3. **Does V3-lease show benefit on reads?** Hypothesis: **yes, big**.
   With the lease duration bumped to 250 ms, lease should be valid
   continuously at steady state. Reads (50 % of `rw_akkio.yml`) skip
   the commit replication, saving the full ~154 ms commit-RTT.
   Distribution becomes bimodal: reads at ~1 client-leader RTT,
   writes at ~1 client-leader RTT + 154 ms commit-RTT. p50 lands in
   the lower (read) cluster.

4. **Does throughput hold at ~3000 req/s without pipelining?**
   Hypothesis: **yes**. Batching alone delivers any reasonable load
   in one batch / RTT / follower carrying many entries. Exactly the
   regime V2-batch from the previous run already proved.

5. **What is the latency penalty of dropping pipelining?**
   Hypothesis: **none for V1/V2-style protocols**. Without pipelining,
   batch covers all in-flight in one round-trip, queue ≈ 0. p50 ≈
   commit-RTT + (negligible). Same as the previous V2-batch.

## Per-DC and integrated predictions

Latency model components:
- `oneway(D, z0)` = one-way client → leader latency from DC D = `RTT/2`
- `commit-RTT` ≈ **154 ms** (round-trip to the 2nd-fastest follower, Frankfurt; same regardless of client location since the leader does the replication)
- Workload is **50 % reads + 50 % writes** (`rw_akkio.yml`)

Per-protocol cost per request type:
- **V1 / V3-write / V4-original / V6-write (no-fp)**: `2 × oneway + commit-RTT`
- **V3-read (lease valid)**: `2 × oneway` *(skips commit replication)*
- **V4-fast-path (R or W)**: `commit-RTT` *(fp eliminates the client-leader round-trip; only the leader's commit-RTT remains)*
- **V6-read (lease valid)**: `2 × oneway` *(same as V3 read; lease beats fp for reads since fp still pays commit-RTT)*
- **V6-write (fp)**: `commit-RTT`

The **p50** of a 50/50 mix at one DC lands halfway between the two cluster values (linear interpolation between the closest two samples around index N/2). The **avg** is the simple mean of the two clusters. So **per-DC p50 ≈ per-DC avg** in this workload.

For the **integrated** numbers, p50 and avg diverge because the population is weighted (75 % z0 + 6.25 % each z1–z4) and the median is determined by where the cdf crosses 50 %, not by the lowest cluster value.

### Per-DC predicted p50 / avg (ms)

Read-cluster value | write-cluster value → p50 = avg = mean of the two:

| client DC | RTT to z0 | V1: R / W → p50 ≈ avg | V3: R / W → p50 ≈ avg | V4: R / W → p50 ≈ avg | V6: R / W → p50 ≈ avg |
|---|---|---|---|---|---|
| z0 California | 0 (in-proc) | 154/154 → **154** | **0**/154 → **77** | 154/154 → **154** ¹ | **0**/154 → **77** |
| z1 Oregon | 18 ms | 172/172 → **172** | 18/172 → **95** | 154/154 → **154** | 18/154 → **86** |
| z3 Frankfurt | 154 ms | 308/308 → **308** | 154/308 → **231** | 154/154 → **154** ² | 154/154 → **154** ³ |
| z4 Stockholm | 167 ms | 321/321 → **321** | 167/321 → **244** | 154/154 → **154** | 167/154 → **160** |
| z2 Mumbai | 227 ms | 381/381 → **381** | 227/381 → **304** | 154/154 → **154** | 227/154 → **190** |

¹ z0 is colocated with the leader → fp saves nothing → V4 z0 ≈ V1 z0.
² V4 z3: fp removes the ~308 ms 2-RTT trip and leaves only commit-RTT.
³ V6 z3: by coincidence, oneway(z3,z0) ≈ commit-RTT/2, so 2×oneway ≈ commit-RTT — V6 read and V6-fp write land at the same value here.

### Integrated (75 % z0 + 6.25 % each z1-z4)

The integrated **p50** is dominated by the most-frequent value, which for V1/V3/V4/V6 is around 154 ms (z0's write cluster + several DCs' value-154 components combine to span well past cdf=50 %).
The integrated **avg** captures the actual savings:

| variant | integrated p50 | integrated avg |
|---|---|---|
| V0-random (5-sub-run mean) | ~280 | ~265 |
| V1-raw | **154** | **190** |
| V3-lease | **154** | **112** ← lease saves ~78 ms on average |
| V4-jetpack-raft | **172** | **174** ← fp helps remote DCs only; z0 unchanged or slightly worse |
| **V6-jetpack-raft-lease** | **154** | **~101** ← best: lease for reads + fp for writes |

So **avg is the right column to compare** here — p50 is dominated by California, where neither fp nor lease has anything to save (client is colocated with leader). The lease savings show up clearly in z0 reads but flatten out in the integrated p50 because the z0-write cluster (still 154 ms) anchors the median.

### Headline (integrated) — vs the previous experiment

| variant | prev (pipeline ON, lease 100 ms) p50 / avg | prev CPU | predicted now (pipeline OFF, lease 250 ms) p50 / avg | predicted CPU |
|---|---|---|---|---|
| V0-random | 283 / 271 | 100 % | ~280 / ~265 | <50 % |
| V1-raw | 167 / 201 | 100 % | **154 / 190** | <50 % |
| V3-lease | 167 / 200 (lease never valid) | 100 % | **154 / 112** ← lease engaged | <50 % |
| V4-jetpack-raft (integrated) | 172 / 204 (0 % fp) | 100 % | **172 / 174** ← fp engaged, but z0 z0 dominates p50 | <50 % |
| V4-jetpack-raft (z3 / z4 only) | ~325 / ~340 | 100 % | **~154 / ~154** ← fp 1-RTT win | <50 % |
| **V6-jetpack-raft-lease** *(new)* | n/a | n/a | **154 / 101** ← best of both | <50 % |

If V3 / V6 integrated **avg** lands near 110 ms / 100 ms *and* V4 z3 lands at ~155 ms,
all three conjectures are confirmed:
1. Pipelining was crowding out lease and fast-path at the bound core.
2. Lease bump from 100 → 250 ms unlocks V3 / V6's read benefit.
3. V4 fp savings show up per-DC even when integrated is z0-dominated.

V6 should be the avg headline: jetpack fp on writes (saving the client-leader RTT for far DCs) **plus** lease on reads (saving the commit-RTT for reads). p50 still lands at 154 ms because of California's structural dominance, but the avg drops the furthest.

## Cluster + workload (unchanged from prior experiments)

- 10 EC2 c5.2xlarge instances across California, Oregon, Mumbai,
  Frankfurt, Stockholm (5 server hosts + 5 spare). Inventory:
  `scripts/aws_instances.tsv`.
- 5-replica raft. Server pinned to core 1. Clients pinned to cores
  0,2,3,4,6,7. Leader = z0 California (raft_leader_locale=0).
- Akkio site map: 6 client sites × 5 DCs = 30 client sites total.
- 6× akkio offered load = ~3000 req/s. Per-site n_concurrent =
  `(372,30,30,30,30)` keeping the 75/25 California/rest split.
- Workload: `rw_akkio_zipf08.yml` — 50/50 read/write, 1M-key,
  **zipf coefficient 0.8** (more skewed than akkio's uniform 0).
- **Write payload**: 1 KB (set via `RW_VALUE_SIZE=1024` env var,
  read by `RwWorkload` at startup; injects a string at input map key 2,
  marshalled on the wire as part of every TxPieceData).
- Duration: 30s. Mid-window stats over the middle 10s.

## Workflow

```bash
cd results/2026-04-30-akkio-batch-pipeoff
./run.sh start             # start AWS instances + NFS remount
./run.sh build             # git pull + build deptran_server.batch_nopipe (1 binary)
./run.sh prep              # generate per-DC YAMLs on server0
./run.sh run V1            # smoke test: V1-raw alone
./run.sh run               # full V0+V1+V3+V4 sweep
./run.sh summary           # parse log/*.csv → summary.md
./run.sh stop              # stop AWS
```

## Open questions / followups (not blocking this run)

- **Jetpack fast-path even with pipelining**: if this run confirms
  pipelining is the CPU culprit, a follow-up could re-enable
  pipelining but raise FP_LO/FP_HI on the throttle, or move CPU
  measurement to "useful work" instead of "core busy" so the throttle
  responds to genuine saturation instead of busy-poll noise.
- **Pipelining cap tuning**: a pipeline cap=64 (instead of cap=8000)
  may let pipelining co-exist with jetpack — tested separately as a
  follow-up after this run lands.
- **Per-DC leader placement for V4**: V4's fast-path is essentially
  free for clients in the leader's DC. To showcase the win across the
  full 30-site population we could move the leader away from
  California (where 75% of clients live) and toward a smaller DC.
  V0-random already does this implicitly across 5 sub-runs.

---

> **Reproducibility rules**:
> 1. The experiment is run **only** through `./run.sh`. If something
>    fails, fix the script and re-run — never SSH into the AWS instances
>    and patch by hand.
> 2. All code changes to the JetPack repo go through git: edit on zoo →
>    `git commit` → `git push` (to `MintGreenTZ/JetPack`) → `git pull` on
>    the AWS NFS host (server0). Per-experiment yaml configs that the
>    runner generates on AWS (`leader_locale_*.yml`, `concurrent_z*.yml`,
>    the akkio site map) are scratch files, not git-tracked.

> **TODO before running**
> - **Code change**: promote `RAFT_BATCH_OPTIMIZATION`'s sibling
>   `raft_leader_locale` to a config field. See "Leader placement"
>   below for the diff sketch. Without this, V0/V1/V2/V3/V4/V5 all
>   end up with whatever locale the existing hardcode picks.
> - The per-DC concurrency split lands at 372/30/30/30/30 = 492 with
>   the script's default integer rounding (Z*_CONC env vars). If you
>   need exact 375/32/31/31/31 = 500, either supply per-site overrides
>   in the akkio site config (not currently supported) or override the
>   `Z{0..4}_CONC` env vars to non-uniform values per site within the
>   DC (would need a code/config tweak).

## How to run

```bash
cd results/2026-04-29-akkio

# One-shot: bring up cluster + build + generate configs + run V0–V5 + stop.
./run.sh all

# Or step-by-step (preferred while iterating):
./run.sh start      # aws_start_instances.sh + 04-nfs.sh + SSH-ready wait
./run.sh build      # build deptran_server.{no_batch, batch} on SERVER_0
./run.sh prep       # generate per-DC + leader_locale + akkio site yamls on SERVER_0
./run.sh run        # run all variants
./run.sh run V1,V2  # rerun a subset
./run.sh stop       # aws_stop_instances.sh
```

Common knobs (env vars accepted by `run.sh`):
- `DURATION=30`, `MODE=101`, `TIMEOUT=180`
- `Z0_CONC=62`, `Z1_CONC=5`, `Z2_CONC=5`, `Z3_CONC=5`, `Z4_CONC=5`
- `SITES_PER_DC=6`

## Cluster

- **5 AWS instances** (server0..server4 = California, Oregon, Mumbai,
  Frankfurt, Stockholm); c5.2xlarge (8 vCPUs, 1 NUMA node, 1 socket,
  4 physical cores × SMT2). Servers 05–09 (London, Hong Kong, Singapore,
  Ireland, Paris) are *not* used in this experiment.
- 5-replica consensus group (one replica per DC).
- **CPU pinning** — set via the repo's existing `pthread_setaffinity_np`
  calls (`SERVER_CORE_ID` for the server thread; the matching client-thread
  pinning logic for clients) — **not** via `taskset`:
    - server thread → core **0**
    - client threads → cores **1, 2, 3, 5, 6, 7**
    - core 4 (SMT sibling of core 0) is **left idle** so the server's
      physical core has no SMT contention.
    - clients on cores {1, 5}, {2, 6}, {3, 7} share physical cores
      pairwise but never share with the server.
- **No simulated WAN delay** (`WAN_DELAY_MS` unset). Real AWS cross-region
  RTTs (~25–225 ms — see `scripts/latency_results/`) are the actual delay.
- etcd binary: TBD on AWS — `dep.sh` does not install etcd. Install or
  build before V1/V2/V3 variants run.

### Leader placement

Raft leader location today is **hardcoded** at [src/deptran/raft/server.cc:1044](src/deptran/raft/server.cc#L1044):

```cpp
int _prio = (frame_->site_info_->locale_id == 1) ? 1 : 20;
```

`locale_id == 1` gets a short election timeout (5–10× heartbeat) and
reliably wins; the other four sites use `_prio=20` (~100–110 s timeout,
longer than the 30 s experiment, so they never campaign).

**Required code change for this experiment**: promote the favored locale
to a config field so each run can choose the leader independently.
Suggested implementation:

- Add `int raft_leader_locale_ = 0;` to `Config` (with getter
  `GetRaftLeaderLocale()`).
- Parse `mode.raft_leader_locale` from the protocol yaml in
  `Config::Load(...)` (next to `batch_start_`, `etcd_batch_size_`).
- Replace the constant in `server.cc:1044` with
  `(frame_->site_info_->locale_id == cfg->GetRaftLeaderLocale()) ? 1 : 20`.
- Create five small "leader override" yamls
  (`config/leader_locale_{0,1,2,3,4}.yml`), each with:
  ```yaml
  mode:
    raft_leader_locale: <N>
  ```
  and pass the appropriate one as the second `-f` arg in the run
  commands below.

**Per-variant default in this experiment**:

- **V1-raw / V2-batch / V3-lease / V4-jetpack-raft**: leader on
  **aws00 / server0 / California** (`locale_id=0`). The 75% of clients
  on z0 then talk to a co-located leader.
- **V0-random**: 5 sub-runs that cycle the leader across
  `locale_id=0..4` (server0..server4); the variant's reported numbers
  are the **average across the 5 sub-runs**. This is the "random
  leader placement" baseline against which V1–V4 are compared.

## Clients

- **6 client sites per DC × 5 DCs = 30 sites total.**
- **~3000 total concurrent in-flight requests** (6× akkio's ~500
  baseline, to push the offered load that pipelining is designed to
  serve), split 75% on z0 and the remaining 25% uniformly across z1–z4:

  | DC | sites | per-site n_conc | DC total n_conc | share |
  |---|---|---|---|---|
  | z0 California | 6 | **372** | **2232** | 75.6% |
  | z1 Oregon | 6 | **30** | **180** | 6.1% |
  | z2 Mumbai | 6 | **30** | **180** | 6.1% |
  | z3 Frankfurt | 6 | **30** | **180** | 6.1% |
  | z4 Stockholm | 6 | **30** | **180** | 6.1% |
  | **total** | **30** | — | **2952** | 100% |

  Total ≈ 3000 (off by 48 due to integer rounding to keep all sites in
  one DC equal). Approximately matches "6× akkio." With pipelining +
  cap=8000 the cap is far from filled (2232/5 = 446 in-flight per
  follower from California alone, well under 8000).

  Driver env vars: `Z0_CONC=372 Z1_CONC=30 ... Z4_CONC=30 SITES_PER_DC=6`
  (defaults baked into `run.sh`).

### Open-loop config (per-DC, generated by `run.sh prep`)

The intended workload is "**each concurrency-coroutine sends 1 cmd/s
with some offset; all `n_concurrent` coroutines can be in-flight
simultaneously; total run = 30 s**". To match that, the open-loop
parameters need:

- `rate = n_concurrent` (so each coroutine fires at ~1 cmd/s on
  average, since rate is per-site)
- `max_undone = n_concurrent` (otherwise in-flight is capped below the
  number of coroutines and most coroutines starve after the first
  burst)

`run.sh prep` now generates `config/client_open_z{0..4}.yml` per DC
with both fields set to the matching `Z<L>_CONC`. Each variant's
`run_variant` includes `-f config/client_open_z${i}.yml` instead of
the legacy `-f config/client_open_akkio.yml` (which had the zoo-Akkio
defaults `rate=1000`, `max_undone=20` — those *don't* fit this
experiment: 20 in-flight × 5 s WAN raft latency was producing only
~80 commits per 30 s on V1-raw, all clustered in a 1.7 s burst at
test start with no dispatches in the middle 1/3 window, leaving
`Mid throughput=0`).

Concrete per-DC client knobs after prep:

| DC | n_concurrent | rate | max_undone | DC total in-flight |
|---|---|---|---|---|
| z0 California | 62 | 62 | 62 | 372 |
| z1 Oregon | 5 | 5 | 5 | 30 |
| z2 Mumbai | 5 | 5 | 5 | 30 |
| z3 Frankfurt | 5 | 5 | 5 | 30 |
| z4 Stockholm | 5 | 5 | 5 | 30 |
| total | — | — | — | **492** (~500) |

## Workload

- `config/rw_akkio.yml`: uniform key distribution (`dist: zipf`,
  `coefficient: 0`), 1,000,000-key range, **50/50 read/write** mix.

## Variants

"Batch" in this experiment means **`RAFT_BATCH_OPTIMIZATION`**
(leader-side AppendEntries replication batching — see
[src/deptran/raft/server.cc:716-728](src/deptran/raft/server.cc#L716-L728)),
which is a **compile-time** `#define` in
[src/deptran/constants.h:208](src/deptran/constants.h#L208). V2 and V5
therefore use a binary built with the macro defined; V0, V1, V3, V4 use
a binary with it commented out. See "Two-build setup" below.

| Tag | Mode YAML | Leader | RAFT_BATCH_OPT | Notes |
|---|---|---|---|---|
| V0-random | `none_raft.yml` | cycles 0..4, avg of 5 | OFF | "Random leader" baseline. 5 sub-runs with leader on each of server0..server4; reported metrics are the average across the 5. Same workload + client setting as V1-raw. |
| V1-raw | `none_raft.yml` | server0 (z0) | OFF | Vanilla raft, leader on California. |
| V2-batch | `none_raft.yml` | server0 (z0) | **ON** | Same yaml as V1, but binary built with `RAFT_BATCH_OPTIMIZATION` defined → leader bundles all pending log entries into one AE RPC per follower. |
| V3-lease | `none_raft_lease.yml` | server0 (z0) | OFF | Lease-based linearizable reads (skips a round trip while leader lease is valid). |
| V4-jetpack-raft | `rule_raft.yml` | server0 (z0) | OFF | Jetpack over raft — fast-path + `merge_leader_rpc` (Dispatch + SpecExec fused). See `docs/2026-04-22_jp-raft-fp100_merge-rpc-and-pool-opts_ab.md`. |
| V5-jetpack-raft-batch | `rule_raft.yml` | server0 (z0) | **ON** | V4 + `RAFT_BATCH_OPTIMIZATION`. Tests whether replication batching adds anything on top of jetpack's RPC fusion. |

## Versions

- janus: `ded2da7f` on branch `jetpack`.
- All four variants are in-tree raft (`src/deptran/raft/...` + 
  `src/deptran/jp-raft/...`) — no external etcd binary needed for this
  experiment.

## Experiment details

- Each variant runs 30 s of workload. Per-host client latency is logged
  over the **middle 10 s** (the "Mid throughput is …" statistic uses the
  same window).
- Per-host p50/p90/p99 are parsed from
  `log/<variant>/<label>-<server N>.res` (line "All-efficient-attempts
  statistics …").
- Cross-host aggregate p50/p90/p99 come from merging the leader-side
  latency CSVs in `log/<variant>/` — see `scripts/merge_latency_csv.py`.

## Run pipeline (what `run.sh` does)

`run.sh` owns the whole pipeline. The subcommands map to the phases
below; `run.sh all` chains them end-to-end.

1. **`start`** — `bash scripts/aws_start_instances.sh`, wait for SSH on
   server0..server4, then `bash scripts/04-nfs.sh` (re-mount NFS so
   clients see SERVER_0's `/home/ubuntu/code`).
2. **`build`** — on SERVER_0 (NFS-shared), `git pull --ff-only` from
   `MintGreenTZ/JetPack`, then build twice and stash the artefacts as
   `build/deptran_server.no_batch` (with `python3 waf configure
   --disable-raft-batch build`) and `build/deptran_server.batch`
   (default). The `--disable-raft-batch` waf option defines
   `RAFT_BATCH_OFF`, which the `#ifndef RAFT_BATCH_OFF` guard at
   [src/deptran/constants.h:204-207](src/deptran/constants.h#L204-L207)
   uses to skip the `#define RAFT_BATCH_OPTIMIZATION`. **No source edits
   on AWS** — every code change goes through zoo (write/commit/push) →
   AWS (`git pull`).
3. **`prep`** — write the experiment's per-DC config yamls into
   SERVER_0's NFS-shared `JetPack/config/`:
   - `leader_locale_{0..4}.yml` (one-line `mode.raft_leader_locale: N` each)
   - `concurrent_z{0..4}.yml` (`n_concurrent: <Zi_CONC>`)
   - `akkio_6_6_6_6_6c1s5r1p-aws.yml` — site/process/host map for the
     5-replica raft group + 30 client sites (6 per DC).
4. **`run [Vs]`** — for each variant (default `all`), parallel-SSH to
   server0..server4, run `deptran_server.<bin>` with the matching
   protocol/leader/concurrency yamls, capture stdout/stderr to
   `log/<variant>-server<i>.res`, then `scp` the leader-side CSVs from
   SERVER_0's `JetPack/results/recent_csv/` to `log/`.
5. **`stop`** — `bash scripts/aws_stop_instances.sh`.

The variant matrix above is encoded directly in [`run.sh:cmd_run`](run.sh).
Per-variant invocations (V0..V5) call `run_variant <label> <proto>
<leader_locale> <bin_suffix>`, which expands to a parallel
`timeout 180s ssh ubuntu@<host> "cd JetPack && build/deptran_server.<bin>
  -f config/<proto>.yml -f config/leader_locale_<L>.yml
  -f config/client_open_akkio.yml -f config/<akkio site map>
  -f config/rw_akkio.yml -f config/concurrent_z<i>.yml
  -m 101 -d 30 -P server<i> -N <label>-server<i>"`.
Output and CSVs land in [`log/`](log).

### Aggregate latency tables

After all variants finish (V0–V5):

```bash
python3 scripts/merge_latency_csv.py \
    --input-dir results/2026-04-29-akkio/log \
    --output results/2026-04-29-akkio/summary.md
```


## Expected outputs

After all variants run, `results/2026-04-29-akkio/` should contain:

```
results/2026-04-29-akkio/
├── settings.md                                  (this file)
├── summary.md                                   (generated by merge_latency_csv.py)
└── log/
    ├── V0-random-leader0-server0.res            (V0 sub-run with leader=server0)
    ├── V0-random-leader0-server0.csv
    ├── V0-random-leader0-server1.res
    ├── …                                        (5 leaders × 5 hosts × 2 file types = 50)
    ├── V0-random-leader4-server4.csv
    ├── V1-raw-server0.res                       (deptran stdout/stderr per host)
    ├── V1-raw-server0.csv                       (per-request latency CSV)
    ├── V1-raw-server1.res
    ├── …                                        (5 hosts × 2 file types = 10)
    ├── V2-batch-server0.res
    ├── …
    ├── V3-lease-server0.res
    ├── …
    ├── V4-jetpack-raft-server4.csv
    ├── V5-jetpack-raft-batch-server0.res
    ├── …
    └── V5-jetpack-raft-batch-server4.csv
```

`log/` contains:
- V0-random: **5 sub-runs × 5 hosts × 2 file types = 50 files**
- V1, V2, V3, V4, V5: **5 variants × 5 hosts × 2 file types = 50 files**
- **total = 100 files**

`settings.md` and `summary.md` stay at the top level of the result
folder.

### `.res` (stdout from deptran_server)

Each `<variant>-serverN.res` should contain (as in the 2026-04-23 zoo
runs):

- `Mid throughput is <reqs/s>` — the headline per-host throughput, computed
  over the middle 10 s of the 30 s run. This is the success marker the
  09 runner greps for. Absent ⇒ the run did not reach the measurement
  phase (consensus failure, timeout, crash, etc.).
- `All-efficient-attempts statistics — min … p50 … p75 … p90 … p95 …
  p99 … p99.9 … max … avg … stddev` (ms) — per-host latency percentiles.
- `Deleted one.` — clean-shutdown marker.

### `.csv` (per-request latency)

One row per request that completed in the middle-10 s window, with at
least an `End2End-Latency` column (ms). Pulled from
`/home/ubuntu/code/JetPack/results/recent_csv/` on SERVER_0 (NFS-host).
The `merge_latency_csv.py` script unions these per variant to compute
the cross-host aggregate.

### `summary.md` (generated)

**One table per variant**, with one row per datacenter and a final
**`integrated`** row that unions all per-DC CSV samples and recomputes
percentiles + sums throughputs (so the integrated row is the true
cross-cluster distribution, not an average of per-DC percentiles).

Mid-10 s window throughout. Skeleton:

#### V1-raw

| host | samples | tput (req/s) | min (ms) | p50 | p90 | p99 | p99.9 | max | avg (ms) | stddev (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| z0 California (server0) | … | … | … | … | … | … | … | … | … | … |
| z1 Oregon (server1) | … | … | … | … | … | … | … | … | … | … |
| z2 Mumbai (server2) | … | … | … | … | … | … | … | … | … | … |
| z3 Frankfurt (server3) | … | … | … | … | … | … | … | … | … | … |
| z4 Stockholm (server4) | … | … | … | … | … | … | … | … | … | … |
| **integrated** | Σ samples | Σ tput | … | … | … | … | … | … | … | … |

How each cell is computed:

- **samples** — row count of `End2End-Latency` in that host's
  `<variant>-server<i>.csv`.
- **tput (req/s)** — `samples / 10` (mid-10 s window). The integrated
  row is the **sum** of per-DC throughputs (independent client streams).
- **min / p50 / … / max / avg / stddev** — quantile/stat over the
  `End2End-Latency` column of that host's CSV. The integrated row
  recomputes the same stats over the **union** of all 5 CSVs (so it
  reflects the actual cross-cluster distribution, weighted by sample
  count — i.e., dominated by z0 since it has 75% of the load).

Format mirrors [results/2026-04-23-akkio-etcd/summary.md](../2026-04-23-akkio-etcd/summary.md),
with the per-variant "Per-host" + "Cross-host aggregate" tables collapsed
into a single per-variant table that has the integrated row at the
bottom.

#### V0-random — averaged across 5 sub-runs

Same column layout as V1-raw, but every cell is the **mean across the
5 sub-runs** (`V0-random-leader0`, `V0-random-leader1`, …,
`V0-random-leader4`). For each sub-run, compute the per-DC and
integrated metrics independently; then average the resulting numbers
across the 5 sub-runs:

- **samples / tput** — mean of 5 per-sub-run values per row.
- **min / p50 / p90 / p99 / p99.9 / max / avg / stddev** — mean of 5
  per-sub-run percentiles per row. (Don't union all 25 CSVs — that
  would conflate the runs into a single distribution and overweight
  whichever sub-run produced more samples.)

Optionally: include a per-sub-run breakdown table elsewhere in
`summary.md` so the variance across leader positions is visible (very
useful — leader=server0 should be much faster than leader=server4 on
this workload).

#### V2-batch / V3-lease / V4-jetpack-raft / V5-jetpack-raft-batch

Same shape as V1-raw, repeated for each variant. Useful comparisons:

- **V1 vs V2**: isolates the impact of `RAFT_BATCH_OPTIMIZATION` on
  vanilla raft.
- **V4 vs V5**: same isolation, on top of jetpack RPC fusion.
- **V2 vs V5**: end-to-end "raft+batch" vs "jetpack+batch".
- **V0 vs V1**: cost of suboptimal leader placement under raw raft.

#### Headline (optional, for at-a-glance comparison)

A trailing one-row-per-variant table over the **integrated** row only:

| variant | samples | tput (req/s) | p50 (ms) | p90 (ms) | p99 (ms) | p99.9 (ms) | avg (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| V0-random | … | … | … | … | … | … | … |
| V1-raw | … | … | … | … | … | … | … |
| V2-batch | … | … | … | … | … | … | … |
| V3-lease | … | … | … | … | … | … | … |
| V4-jetpack-raft | … | … | … | … | … | … | … |
| V5-jetpack-raft-batch | … | … | … | … | … | … | … |

(Headline drops p75/p95 too — only the four percentiles you'd typically
cite in a paper.)

**Pass criteria** for each variant:
1. All 5 hosts produced a non-empty `.res` with a `Mid throughput is …`
   line and a `Deleted one.` shutdown marker.
2. Cross-host sample count consistent with `total_conc / avg_latency × 10 s`
   (e.g., ~10k samples at ~50 ms avg latency, ~25k at ~200 ms — exact
   number depends on the variant's WAN profile).
3. No `verify failed`, `Cannot assign requested address` (other than the
   benign rrr::Client warning), or stack-trace lines in any `.res`.
