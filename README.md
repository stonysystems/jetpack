# Jetpack

Jetpack is a plugin consensus protocol that sits on top of a base protocol (e.g. Raft, CoPilot, Mencius). It provides failure recovery via a 3-phase Paxos protocol that is independent of the base consensus layer.

The system compiles into a **single binary** (`build/deptran_server`) that supports all protocols: Raft, CoPilot, Mencius, MongoDB, etcd, and ZooKeeper. The protocol is selected at runtime via config files.

## 1. Build

### 1.1 Prerequisites

- C++14 compiler (g++ or clang++) — only needed for native builds without Docker
- Python 3 (< 3.12) — only needed for native builds (WAF build system)
- Docker Engine >= 17.05 (for multi-stage builds)
- Docker Compose V2 >= 2.0 (`docker compose`, not legacy `docker-compose`). V2 is required because compose files use the modern format (no `version:` field) with `depends_on: condition: service_healthy`.
- Git submodules initialized: `git submodule update --init --recursive`

Verify:

```bash
docker --version          # Docker Engine 17.05+
docker compose version    # Docker Compose V2.0+
```

Some Docker operations require extra flags:
- `--network=host` during `docker build` (so the builder can fetch third-party dependencies)
- `--privileged` at runtime for multi-process tests (tc/netem latency simulation) and TLA+ model checking (cgroup access)

### 1.2 Build the binary

The canonical build uses `docker/zoo-build/Dockerfile`. This builds inside a controlled Ubuntu 22.04 environment with all dependencies (mongocxx, etcd-cpp-api, libzookeeper, boost, etc.), producing a single binary compatible with all target machines.

```bash
# Build
docker build -f docker/zoo-build/Dockerfile -t jetpack-zoo-build .

# Extract binary + shared libraries
docker create --name tmp jetpack-zoo-build
docker cp tmp:/output/deptran_server build/deptran_server
docker cp tmp:/output/lib build/docker_libs/
docker rm tmp

# Remove system libs that conflict with host (keep only third-party libs)
rm -f build/docker_libs/{libc.so.6,libm.so.6,libresolv.so.2,libgcc_s.so.1,libstdc++.so.6,ld-linux-x86-64.so.2}
```

This produces:
- `build/deptran_server` — single binary, all protocols compiled in
- `build/docker_libs/` — third-party shared libraries (mongocxx, etcd-cpp-api, etc.)

### 1.3 Deploy to servers

Copy `build/deptran_server` and `build/docker_libs/` to target machines. If the machines share an NFS home directory (like the Zoo cluster), the build is already visible on all nodes.

Run on any server with:

```bash
export LD_LIBRARY_PATH=/path/to/build/docker_libs:$LD_LIBRARY_PATH
build/deptran_server -f config/none_raft.yml ...    # Raft
build/deptran_server -f config/none_etcd.yml ...    # etcd
build/deptran_server -f config/none_mongodb.yml ...  # MongoDB
build/deptran_server -f config/rule_raft.yml ...     # Jetpack + Raft
```

### 1.4 Native build (alternative)

If all dependencies are installed on the host (boost, yaml-cpp, mongocxx, etcd-cpp-api, libzookeeper, gperftools, etc.), you can build natively without Docker:

```bash
# Generate RPC stubs (only needed after modifying .rpc files)
bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc

# Build
python3 waf configure build -J

# Build for Raft unit testing
python3 waf configure build -J --enable-raft-test
```

This produces `build/deptran_server` directly, no `docker_libs` needed.

### 1.5 Build notes

- Internally, all build paths use `python3 waf configure build` (the WAF build system). Docker wraps this to provide a reproducible dependency environment.
- The binary links all protocol modules unconditionally — you need all backend libraries to compile, even if you only run Raft.
- `SIMULATE_WAN` must **not** be defined when using tc/netem for network simulation (Docker tests). It is off by default. Only enable it via `python3 waf configure build -W` for software-based WAN delay.

## 2. Run Locally

### 2.1 Single-process experiments

Run all replicas + clients in one process on localhost:

