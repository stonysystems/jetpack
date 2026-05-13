# JetPack camera-ready experiments — settings & expectations (AWS)

This folder is the **single entry point** for reproducing every result
JetPack reports in the camera-ready paper. All runs are **AWS-only**;
the Zoo cluster path is intentionally out of scope here. Everything
below is derived directly from
[`scripts/10-run_all.sh`](../10-run_all.sh) +
[`scripts/experiment_defs.sh`](../experiment_defs.sh) — the canonical
experiment driver — with one camera-ready override:

> **Raft protocol**: camera-ready uses `rule_raft` (the in-tree raft
> sibling), **never** `rule_fpga_raft`. The legacy AWS protocol-family
> array in
> [`experiment_defs.sh:36`](../experiment_defs.sh#L36)
> currently lists `rule_fpga_raft` as the JetPack-Raft entry; the
> camera-ready driver must override that to `rule_raft` (either patch
> `LEGACY_JETPACK_PROTOCOLS[0]` or pass an env override before
> sourcing). Every reference to JetPack-Raft in this document means
> **`rule_raft`**.

The plan is:

1. `settings.md` (this file) — reference for what runs, why it runs,
   what comes out, and what counts as success.
2. `run.sh` (forthcoming) — one-click driver that wraps
   `10-run_all.sh` with the camera-ready argument set, gathers all
   artefacts, and regenerates the paper's figures/tables.

Until `run.sh` lands, the manual recipe is:

```bash
cd scripts
./10-run_all.sh full --exp 0   # rpcgen + build, then concurrency sweep
python3 derive_fixed_conc.py   # produces results/fixed_conc.json
./10-run_all.sh --exp 1,2      # zipf + key-range sweeps
```

---

## 1. Cluster

| field | value |
|---|---|
| environment | `aws` (set in [`scripts/setup.json`](../setup.json)) |
| site config | `60c1s5r10p` |
| hosts | 10× EC2 `c5.2xlarge` (8 vCPU, 1 socket, 4 physical cores × SMT2) across 5 AWS regions: California, Oregon, Mumbai, Frankfurt, Stockholm — 5 servers + 5 spare clients |
| replica naming | `server0..server4` (one replica per region) |
| repo path on host | `/home/ubuntu/code/JetPack` (NFS-shared from `server0`) |
| WAN delay | real cross-region RTT (no `WAN_DELAY_MS` injection) |

Inventory: [`scripts/aws_instances.tsv`](../aws_instances.tsv) and
[`scripts/setup.json`](../setup.json) (`servers[]`).

The driver reads `setup.json` to pick the AWS protocol families,
sites, and concurrency arrays — see
[`10-run_all.sh:111-117`](../10-run_all.sh#L111-L117).

## 2. Build pipeline

`10-run_all.sh full|build` SSHes to **server0 only** (NFS-shared with
the rest) and runs:

| arg | command on server0 |
|---|---|
| `full` | `bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc && python3 add_virtual.py && python3 waf configure --disable-raft-pipeline build` |
| `build` | `python3 waf configure --disable-raft-pipeline build` |
| *(none)* | *(no rebuild — uses whatever binary is already on NFS)* |

The build produces `build/deptran_server`, the single binary every
experiment invokes. **Camera-ready raft default: batching ON, pipeline
OFF** — `--disable-raft-pipeline` defines `RAFT_PIPELINE_OFF` at
[`src/deptran/constants.h`](../../src/deptran/constants.h), reverting
the leader's HeartbeatLoop to the legacy 1-AE-RPC/RTT path that
carries the full pending batch (batching itself stays on by default;
`--disable-raft-batch` would turn that off, which we do not want).

Rationale: pipelining at the AWS WAN scale issues one AE-RPC per
in-flight client request, saturating the leader's bound replication
core at high offered load and crowding out JetPack's fast-path /
lease optimizations. Batching alone delivers the same throughput in 1
AE-RPC per RTT carrying many entries, leaving CPU headroom for the
optimizations the camera-ready is measuring. The flag affects raft /
rule_raft / curp paths only — CoPilot, Mencius, MongoDB, etcd,
ZooKeeper, swiftpaxos, and epaxos are unchanged. So a single
`build/deptran_server` binary, built with `--disable-raft-pipeline`,
correctly drives every protocol in the matrix.

> No source edits on hosts: every code change goes
> zoo → `git commit` → `git push` (fans out to `stonysystems/janus`,
> `stonysystems/jetpack`, and `MintGreenTZ/JetPack`, all on the
> `jetpack` branch) → server0 `git pull`.

### 2.1 MongoDB consistency: **linearizable**

The MongoDB family is run with the strongest single-key consistency
the driver supports — *linearizable* — so that JetPack's commit
semantics on the `mongodb` path are directly comparable to the
(linearizable-by-construction) raft / etcd / zookeeper paths. The
deptran mongodb wrapper attaches the following to every operation:

| field | value | meaning |
|---|---|---|
| `writeConcern.w` | `"majority"` | wait until a majority of replicas ack |
| `writeConcern.j` | `true` | wait for journal flush before ack (durable on disk) |
| `readConcern` | `"linearizable"` | reads see the most recent durable write |
| `readPreference` | `"primary"` | reads always go to the current primary |

**Implementation**: attached as URI options on the mongo-cxx-driver
client, applied as defaults to every read/write (no per-op patching).
See
[`src/deptran/mongodb_kv_table_handler.h`](../../src/deptran/mongodb_kv_table_handler.h)
(`JANUS_MONGO_LINEARIZABLE_OPTS` + the three `kMongoDbUri` constants) and
[`src/deptran/mongodb/server.h`](../../src/deptran/mongodb/server.h)
(the dynamic URI builder in the `JETPACK_MONGODB_RECOVERY` block
appends the same macro). Verify in run logs by grepping for
`mongo_uri_:.*readConcernLevel=linearizable`.

### 2.2 Backend lifecycle (mongodb / etcd / zookeeper)

Three of the nine protocols use an out-of-process backend service
(mongod, etcd-server, zkServer) on each replica host. The other six
(raft, copilot, mencius, curp, swiftpaxos, epaxos) live entirely
inside `deptran_server` — no service start/stop needed.

#### Deployment topology (applies to each of the three backend services)

Each of `mongodb`, `etcd`, and `zookeeper` runs as a 5-node cluster
with the same topology contract — only the binary and ports change.

| dimension | value | how it's enforced |
|---|---|---|
| **Cluster size** | **5 nodes** per backend (one per AWS region: California / Oregon / Mumbai / Frankfurt / Stockholm) — `n_replica = 5`, deployed on `server0..server4`. | hard-coded `N_REPLICA=5` in each `start_*` script; iterates `servers[i]` from [setup.json](../setup.json) |
| **CPU pinning** | Backend service pinned to **core 1** on each host — same core as the deptran server thread. Total protocol-stack CPU shows up on a single core so families are directly comparable. Overridable via `BACKEND_CORE=…`. | etcd: `taskset -c 1` prefix on launch. zookeeper: `taskset -p -c 1` on the `QuorumPeerMain` pid post-start. mongodb: persistent systemd drop-in `/etc/systemd/system/mongod.service.d/cpuaffinity.conf` (`[Service] CPUAffinity=1`) installed during host bootstrap; the start script verifies `Cpus_allowed_list` matches and warns otherwise. |
| **Leader pinning** | `server0` (California / aws00) is always the cluster leader / PRIMARY. Reproducible commit-RTT and consistent leader-CPU readings (JetPack's adaptive throttle keys off leader CPU) require a fixed leader. | etcd: `etcdctl move-leader` to server0's member-id post-liveness. mongodb: replica-set member 0 has `priority=2.0` set during `rs.initiate` at host bootstrap, and the start script attempts `rs.stepDown(60)` on the current PRIMARY (up to 3 attempts) until server0 wins re-election. zookeeper: `myid` configured so `server0` holds the **highest** sid (e.g. `myid=5`); FastLeaderElection picks the highest-sid node on fresh start. The start script verifies via `srvr` four-letter and warns if server0 is not the leader (no auto-correction — ZK has no built-in leader-move). |

Items marked "during host bootstrap" are install-time setup the start
scripts assume rather than perform — they belong in
[`scripts/aws_setup_script.sh`](../aws_setup_script.sh) +
[`scripts/02-setup.sh`](../02-setup.sh) so a fresh c5.2xlarge gets the
right systemd drop-in / replica-set priorities / `myid` ordering with
no on-host edits.

**Default policy: per-protocol-family lifecycle** — start the backend
cluster once before the family's first run, stop after the family's
last run. State accumulation across runs in the same family is
acceptable because the camera-ready workloads (`rw_1000000`, the
zipf set, the key-range set) all spread requests across many keys
without persistent hot-key state.

Trade-off vs per-test (start/stop around every individual run):
- **Per-family** *(default)*: ~40 min faster on the full ~860-run
  matrix. Simpler failure modes (one bad run does not poison the rest
  of the family in a hard-to-diagnose way for our workloads).
- **Per-test**: hermetic isolation; useful while triaging a single
  broken family.

The start/stop scripts live in [`scripts/`](../) and read
`setup.json` for AWS server IPs:

| backend | start | stop |
|---|---|---|
| mongodb   | [`start_mongodb_cluster.sh`](../start_mongodb_cluster.sh) | [`stop_mongodb_cluster.sh`](../stop_mongodb_cluster.sh) |
| etcd      | [`start_etcd_cluster_aws.sh`](../start_etcd_cluster_aws.sh) | [`stop_etcd_cluster_aws.sh`](../stop_etcd_cluster_aws.sh) |
| zookeeper | [`start_zookeeper_cluster.sh`](../start_zookeeper_cluster.sh) | [`stop_zookeeper_cluster.sh`](../stop_zookeeper_cluster.sh) |

Each `start_*` script:
1. SSHes to all 5 server hosts in parallel.
2. Kills any prior backend instance + cleans state dir.
3. Starts the backend with the camera-ready 5-replica config.
4. **Polls until every node is healthy** with the backend's native
   liveness probe (mongo `db.runCommand({ping:1}).ok==1` /
   etcdctl `endpoint health` / zookeeper `ruok→imok`).
5. Sleeps 5 s after readiness returns to let cross-replica state
   converge.
6. Returns 0 only when all 5 nodes are healthy within
   `READY_TIMEOUT` (default 60 s); otherwise returns 1.

> **Backend binaries are jetpack-patched.** The mongod, etcd, and
> zkServer binaries on AWS hosts are *not* the upstream packages —
> they're built from the patched sources tracked under
> [`third_party/`](../../third_party). The host-bootstrap step
> ([`scripts/aws_setup_script.sh`](../aws_setup_script.sh) +
> [`scripts/02-setup.sh`](../02-setup.sh)) is responsible for getting
> these patched binaries onto each host. If a fresh-cluster run fails
> with `mongod: command not found`, `etcd: command not found`, or
> `zkServer.sh: command not found`, the fix belongs in those setup
> scripts (per the §"Reproducibility rules" contract), not in
> `10-run_all.sh`.

`10-run_all.sh` does **not** currently call these scripts. The
[`camera-ready/run.sh`](#todo) wrapper (TODO) is responsible for
chaining `start_<backend>_cluster*.sh` → `10-run_all.sh ... <family>`
→ `stop_<backend>_cluster*.sh`. See
[`results/2026-04-30-camera-ready-exp0-small/run.sh`](../../results/2026-04-30-camera-ready-exp0-small/run.sh)
for a working example of the per-family lifecycle plumbing.

## 3. Experiment matrix

`10-run_all.sh` runs three orthogonal experiments selectable via
`--exp 0,1,2`. The matrix is built in
[`10-run_all.sh:327-440`](../10-run_all.sh#L327-L440).

### 3.1 Common knobs

| knob | value | source |
|---|---|---|
| Run duration | **30 s** wall-clock per host per run | `-d 30` in `build_deptran_cmd`, [`experiment_defs.sh:271`](../experiment_defs.sh#L271) |
| SSH timeout | **180 s** per run per host | `TIMEOUT_SEC` in [`10-run_all.sh:194`](../10-run_all.sh#L194) |
| Mid-window stats | **middle 10 s** of the 30 s run | `Mid throughput is …` line emitted by `deptran_server` |
| Max `.res` size | **200 MB** before falling back to tail-grep | `MAX_RES_SIZE_BYTES` in [`10-run_all.sh:88`](../10-run_all.sh#L88) |
| YCSB workload | **`YCSB_A`** for every camera-ready run | `experiment_defs.sh` + [`10-run_all.sh:333`](../10-run_all.sh#L333) |
| Site config | **`60c1s5r10p`** | `SITE_AWS_SWEEP` in [`experiment_defs.sh:170`](../experiment_defs.sh#L170) |

### 3.2 Fast-path modes (`-m` flag)

| `-m` | name | behaviour |
|---|---|---|
| `0` | `MODE_ORIGINAL` | No JetPack fast-path. Used for **all** original-protocol runs *and* as the JetPack-disabled baseline. |
| `100` | `MODE_FASTPATH100` | Force 100% fast-path attempts (no throttle). |
| `101` | `MODE_ADAPTIVE` | Adaptive fast-path throttle (engages/disengages based on FP_LO/FP_HI CPU thresholds). |

Originals get only `mode=0`; JetPack siblings get all three
(`ALL_FASTPATH_MODES` in [`experiment_defs.sh:66`](../experiment_defs.sh#L66)).

### 3.3 Protocols (AWS, camera-ready)

The camera-ready matrix has **two groups** of protocols, with different
run-shapes:

#### Group A — JetPack-augmented families (6)

`origin` = vanilla protocol, run with `mode=0`; `jetpack` =
JetPack-augmented sibling, run with all three fastpath modes
(`mode ∈ {0, 100, 101}`). 4 variants per concurrency point.

| i | origin | jetpack *(camera-ready)* | concurrency array | sweep length |
|---|---|---|---|---|
| 0 | `none_raft` | **`rule_raft`** ¹ | `RAFT_CONCS` | 24 |
| 1 | `none_copilot` | `rule_copilot` | `COPILOT_CONCS` | 22 |
| 2 | `none_mencius` | `rule_mencius` | `MENCIUS_CONCS` | 15 |
| 3 | `none_mongodb` | `rule_mongodb` | `MONGODB_CONCS` | 14 |
| 4 | `none_etcd` | `rule_etcd` | `ETCD_CONCS` | 22 |
| 5 | `none_zookeeper` | `rule_zookeeper` | `ZOOKEEPER_CONCS` | 22 |

¹ Override of [`experiment_defs.sh:36`](../experiment_defs.sh#L36),
which currently lists `rule_fpga_raft` for the AWS path. Camera-ready
**must** use `rule_raft`. Same applies to `rule_etcd` /
`rule_zookeeper`: today these only appear in
[`ZOO_JETPACK_PROTOCOLS`](../experiment_defs.sh#L50) — the camera-ready
override extends `LEGACY_JETPACK_PROTOCOLS` to include them on AWS.

#### Group B — standalone baselines (3)

These are reference protocols that **have no JetPack sibling**: a
single config + single `-m` flag, 1 variant per concurrency point.

| j | label | config | `-m` | concurrency array | sweep length |
|---|---|---|---|---|---|
| 0 | `curp` | `none_curp.yml` | `200` (`MODE_CURP`) | `CURP_CONCS` *(new)* | 11 |
| 1 | `swiftpaxos` | `none_swiftpaxos.yml` | `0` | `SWIFTPAXOS_CONCS` *(new)* | 11 |
| 2 | `epaxos` | `none_epaxos_corrected.yml` ² | `0` | `EPAXOS_CONCS` *(new)* | 11 |

² `none_epaxos_corrected.yml` is the canonical EPaxos config (the
correctness-fixed variant). The legacy `none_naive_epaxos.yml` is
**not** part of the camera-ready set.

Result-prefix convention for these (see §4): the *protocol* slug in
the prefix is the config-stem **minus** the `none_` prefix —
`curp`, `swiftpaxos`, `epaxos_corrected` — matching what
[`scripts/build_per_protocol_tables.py`](../build_per_protocol_tables.py)
already parses.

> **Plumbing TODO** to make the driver support this matrix on AWS:
> - Extend `LEGACY_*_PROTOCOLS` to length 6 with `rule_raft`,
>   `rule_etcd`, `rule_zookeeper` added (and `rule_fpga_raft` removed).
> - Add `LEGACY_FIXED_CONCS` entries for etcd / zookeeper.
> - Add the three new concurrency arrays
>   (`CURP_CONCS`, `SWIFTPAXOS_CONCS`, `EPAXOS_CONCS`) and a parallel
>   `LEGACY_BASELINE_PROTOCOLS` / `LEGACY_BASELINE_MODES` /
>   `LEGACY_BASELINE_CONCS` triple.
> - Teach `10-run_all.sh:327-440` to iterate Group B with a single
>   variant per conc point (no fastpath fan-out, no jetpack sibling).

### 3.4 Concurrency arrays (every value)

Each entry is a config file `config/concurrent_<N>.yml`.

#### Group A (existing arrays in `experiment_defs.sh`)

From [`experiment_defs.sh:97-145`](../experiment_defs.sh#L97-L145).

**`RAFT_CONCS`** — 24 levels:
```
1, 10, 20, 40, 60, 80, 100, 120, 140, 150, 160, 170,
180, 190, 200, 250, 300, 400, 500, 750, 1000, 1250, 1500, 2000
```

**`COPILOT_CONCS`** — 22 levels (densely sampled around the knee at ~80):
```
1, 10, 20, 30, 40, 50, 60, 70, 72, 75, 77, 80,
82, 85, 87, 90, 100, 120, 140, 160, 180, 200
```

**`MENCIUS_CONCS`** — 15 levels (Mencius saturates much earlier):
```
1, 10, 12, 14, 16, 18, 20, 25, 30, 35, 40, 45, 50, 55, 60
```

**`MONGODB_CONCS`** — 14 levels:
```
1, 10, 20, 30, 35, 40, 50, 60, 70, 80, 90, 100, 110, 120
```

**`ETCD_CONCS`** — 22 levels (currently used on Zoo;
camera-ready promotes to AWS):
```
1, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110,
120, 140, 160, 180, 200, 250, 300, 350, 400, 500
```

**`ZOOKEEPER_CONCS`** — 22 levels (same shape as ETCD_CONCS):
```
1, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110,
120, 140, 160, 180, 200, 250, 300, 350, 400, 500
```

#### Group B (proposed new arrays — must be added to `experiment_defs.sh`)

Tuned to each protocol's known saturation regime, derived from
[`scripts/run_curp_data_sweep.sh`](../run_curp_data_sweep.sh) and
[`scripts/run_max_throughput_regression.sh`](../run_max_throughput_regression.sh).
Densified to 11 levels each so curves are publication-quality.

**`CURP_CONCS`** — 11 levels (CURP is raft-derived, similar saturation):
```
1, 10, 25, 50, 75, 100, 150, 200, 300, 500, 750
```

**`SWIFTPAXOS_CONCS`** — 11 levels (saturates around N=50–100):
```
1, 10, 25, 50, 75, 100, 125, 150, 175, 200, 250
```

**`EPAXOS_CONCS`** — 11 levels (saturates higher than the others):
```
1, 10, 25, 50, 100, 150, 200, 250, 300, 400, 500
```

> Each `concurrent_<N>.yml` referenced above must already exist under
> `config/`. Smoke-check:
> `for n in 25 75 125 175 250 350 500 750; do ls config/concurrent_${n}.yml; done`.
> Generate any missing files by copying an existing `concurrent_*.yml`
> and editing the `n_concurrent` field — the only knob in the file.

### 3.5 Workload sets

| set | values | config files |
|---|---|---|
| **uniform key range** *(used by exp 0)* | `rw_1000000` (1 M-key, uniform, 50/50 R/W) | `config/rw_1000000.yml` |
| **zipf sweep** *(exp 1)* | 6 values: `rw_zipf_1`, `rw_zipf_0.9`, `rw_zipf_0.8`, `rw_zipf_0.7`, `rw_zipf_0.6`, `rw_zipf_0.5` | `config/rw_zipf_<v>.yml` |
| **key-range sweep** *(exp 2)* | 7 values: `rw_1`, `rw_10`, `rw_100`, `rw_1000`, `rw_10000`, `rw_100000`, `rw_1000000` | `config/rw_<N>.yml` |
| **YCSB** | `YCSB_A` (single value across the camera-ready) | `config/YCSB_A.yml` |

Defined in [`10-run_all.sh:119-125`](../10-run_all.sh#L119-L125).

### 3.6 Fixed concurrencies *(used by exp 1 & 2)*

Group A's existing 4 entries from
[`experiment_defs.sh:148`](../experiment_defs.sh#L148)
(`LEGACY_FIXED_CONCS`), plus 5 new entries the camera-ready needs to
add (etcd / zookeeper into Group A, plus all 3 of Group B):

| group | protocol family | fixed concurrency | rationale |
|---|---|---|---|
| A | raft       | `concurrent_150` | RAFT throughput knee on AWS |
| A | copilot    | `concurrent_50`  | CoPilot saturates early |
| A | mencius    | `concurrent_16`  | Mencius's narrow stable region |
| A | mongodb    | `concurrent_40`  | MongoDB consensus throughput knee |
| A | etcd       | `concurrent_100` *(new)* | etcd knee around N=100 |
| A | zookeeper  | `concurrent_100` *(new)* | zookeeper knee around N=100 |
| B | curp       | `concurrent_100` *(new)* | CURP knee tracks raft's at our offered load |
| B | swiftpaxos | `concurrent_75`  *(new)* | swiftpaxos saturates around N=75 |
| B | epaxos     | `concurrent_100` *(new)* | epaxos's stable mid-range |

Camera-ready can either accept these defaults or regenerate from
exp-0 results via [`scripts/derive_fixed_conc.py`](../derive_fixed_conc.py).
The AWS path currently reads its fixed-conc values from the hard-coded
`LEGACY_FIXED_CONCS` array
([`10-run_all.sh:116`](../10-run_all.sh#L116)) — it does **not** consume
`fixed_conc.json`. To switch, edit `experiment_defs.sh:148` directly.

### 3.7 Exp 0 — concurrency sweep

**Group A** (per family `i`):
- `(origin, conc, fp=0, YCSB_A)` for every `conc` in `concurrents[i]`
- `(jetpack, conc, fp ∈ {0, 100, 101}, YCSB_A)` for every `conc`
  → 4 variants per conc point.

**Group B** (per baseline `j`): 1 run per `(config, mode_j, conc)` for
every `conc` in `baseline_concs[j]`.

Workload: `rw_1000000`. Goal: peak-throughput curve per protocol →
data for exp 0's headline figure and refreshing the fixed-conc table.

**Per-protocol run count**:

| group | protocol | conc levels | variants | runs |
|---|---|---:|---:|---:|
| A | raft       | 24 | 4 | **96** |
| A | copilot    | 22 | 4 | **88** |
| A | mencius    | 15 | 4 | **60** |
| A | mongodb    | 14 | 4 | **56** |
| A | etcd       | 22 | 4 | **88** |
| A | zookeeper  | 22 | 4 | **88** |
| B | curp       | 11 | 1 | **11** |
| B | swiftpaxos | 11 | 1 | **11** |
| B | epaxos     | 11 | 1 | **11** |
| **total** |  |  |  | **509** |

### 3.8 Exp 1 — zipf sweep (skew sensitivity)

At the per-protocol fixed concurrency from §3.6, for each of the 6 zipf
workloads:
- **Group A**: 1 origin run (fp=0) + 3 jetpack runs (fp ∈ {0, 100, 101})
  = 4 runs per workload per family.
- **Group B**: 1 run per workload per baseline.

| group | protocols | workloads | variants | runs |
|---|---:|---:|---:|---:|
| A | 6 | 6 | 4 | **144** |
| B | 3 | 6 | 1 | **18**  |
| **total** | | | | **162** |

Goal: how does fast-path engagement degrade as the workload becomes
more skewed (more conflicts on hot keys)?

### 3.9 Exp 2 — key-range sweep (contention sensitivity)

Same shape as exp 1, with the 7 key-range workloads at fixed
concurrency.

| group | protocols | workloads | variants | runs |
|---|---:|---:|---:|---:|
| A | 6 | 7 | 4 | **168** |
| B | 3 | 7 | 1 | **21**  |
| **total** | | | | **189** |

Goal: contention sensitivity at fixed offered load — at `rw_1` every
request hits the same key (worst case); at `rw_1000000` collisions are
rare (matches the `rw_1000000` data point in exp 0).

### 3.10 Run-count budget (camera-ready, AWS only)

| exp | runs | per-run wall-clock ¹ | exp wall-clock |
|---|---:|---:|---:|
| 0 (concurrency) | **509** | ~109 s | ~15 h 25 m |
| 1 (zipf)        | **162** | ~109 s | ~4 h 54 m  |
| 2 (key-range)   | **189** | ~109 s | ~5 h 43 m  |
| **total**       | **860** |         | **~26 h**  |

¹ "109 s/run" is the historical AWS average — Raft / Copilot / Mencius
/ etcd / zookeeper / curp / swiftpaxos / epaxos sweeps land around
85 s, MongoDB closer to 180 s. The driver SSHes all 5 hosts in
parallel per run; this is wall-clock per matrix entry, not 5×.

Failed runs are auto-retried once at the end of each loop pass — see
[`10-run_all.sh:484-495`](../10-run_all.sh#L484-L495). Budget an extra
~5–10 % for retry overhead, so plan for **~28–29 h** of AWS uptime
end-to-end (≈ a 1.2-day continuous run).

## 4. Output filenames & format

Every run dumps artefacts under
`results/<timestamp>-<commit>/` — created in
[`10-run_all.sh:170-178`](../10-run_all.sh#L170-L178).

Per-run prefix
([`experiment_defs.sh:279-288`](../experiment_defs.sh#L279-L288)):

```
<protocol>-<site>-<workload>-<conc>-<mode>-<ycsb>
```

Examples:
- `none_raft-60c1s5r10p-rw_1000000-concurrent_100-0-YCSB_A`
- `rule_raft-60c1s5r10p-rw_zipf_0.8-concurrent_150-101-YCSB_A`
- `rule_copilot-60c1s5r10p-rw_1000-concurrent_50-100-YCSB_A`
- `none_curp-60c1s5r10p-rw_1000000-concurrent_100-200-YCSB_A`
- `none_swiftpaxos-60c1s5r10p-rw_zipf_0.6-concurrent_75-0-YCSB_A`
- `none_epaxos_corrected-60c1s5r10p-rw_10000-concurrent_100-0-YCSB_A`

Per host (5 hosts: `server0..server4`) the run produces:

| file | source | content |
|---|---|---|
| `<prefix>-server<i>.res` | host stdout | `Mid throughput is …`, `All-efficient-attempts statistics …` (min / p50 / p75 / p90 / p95 / p99 / p99.9 / max / avg / stddev), `Dumped to …`, `Deleted one.` |
| `<prefix>-server<i>.csv` | scp from `server0:results/recent_csv/` | per-request latency rows in middle-10 s window (≥ `End2End-Latency` column) |
| `tdigest_<prefix>-server<i>.csv` | scp from `server0:results/recent_csv/` | t-digest serialisation for cross-host percentile merging |

So **15 files per run** = 5 hosts × 3 file types. Camera-ready total:
860 × 15 = **12 900 artefact files**, plus one `metadata.json` at the
top of the result dir recording git commit + start time + environment.

## 5. Pass / fail criteria

Encoded in `execute_command`
([`10-run_all.sh:252-323`](../10-run_all.sh#L252-L323)). A run is
**successful only if every host satisfies all of**:

1. `<prefix>-server<i>.res` exists and is non-empty.
2. The file (or its last 100 KB if > 200 MB) contains both:
   - `Mid throughput is …`
   - `Dumped to …`
3. The file does **not** contain `generic server error`.
4. **For `rw_1000000` workload only** (exp 0): mid throughput ≥ 1.
   *(Zipf and key-range workloads accept 0-throughput as legitimate
   data points under extreme contention — exp 1 / 2 do not gate on
   throughput.)*
5. The corresponding `<prefix>-server<i>.csv` is present **locally**
   after the scp from server0 (NFS attribute-cache races have caused
   "the .res says Dumped to but no CSV" before — see
   [`scripts/scp_race_audit.py`](../scp_race_audit.py)).

If any host fails, the entire run is marked `fail (<reason>)` and
re-queued for one retry pass at the end. Reasons reported:
`missing file`, `missing success markers`, `low throughput (<N>)`,
`csv_missing_after_scp`, `unknown`.

## 6. Inter-experiment dependency: `fixed_conc`

Exp 1 and exp 2 share a single concurrency value per protocol — the
throughput knee from exp 0. On the **AWS** path the driver reads from
the hard-coded `LEGACY_FIXED_CONCS` array
([`experiment_defs.sh:148`](../experiment_defs.sh#L148)). The values
in §3.6 are the current defaults.

If exp 0 reveals a different knee for a protocol, edit
`LEGACY_FIXED_CONCS` to match before running exp 1 / 2 — or use
[`scripts/derive_fixed_conc.py`](../derive_fixed_conc.py) to compute
new values from the exp-0 result tree (it currently writes
`scripts/results/fixed_conc.json`, which is consumed by the Zoo path
only — the AWS path needs a manual edit of the array).

> **TODO (camera-ready run.sh)**: thread `derive_fixed_conc.py`'s
> output back into the AWS path automatically so exp 1 / 2 always use
> the freshly-computed knee.

## 7. Expected results — what the camera-ready figures need

Each figure in the paper is computed from the result tree above; the
generation pipeline is the existing scripts in `scripts/`:

| figure / table | inputs | generator |
|---|---|---|
| Per-protocol throughput vs concurrency (exp 0) | exp 0 `.res` + `.csv` | [`scripts/build_per_protocol_tables.py`](../build_per_protocol_tables.py) |
| Latency CDF / merged percentiles | per-host `.csv` (any exp) | [`scripts/merge_latency_csv.py`](../merge_latency_csv.py) |
| Zipf-sensitivity curves (exp 1) | exp 1 `.res` | [`scripts/generate_summary.py`](../generate_summary.py) → `summary.md` |
| Key-range curves (exp 2) | exp 2 `.res` | same as above |
| CPU utilisation (5-host median, mid-10 s only) | per-host `cpustat` logs | [`scripts/parse_cpustat.py`](../parse_cpustat.py) + [`generate_cpu_figure.py`](../generate_cpu_figure.py) |
| Consolidated CSV for headline tables | all `.res` | [`scripts/build_consolidated_csv.sh`](../build_consolidated_csv.sh) |

> **CPU reporting rule** *(per project memory)*: median across the
> middle 10 s of the run, **then** averaged across the 5 hosts. Never
> report the max-across-hosts as the headline number.

### Expected directional outcomes

These are the gates that tell us a reproduction matches the paper.
**Direction**, not exact numbers — exact values depend on hardware and
WAN snapshots:

- **Exp 0, raft**: `rule_raft` with `mode=101` should beat `none_raft`
  on peak throughput by ≥ 1.5× at the throughput knee
  (`concurrent_150`), with p50 ≤ vanilla p50 in the same regime.
- **Exp 0, all 6 Group-A protocols**: `mode=101` (adaptive) should
  never be worse than `mode=0` on the JetPack binary — the throttle
  should disengage cleanly when fast-path is unprofitable.
- **Exp 0, mode=100 vs mode=101**: at high contention `mode=100` may
  underperform `mode=0`; `mode=101` should match the better of the two
  at every conc.
- **Exp 0, Group-B baselines**:
  - `epaxos`: peak throughput should land between Raft and CoPilot at
    the comparable concurrency point — its leaderless design wins on
    uncontended workloads but pays the dependency-tracking cost.
  - `swiftpaxos`: should achieve lower p50 than vanilla Raft at low
    concurrency (≤ 50) thanks to the fast quorum path; throughput
    saturates earlier.
  - `curp`: at `rw_1000000` should approach `rule_raft` mode=100
    behaviour (similar fast-path geometry), but without Jetpack's
    adaptive throttle it degrades earlier under skew (see exp 1).
- **Exp 1 (zipf)**:
  - JetPack fast-path attempt rate decreases monotonically as the
    zipf coefficient rises. At `rw_zipf_1`, `mode=101` ≈ `mode=0`.
  - `curp` throughput collapses at `rw_zipf_1` (1-key contention) far
    faster than `rule_raft` mode=101 — the camera-ready story.
  - `epaxos` p99 inflates sharply once zipf > 0.8 (dependency-graph
    blowup); `rule_*` mode=101 stays bounded.
- **Exp 2 (key-range)**: at `rw_1` (1-key contention) all protocols
  collapse to similar low throughput; at `rw_1000000` the spread is
  widest and matches exp 0's `concurrent_<fixed>` data point exactly.
- **All experiments**: every successful run reports `Deleted one.` —
  no leaked `deptran_server` processes, no `generic server error`,
  CSV present.

## 8. Reproducibility rules (the contract)

1. **Run only through `10-run_all.sh`** (or the forthcoming
   `camera-ready/run.sh` wrapper). If a run fails, fix the script /
   code and re-run — do **not** SSH into hosts and patch by hand.
2. **All code changes go through git** — zoo (write/commit/push) →
   server0 (`git pull`). Macros toggle via build flags, not source
   edits.
3. **Do not edit `setup.json` mid-experiment** — the driver hashes the
   commit + timestamp into the result-dir name, so changing host
   inventory mid-run produces silently inconsistent data.
4. **Run order matters**: exp 0 → (refresh `LEGACY_FIXED_CONCS` if
   needed) → exp 1 / 2. Skipping exp 0 is fine if you trust the
   defaults in §3.6, but the camera-ready figure pipeline expects the
   exp-0 curve to be present.
5. **Always pair an AWS reboot with `04-nfs.sh`** (NFS unmounts on
   stop). Sequence: `aws_start_instances.sh` → `04-nfs.sh` →
   `06-set_jetpack_env.sh` → `08`/`09`/`10`. Skipping `04-nfs.sh`
   means server0 has no `/home/ubuntu/code` mount and every run fails
   with "missing file" or "binary not found".
6. **Camera-ready uses `rule_raft`, never `rule_fpga_raft`** — see the
   override note at the top of this file.

---

## TODO

- [ ] **`experiment_defs.sh` extensions** required before the matrix
  in §3 will run end-to-end:
  - Flip `LEGACY_JETPACK_PROTOCOLS[0]`: `rule_fpga_raft` → `rule_raft`.
  - Extend `LEGACY_*_PROTOCOLS` to length 6 by appending
    `none_etcd / rule_etcd` and `none_zookeeper / rule_zookeeper`.
  - Extend `LEGACY_FIXED_CONCS` with `concurrent_100, concurrent_100`
    for etcd / zookeeper. *(Order: raft, copilot, mencius, mongodb,
    etcd, zookeeper.)*
  - Add `CURP_CONCS`, `SWIFTPAXOS_CONCS`, `EPAXOS_CONCS` arrays
    (values in §3.4).
  - Add a parallel "baselines" tuple:
    ```bash
    LEGACY_BASELINE_LABELS=("curp" "swiftpaxos" "epaxos")
    LEGACY_BASELINE_CONFIGS=("none_curp" "none_swiftpaxos" "none_epaxos_corrected")
    LEGACY_BASELINE_MODES=("200" "0" "0")
    LEGACY_BASELINE_CONCS_ARRAYS=("CURP_CONCS" "SWIFTPAXOS_CONCS" "EPAXOS_CONCS")
    LEGACY_BASELINE_FIXED_CONCS=("concurrent_100" "concurrent_75" "concurrent_100")
    ```
- [ ] **`10-run_all.sh:327-440` extensions**: after the existing Group-A
  loops in exp 0/1/2, add a parallel Group-B loop that emits 1 variant
  per conc point (no fastpath fan-out, no jetpack sibling).
- [ ] **`config/concurrent_<N>.yml` smoke check**: confirm every value
  listed in §3.4 has a matching config file; generate any missing ones.
- [ ] `camera-ready/run.sh` — one-click driver that:
  - Confirms environment, asks before destructive AWS start/stop.
  - Wraps `./10-run_all.sh full --exp 0`, runs `derive_fixed_conc.py`,
    refreshes `LEGACY_FIXED_CONCS`, then `./10-run_all.sh --exp 1,2`.
  - Calls `build_consolidated_csv.sh` + `generate_summary.py` +
    `build_per_protocol_tables.py` to materialise paper figures into
    `camera-ready/figures/` and `camera-ready/summary.md`.
  - Verifies the §5 pass criteria for each phase before moving on.
- [ ] `camera-ready/expected/` — checked-in golden outputs (small text
  artefacts only) so future re-runs can diff and flag drift.
