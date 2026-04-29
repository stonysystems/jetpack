# Akkio AWS latency experiment — 2026-04-29T03:05:33+00:00

Driver: [`run.sh`](run.sh) (next to this file).

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
- **500 total concurrent in-flight requests**, split 75% on z0 and the
  remaining 25% uniformly across z1–z4:

  | DC | sites | DC total n_conc | share |
  |---|---|---|---|
  | z0 California | 6 | **375** | 75.0% |
  | z1 Oregon | 6 | **32** | 6.4% |
  | z2 Mumbai | 6 | **31** | 6.2% |
  | z3 Frankfurt | 6 | **31** | 6.2% |
  | z4 Stockholm | 6 | **31** | 6.2% |
  | **total** | **30** | **500** | 100% |

  (Exact 25%/4 = 31.25; rounded with Oregon=32 so the four small DCs sum
  to 125 and the grand total is exactly 500.)

  Per-site `n_concurrent` therefore lands at non-integer averages (62.5
  for z0, 5.33 for z1, 5.17 for z2–z4). YAML needs either a per-host
  `concurrent_<dc>.yml` with mixed values inside each DC (e.g., z0:
  5 sites × 62 + 1 × 65 = 375; z1: 4 × 5 + 2 × 6 = 32; z2–z4:
  5 × 5 + 1 × 6 = 31), or per-site overrides in the akkio site map.

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