```bash
export LD_LIBRARY_PATH=build/docker_libs:$LD_LIBRARY_PATH

# Raft, 3 replicas, 1 client (closed loop)
build/deptran_server -f config/none_raft.yml -f config/1c1s3r1p.yml \
  -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml \
  -d 30 -m 100 -P localhost

# Raft, 3 replicas, 12 clients
build/deptran_server -f config/none_raft.yml -f config/12c1s3r1p.yml \
  -f config/rw.yml -f config/client_closed.yml -f config/concurrent_12.yml \
  -d 30 -m 100 -P localhost

# Raft + Jetpack failure recovery
build/deptran_server -f config/rule_raft.yml -f config/1c1s3r1p.yml \
  -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml \
  -f config/failover.yml -d 30 -m 100 -P localhost

# Raft lab tests
build/deptran_server -f config/raft_lab_test.yml
```

### 2.2 Docker concurrency sweep

```bash
# Sweep all concurrency levels for one backend/mode
./scripts/sweep_benchmark.sh jetpack-etcd none_etcd.yml
./scripts/sweep_benchmark.sh jetpack-etcd rule_etcd.yml "-m 100"
./scripts/sweep_benchmark.sh jetpack-mongodb rule_mongodb.yml

# Run all 9 backend/mode combinations
./scripts/run_full_sweep.sh

# Automated end-to-end reproduction (build + sanity + sweep + recovery)
./scripts/reproduce_evaluation.sh
./scripts/reproduce_evaluation.sh --dry-run      # preview commands
./scripts/reproduce_evaluation.sh --build-only
./scripts/reproduce_evaluation.sh --sweep-only
./scripts/reproduce_evaluation.sh --recovery-only
```

Sweep output is TSV with columns: `concurrency`, `total_throughput`, `h1`..`h5`, `fp_attempted`, `fp_succeeded`, `fp_rate`, `cpu_leader_avg`, `queue_depth_avg`, `status`, `error_summary`, `log_path`, `retry_count`.

Status values: `OK` (all processes succeeded), `PARTIAL` (some processes failed), `FAILED` (run failed entirely). Failed runs are retried up to 2 times. Logs saved under `docs/sweep_2026-02-28/logs/`.

## 3. Run on Zoo Cluster (.101-.105)

### 3.1 Cluster layout

| Host | IP | NFS | Notes |
|---|---|---|---|
| zoo0 | 130.245.173.101 | shared home | Debian trixie (glibc 2.38) |
| zoo1 | 130.245.173.102 | shared home | Ubuntu 22.04 (glibc 2.35) |
| zoo2 | 130.245.173.103 | shared home | Debian bookworm (glibc 2.36) |
| zoo3 | 130.245.173.104 | shared home | Ubuntu 22.04 (glibc 2.35) |
| zoo4 | 130.245.173.105 | shared home | Debian trixie (glibc 2.38) |

- SSH user: `ztang` (passwordless SSH between all nodes)
- Home directory is NFS-shared: build once, visible on all nodes
- Each host: 2x Xeon Silver 4216 (64 logical CPUs), 64 GB RAM

### 3.2 setup.json

`scripts/setup.json` is the control-plane config consumed by experiment scripts. It stores the cluster IPs, username, and repo path.

Generate or update it:

```bash
cd scripts && ./00-ips.sh
```

Current content (for .101-.105):

```json
{
  "environment": "zoo",
  "server_username": "ztang",
  "n_server": "5",
  "servers": [
    {"server_0_ip": "130.245.173.101"},
    {"server_1_ip": "130.245.173.102"},
    {"server_2_ip": "130.245.173.103"},
    {"server_3_ip": "130.245.173.104"},
    {"server_4_ip": "130.245.173.105"}
  ],
  "zoo_directory": "/home/users/ztang/janus"
}
```

### 3.3 Build and deploy

Since the Zoo machines have NFS-shared home and heterogeneous glibc, build via Docker on any machine with Docker installed:

```bash
# Build (see Section 1.2)
docker build -f docker/zoo-build/Dockerfile -t jetpack-zoo-build .
docker create --name tmp jetpack-zoo-build
docker cp tmp:/output/deptran_server build/deptran_server
docker cp tmp:/output/lib build/docker_libs/
docker rm tmp
rm -f build/docker_libs/{libc.so.6,libm.so.6,libresolv.so.2,libgcc_s.so.1,libstdc++.so.6,ld-linux-x86-64.so.2}
```

The binary is immediately available on all 5 nodes via NFS.

### 3.4 Single experiment (run_single_exp.sh)

Run one experiment point with CPU monitoring:

```bash
cd scripts
./run_single_exp.sh <protocol_cfg> <mode> <concurrent_cfg> <label> <result_dir>

# Examples:
./run_single_exp.sh none_raft.yml 0 concurrent_1.yml raft-c1 ../results/my-exp
./run_single_exp.sh rule_raft.yml 100 concurrent_50.yml jp-raft-fp100-c50 ../results/my-exp
./run_single_exp.sh none_etcd.yml 0 concurrent_100.yml etcd-c100 ../results/my-exp
```

This script:
- Reads `setup.json` for cluster IPs
- Kills leftover processes on all nodes
- Starts `/proc/stat` CPU monitors on all hosts
- Launches `deptran_server` on all 5 nodes in parallel (with `LD_LIBRARY_PATH` and `WAN_DELAY_MS=20`)
- Waits for completion (180s timeout)
- Pulls `.res` and `.csv` result files
- Prints throughput, latency, and per-host CPU usage

### 3.5 Single experiment (09-build_and_test_run_wan.sh)

The original experiment runner. Edit config variables at the top of the script, then run:

```bash
cd scripts

# Run with current config
./09-build_and_test_run_wan.sh

# Custom filename
./09-build_and_test_run_wan.sh --filename my-experiment

# Save to specific directory
./09-build_and_test_run_wan.sh --result-dir ../results/my-exp

# Failure recovery mode (duration=70s, kills a server mid-run)
./09-build_and_test_run_wan.sh --failover --kill-target 2 --kill-delay 20

# Dry run (print commands without executing)
./09-build_and_test_run_wan.sh --dry-run
```

Config variables to edit in the script (Zoo environment):

```bash
CONFIG_FILE_1="none_raft.yml"           # protocol
CONFIG_FILE_2="client_open.yml"         # client mode
CONFIG_FILE_3="30c1s5r5p-zoo.yml"       # topology
CONFIG_FILE_4="rw_1000000.yml"          # workload
CONFIG_FILE_5="concurrent_100.yml"      # concurrency
CONFIG_MODE="0"                         # -m flag (0=original, 100=fp100, 101=adaptive)
CONFIG_DURATION="30"                    # seconds
```

### 3.6 Batch sweep (10-run_all.sh)

Large batch sweeps over protocols/workloads/concurrency:

```bash
cd scripts

# Run all experiments (concurrency sweep + zipf + key-range)
./10-run_all.sh

# Run only specific experiment sets
./10-run_all.sh --exp 0          # concurrency sweep only
./10-run_all.sh --exp 1          # zipf sweep only
./10-run_all.sh --exp 0,1        # both

# Rebuild before running
./10-run_all.sh build

# Preview experiment matrix without running
./10-run_all.sh --dry-run

# Reuse existing result directory
./10-run_all.sh --exp-dir results/2026-04-14-zoo-5machines
```

Experiment types:
- **Exp 0** (concurrency sweep): sweep concurrency levels for each protocol with `rw_1000000` workload
- **Exp 1** (zipf sweep): sweep Zipf skew (0.5-1.0) at fixed concurrency per protocol
- **Exp 2** (key-range sweep): sweep key ranges (1 to 1M) at fixed concurrency per protocol

Results are saved to `results/<timestamp>-zoo-5machines/` with `.res`, `.csv`, and `tdigest_*.csv` files.

### 3.7 CPU pinning

The binary automatically pins threads to CPU cores (`src/deptran/s_main.cc`):
- **Server thread**: core 1 (one per host process)
- **Client threads**: start at core 0, increment by 1, skipping core 1 (server) and core 4 (reserved)

With `30c1s5r5p-zoo.yml` (1 server partition + 6 clients per host):
- Server: core 1
- Clients: cores 0, 2, 3, 5, 6, 7

### 3.8 CPU monitoring

`run_single_exp.sh` automatically polls `/proc/stat` on each host during the experiment. Parse results with:

```bash
python3 scripts/parse_cpustat.py <result_dir> <label> [core_id]

# Example: parse core 1 (server thread) CPU for all hosts
python3 scripts/parse_cpustat.py results/my-exp raft-c100 1
```

Output per host: `core1 avg=X% max=Y%  |  host avg=X% max=Y%`

### 3.9 WAN latency

WAN delay is injected via `WAN_DELAY_MS=20` environment variable (20ms one-way, 40ms RTT). This uses software-based delay queues in the binary (not tc/netem). All Zoo experiment scripts set this automatically.

## 4. Run on AWS (10-node)

### 4.1 AWS layout

```
00 california  (NFS host, server + client)
01 oregon      (server + client)
02 mumbai      (server + client)
03 frankfurt   (server + client)
04 stockholm   (server + client)
05 london      (client-heavy)
06 hongkong    (client-heavy)
07 singapore   (client-heavy)
08 ireland     (client-heavy)
09 paris       (client-heavy)
```

### 4.2 Full bootstrap (fresh machines)

```bash
cd scripts
./00-ips.sh                               # generate setup.json
./01-exchange_keys.sh                     # SSH trust
./02-setup.sh                             # install packages
./04-nfs.sh                               # NFS on server0
./05-clone_repo_and_set_default_folder.sh # clone repo
./06-set_jetpack_env.sh                   # env vars
./07-link_mongocxx.sh                     # MongoDB driver
./09-build_and_test_run_wan.sh build      # build + sanity run
```

### 4.3 Running experiments

Same `09` and `10` scripts as Zoo (Section 3.5-3.6). The scripts auto-detect `environment: aws` from `setup.json` and adjust paths/commands accordingly.

## 5. Config System

### 5.1 Config file categories

All configs are in `config/`. Multiple `-f` flags are composed:

| Category | Pattern | Example | Purpose |
|---|---|---|---|
| Protocol mode | `none_<proto>.yml` / `rule_<proto>.yml` | `rule_raft.yml` | Select protocol and Jetpack on/off |
| Topology | `<C>c<S>s<R>r<P>p.yml` | `30c1s5r5p-zoo.yml` | Clients, sites, replicas, partitions |
| Workload | `rw_*.yml` | `rw_1000000.yml` | Key range, read/write ratio |
| Client mode | `client_open.yml` / `client_closed.yml` | | Open-loop (rate-limited) or closed-loop |
| Concurrency | `concurrent_<N>.yml` | `concurrent_200.yml` | Outstanding requests per client |
| Failover | `failover.yml` | | Enable failure recovery mode |

### 5.2 Protocol modes

| Config | Protocol | Jetpack | `-m` flag |
|---|---|---|---|
| `none_raft.yml` | Raft | Off | `0` |
| `rule_raft.yml` | Raft + Jetpack | On | `100` (fp100) or `101` (adaptive) |
| `none_copilot.yml` | CoPilot | Off | `0` |
| `rule_copilot.yml` | CoPilot + Jetpack | On | `100` or `101` |
| `none_mencius.yml` | Mencius | Off | `0` |
| `rule_mencius.yml` | Mencius + Jetpack | On | `100` or `101` |
| `none_mongodb.yml` | MongoDB | Off | `0` |
| `rule_mongodb.yml` | MongoDB + Jetpack | On | `100` or `101` |
| `none_etcd.yml` | etcd | Off | `0` |
| `rule_etcd.yml` | etcd + Jetpack | On | `100` or `101` |
| `none_zookeeper.yml` | ZooKeeper | Off | `0` |
| `rule_zookeeper.yml` | ZooKeeper + Jetpack | On | `100` or `101` |

The `-m` flag: `0` = original protocol (no fast-path), `100` = force 100% fast-path, `101` = adaptive fast-path throttle. When using `rule_*.yml` without an explicit `-m` flag, the default is adaptive (`-m 101`).

### 5.3 Experiment definitions (experiment_defs.sh)

`scripts/experiment_defs.sh` centralizes protocol families, mode mappings, concurrency arrays, and command-generation helpers. Source it from custom scripts:

```bash
source scripts/experiment_defs.sh
```

Key definitions:
- `ZOO_JETPACK_PROTOCOLS`, `ZOO_ORIGIN_PROTOCOLS` — protocol lists for Zoo cluster
- `RAFT_CONCS`, `COPILOT_CONCS`, `MENCIUS_CONCS`, etc. — per-protocol concurrency arrays
- `build_deptran_cmd()` — generates a full `deptran_server` command from parameters
- `build_result_prefix()` — generates a result filename prefix
- `generate_zoo_matrix()` — generates the full experiment matrix

## 6. Reading Results

### 6.1 Output metrics

Look for these lines in `.res` files (h1 = leader at 127.0.0.1 in Docker; zoo0-zoo4 on cluster):

```
Mid throughput is 1500.20                                    # txn/s (steady-state middle third)
All-efficient-attempts  statistics  count 10  50pct 42.00  90pct 43.50  99pct 52.00  ave 42.36
All-efficient-attempts  distribution  40.30  40.54  41.00  41.50  42.00  42.50  43.00  43.50  44.00  45.00  52.00
Fastpath statistics attempted 5000 successed 4200 rate(pct) 84.00
Cpu-usage-leaders ave 78.5000 count 5
Queue-depth ave 12.3000 count 100
server median : 74.23                                        # server core CPU% (median)
```

Key metrics:
- **Total throughput** = sum of `Mid throughput` across all hosts (cmd/s). In Docker, h1 = leader (127.0.0.1), h2-h5 = followers (127.0.0.2-5).
- **Latency** = `All-efficient-attempts` percentiles (p50, p90, p99) in ms. The `distribution` line shows the full percentile breakdown.
- **Fast-path rate** = `successed / attempted * 100`
- **CPU** = `Cpu-usage-leaders ave` (leader utilization %) or `server median` (pinned core %)

### 6.2 Result file locations

| Path | Contents |
|---|---|
| `results/<timestamp>-zoo-5machines/` | Zoo cluster batch results |
| `results/reproduce_<timestamp>/` | Docker automated reproduction |
| `docs/sweep_2026-02-28/*.tsv` | Canonical Docker sweep data |
| `docs/sweep_2026-02-28/*.md` | Markdown tables from TSV |
| `docs/sweep_2026-02-28/logs/` | Per-run stdout/stderr logs |
| `docs/sweep_2026-02-28/README.md` | Index of all data files |
| `docs/latency_analysis.md` | Consolidated performance analysis |
| `docs/failure_recovery_evaluation.md` | Recovery timing results |
| `docs/phase1f_wan_recovery_20260311/` | Accepted WAN rerun raw logs and consolidated matrix |
| `scripts/test_output/` | Single-run artifacts |
| `results/recent_csv/` (remote) | Latest CSVs before pullback |

### 6.3 Analysis utilities

```bash
# Convert TSV sweep results to Markdown tables
./scripts/tsv_to_md.sh docs/sweep_2026-02-28/*.tsv

# Build consolidated CSV from all sweep TSVs
./scripts/build_consolidated_csv.sh

# Compute latency statistics from tdigest CSVs
python3 scripts/calc_latency.py

# Parse legacy test_output naming
python3 scripts/results_reader.py

# Parse CPU usage from /proc/stat monitoring
python3 scripts/parse_cpustat.py <result_dir> <label> [core_id]

# Process results
python3 results_processor.py <directory name under results/>
```

## 7. TLA+ Model Checking

TLA+ specifications live in `tla/`. All model checking runs in Docker via `tla/run-tlc.sh`.

### Specifications

| Spec | Description | Config |
|---|---|---|
| `raft.tla` | Standalone Raft protocol | `raft.cfg` / `raft_small.cfg` |
| `copilot.tla` | Standalone CoPilot protocol | `copilot.cfg` / `copilot_small.cfg` |
| `mencius.tla` | Standalone Mencius protocol | `mencius.cfg` / `mencius_small.cfg` |
| `base_raft.tla` | Raft base module (INSTANCE'd by wrapper) | - |
| `base_copilot.tla` | CoPilot base module (INSTANCE'd by wrapper) | - |
| `base_mencius.tla` | Mencius base module (INSTANCE'd by wrapper) | - |
| `jetpack.tla` | Jetpack plugin layer (shared across all wrappers) | - |
| `jetpack_raft.tla` | Jetpack + Raft composition | `jetpack_raft.cfg` / `jetpack_raft_small.cfg` |
| `jetpack_copilot.tla` | Jetpack + CoPilot composition | `jetpack_copilot.cfg` / `jetpack_copilot_small.cfg` |
| `jetpack_mencius.tla` | Jetpack + Mencius composition | `jetpack_mencius.cfg` / `jetpack_mencius_small.cfg` |
| `raft_ongaro.tla` | Original Diego Ongaro Raft (reference) | - |

### Run model checking

```bash
# Build Docker image (auto-built by helper script if needed)
docker build -t tlaplus tla/

# Run via helper script
tla/run-tlc.sh raft.tla
tla/run-tlc.sh raft.tla -config raft_small.cfg
tla/run-tlc.sh raft.tla -workers 4
tla/run-tlc.sh jetpack_raft.tla
tla/run-tlc.sh jetpack_copilot.tla
tla/run-tlc.sh jetpack_mencius.tla

# Or run Docker directly
docker run --rm --privileged -v $(pwd)/tla:/tla tlaplus \
  tlc2.TLC -nowarning -deadlock -config raft.cfg raft.tla
```

### Verified properties

Standalone base protocols (5 servers, 3 cmds, 2 keys):
- **Raft**: CommittedLogAgreement, ElectionSafety, LogOrderMatchesExecution (21M+ states)
- **CoPilot**: CommittedLogAgreement, ActiveProposerBound, LogOrderMatchesExecution (11M+ states)
- **Mencius**: SlotAgreement, CommittedLogAgreement, LogOrderMatchesExecution (13M+ states)

Jetpack compositions (5 servers, 3 cmds, 2 keys):
- **Jetpack + Raft**: CommittedLogAgreement, MultiSequenceLogAgreement, LogOrderMatchesExecution, ExecutionDedupMatches (2.9M+ states)
- **Jetpack + CoPilot**: CommittedLogAgreement, MultiSequenceLogAgreement, LogOrderMatchesExecution, ExecutionDedupMatches, ActiveProposerBound (2.4M+ states)
- **Jetpack + Mencius**: CommittedLogAgreement, MultiSequenceLogAgreement, LogOrderMatchesExecution, ExecutionDedupMatches, SlotAgreement (1.5M+ states)

Jetpack wrappers use a shared 3D log projection (`Log[i][j][k]`) where `i` = server, `j` = proposer, `k` = per-sequence position. See `tla/TLA_PLUS_BIG_PICTURE.md` for the design. TLC logs are saved in `tla/log/`.

## 8. Failure Recovery

### 8.1 Docker recovery tests

```bash
# With WAN latency
docker compose -f docker/etcd/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery
```

### 8.2 Recovery timeline

```
T_kill              T_new_leader            T_jetpack_done
  |--- backend ---|--- Jetpack recovery ---|
```

1. Test kills the leader process
2. Backend re-elects a leader
3. Signal file written to `/tmp/JM_Jetpack_0.0.0.0`
4. Jetpack recovery runs (expected: `1ms + 2*RTT` internal duration)
5. Writes `/tmp/JM_Jetpack_recovery_finish_after_failure` on completion

### 8.3 Signal files (in `/tmp/`)

| File | Writer | Meaning |
|---|---|---|
| `JM_Jetpack_failure_triggered` | Test script | Leader kill initiated |
| `JM_Jetpack_0.0.0.0` | Test script | Backend re-election complete |
| `JM_Jetpack_recovery_finish_after_failure` | Jetpack | Recovery complete |

### 8.4 Expected recovery times

RTT-model comparison: expected Jetpack internal duration at `RECOVERY_LATENCY_MS=20` (RTT=40ms) is `1ms + 2*40ms = 81ms`.

| Backend | Backend re-election (script) | Jetpack internal duration |
|---|---|---|
| etcd | 6.568-6.817s | 81-82ms |
| MongoDB | 10.741-23.209s | 82-83ms |
| ZooKeeper | 0.773-0.800s | 81-82ms |

Source: `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md`

### 8.5 Zoo cluster failure recovery

```bash
cd scripts
./09-build_and_test_run_wan.sh --failover --kill-target 2 --kill-delay 20 \
  --filename jetpack-failure-recovery --result-dir ../results/recovery-test
```

See `docs/zoo_failure_recovery_design.md` for protocol-specific leader identification.

### 8.6 Recovery log lines

```
[INFO] JetpackRecoveryEntry: JETPACK-RECOVERY STARTING at <timestamp>
[INFO] ... JETPACK-RECOVERY ... COMPLETED in <duration_ms>ms
```

## 9. Scripts Reference

### 9.1 Classification

| Category | Scripts | Purpose |
|---|---|---|
| **Build** | `docker/zoo-build/Dockerfile` | Canonical build (produces binary + libs) |
| **Docker testing** | `docker/{etcd,mongodb,zookeeper}/` | Local integration test images |
| **Docker sweeps** | `reproduce_evaluation.sh`, `sweep_benchmark.sh`, `run_full_sweep.sh` | Local benchmark automation |
| **Zoo/AWS experiments** | `run_single_exp.sh`, `09-build_and_test_run_wan.sh`, `10-run_all.sh` | Cluster experiment runners |
| **Shared definitions** | `experiment_defs.sh` | Protocol families, concurrency arrays, helpers |
| **Result processing** | `build_consolidated_csv.sh`, `tsv_to_md.sh`, `calc_latency.py`, `results_reader.py`, `parse_cpustat.py` | Analysis and conversion |
| **Ops helpers** | `98-kill.sh`, `94-check-time-sync.sh`, `03-ping.sh` | Cluster operations |
| **Cluster setup** | `00-ips.sh` through `07-link_mongocxx.sh` | Bootstrap new machines |

### 9.2 Ops helpers

| Script | Purpose |
|---|---|
| `00-ips.sh` | Generate `setup.json` from `aws_ips.json` or `zoo_ips.json` |
| `01-exchange_keys.sh` | SSH trust bootstrap |
| `03-ping.sh` | Measure inter-server ping latencies |
| `94-check-time-sync.sh` | NTP sync validation |
| `95-restart_mongodb.sh` | Restart MongoDB replica set (AWS only) |
| `97-git_commit_hash.sh` | Print remote commit hash |
| `98-kill.sh` | `pkill -9 deptran` on all nodes |
| `99-append_ssh_key.sh` | Add SSH key to all nodes |

## 10. Troubleshooting

### Zero throughput for all processes

1. Check output for crash/OOM
2. Verify `--privileged` for Docker runs (required for tc/netem)
3. Increase file descriptors: `ulimit -n 65536`
4. Check Docker memory allocation

### `SIMULATE_WAN` conflict

`SIMULATE_WAN` adds software delays that are **additive** to tc/netem delays. When using Docker benchmarks, ensure it is **not** defined (off by default):

```cpp
// src/deptran/constants.h
// #define SIMULATE_WAN   // MUST be commented out for tc/netem benchmarks
```

For Zoo cluster experiments, WAN delay is via `WAN_DELAY_MS` env var (not `SIMULATE_WAN`).

### Stale signal files

Old `JM_Jetpack_*` files can interfere with recovery tests:

```bash
# Docker
docker run --rm jetpack-etcd bash -c "rm -f /tmp/JM_Jetpack_*"

# Zoo cluster
ssh ztang@130.245.173.101 "rm -f /tmp/JM_*"
```

### `too many open files` (EMFILE)

```bash
ulimit -n 65536
```

### Missing benchmark output

If no `Mid throughput` lines appear, the benchmark may not have reached steady state. Increase `TEST_DURATION` to 60s.

### Recovery takes unusually long (>1s)

Expected Jetpack internal recovery: `1ms + 2 * RTT`. At 20ms one-way (RTT=40ms), expect ~81ms. If longer, check tc/netem rules (`tc qdisc show`) or whether you're running single-process vs multi-process mode.

## 11. Reproducibility Checklist

- [ ] Binary built from current repo state via `docker/zoo-build/Dockerfile`
- [ ] `setup.json` points to correct cluster IPs
- [ ] `LD_LIBRARY_PATH` includes `build/docker_libs/` in all run commands
- [ ] No stale `deptran_server` processes on cluster nodes (`scripts/98-kill.sh`)
- [ ] `WAN_DELAY_MS` set correctly for experiment (20ms for standard WAN tests)
- [ ] Results saved to timestamped directory under `results/`
