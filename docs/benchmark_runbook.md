# Benchmark & Recovery Runbook

Primary entry point for running Jetpack benchmarks and failure recovery tests.
Consolidates instructions from `docs/run.md`, `docs/failure_recovery_design.md`,
and `docs/failure_recovery_evaluation.md`.

---

## 1. Prerequisites

- Docker Engine >= 17.05 (multi-stage builds)
- Docker Compose V2 (`docker compose`, not legacy `docker-compose`)
- Git submodules initialized: `git submodule update --init --recursive`
- Privileged mode required for tc/netem network simulation inside containers
  (set automatically via `privileged: true` in compose files; for `docker run`
  commands, pass `--privileged` explicitly)

## 2. Build Docker Images

```bash
# etcd backend
docker compose -f docker/etcd/docker-compose.yml build

# MongoDB backend
docker compose -f docker/mongodb/docker-compose.yml build

# ZooKeeper backend
docker compose -f docker/zookeeper/docker-compose.yml build
```

Each image bundles the Jetpack binary, backend client libraries, config files,
and network simulation tools.

Compose files pin explicit tags, so successful builds produce:
`jetpack-etcd`, `jetpack-mongodb`, `jetpack-zookeeper`.

Record build metadata for reproducibility:

```bash
git rev-parse --short HEAD
date -Iseconds
docker image inspect jetpack-etcd jetpack-mongodb jetpack-zookeeper \
  --format '{{.RepoTags}} {{.Id}} {{.Created}}'
```

## 3. Run a Single Benchmark

### Minimal (1 client, default config)

```bash
docker run --rm --privileged jetpack-etcd benchmark
docker run --rm --privileged jetpack-mongodb benchmark
docker run --rm --privileged jetpack-zookeeper benchmark
```

### With Jetpack Enabled (rule mode)

```bash
docker run --rm --privileged -e MODE_CONFIG=rule_etcd.yml jetpack-etcd benchmark
```

### Full Configuration

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_etcd.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_200.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  -e SERVER_EXTRA_ARGS="-m 100" \
  jetpack-etcd benchmark
```

### Environment Variables

| Variable | Description | Default | Examples |
|----------|-------------|---------|----------|
| `SITE_CONFIG` | Topology | `5c1s5r1p_<backend>.yml` | `60c1s5r5p.yml` |
| `MODE_CONFIG` | Protocol mode | `none_<backend>.yml` | `rule_etcd.yml` |
| `CLIENT_CONFIG` | Load profile | `client_open.yml` | `client_closed.yml` |
| `CONCURRENT_CONFIG` | Concurrency | `concurrent_1.yml` | `concurrent_200.yml` |
| `LATENCY_MS` | One-way network delay (ms) | `20` | `5`, `40` |
| `LATENCY_JITTER` | Jitter +/- (ms) | `0` | `2`, `5` |
| `TEST_DURATION` | Duration (seconds) | `30` | `60`, `120` |
| `SERVER_EXTRA_ARGS` | Extra server flags | (empty) | `-m 100`, `-m 101` |

### Choosing Mode

| `MODE_CONFIG` | Meaning |
|---------------|---------|
| `none_etcd.yml` | etcd Raft only, no Jetpack |
| `rule_etcd.yml` | etcd + Jetpack (adaptive fast-path) |
| `none_mongodb.yml` | MongoDB only |
| `rule_mongodb.yml` | MongoDB + Jetpack |
| `none_zookeeper.yml` | ZooKeeper only |
| `rule_zookeeper.yml` | ZooKeeper + Jetpack |

### Choosing `-m` (SERVER_EXTRA_ARGS)

| Flag | Meaning |
|------|---------|
| (none) | Adaptive fast-path throttle (default for rule mode; current default maps to `-m 101`) |
| `-m 100` | Force 100% fast-path attempts |
| `-m 101` | Adaptive fast-path throttle (explicitly set the adaptive sentinel used by the implementation) |

## 4. Config Files

All configs are in `config/`:

| Category | Pattern | Example |
|----------|---------|---------|
| Topology | `<clients>c<sites>s<replicas>r<processes>p.yml` | `60c1s5r5p.yml` |
| Mode | `none_<backend>.yml` / `rule_<backend>.yml` | `rule_etcd.yml` |
| Concurrency | `concurrent_<N>.yml` | `concurrent_200.yml` |
| Client | `client_open.yml` / `client_closed.yml` | |

The `60c1s5r5p.yml` topology maps 5 processes (h1-h5) to loopback IPs
127.0.0.1-5. tc/netem adds `LATENCY_MS` one-way delay between them.

## 5. Reading Benchmark Output

Look for these lines per process (h1-h5):

```
h1: site Benchmark Summary: Mid throughput 1500.20    # txn/s
h1: Fastpath statistics attempted 5000 successed 4200  # fast-path usage
h1: Cpu-usage-leaders ave 78.5000 count 5              # CPU %
h1: Queue-depth ave 12.3000 count 100                  # queue depth
```

**Key metrics:**
- **Total throughput** = sum of `Mid throughput` across h1-h5
- **Latency** = `All-efficient-attempts` percentiles (50pct, 90pct, 99pct) in ms
- **Fast-path rate** = `successed / attempted * 100`
- **CPU** = `Cpu-usage-leaders ave` (leader process utilization %)
- **Queue depth** = `Queue-depth ave` (transactions waiting in server queue)

## 6. Concurrency Sweep

The `scripts/sweep_benchmark.sh` script automates running all concurrency levels:

```bash
mkdir -p docs/sweep_2026-02-28

# etcd without Jetpack
./scripts/sweep_benchmark.sh jetpack-etcd none_etcd.yml \
  > docs/sweep_2026-02-28/etcd_original.tsv

# MongoDB with Jetpack
./scripts/sweep_benchmark.sh jetpack-mongodb rule_mongodb.yml \
  > docs/sweep_2026-02-28/mongodb_adaptive.tsv

# ZooKeeper with Jetpack, custom server args
./scripts/sweep_benchmark.sh jetpack-zookeeper rule_zookeeper.yml "-m 100" \
  > docs/sweep_2026-02-28/zk_fp100.tsv
```

Output is TSV with columns: `concurrency`, `total_throughput`, `h1`..`h5`,
`fp_attempted`, `fp_succeeded`, `fp_rate`, `cpu_leader_avg`, `queue_depth_avg`,
`status`, `error_summary`, `log_path`, `retry_count`.

Status values: `OK` (all good), `PARTIAL` (some processes failed), `FAILED` (run failed).
Failed runs are retried up to 2 times. Logs saved under `docs/sweep_2026-02-28/logs/`.

To regenerate Markdown tables from TSV files:

```bash
./scripts/tsv_to_md.sh docs/sweep_2026-02-28/*.tsv
```

## 7. Failure Recovery Tests

### Run Recovery Test

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm jetpack-etcd recovery
docker compose -f docker/mongodb/docker-compose.yml run --rm jetpack-mongodb recovery
docker compose -f docker/zookeeper/docker-compose.yml run --rm jetpack-zookeeper recovery
```

### WAN Recovery (with network latency)

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm \
  -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery
```

### Recovery Timeline

```
T_kill              T_new_leader            T_jetpack_done
  |--- backend ---|--- Jetpack recovery ---|
```

1. Test kills the leader process
2. Backend re-elects a leader (etcd ~6s, MongoDB ~11s, ZooKeeper ~1s)
3. Signal file written to `/tmp/JM_Jetpack_0.0.0.0`
4. Jetpack recovery hooker detects signal, runs 3-phase Paxos (~80-110ms at 20ms RTT)
5. Writes `/tmp/JM_Jetpack_recovery_finish_after_failure` on completion

### Signal Files (in `/tmp/`)

| File | Writer | Meaning |
|------|--------|---------|
| `JM_Jetpack_failure_triggered` | Test script | Leader kill initiated |
| `JM_Jetpack_0.0.0.0` | Test script | Backend re-election complete |
| `JM_Jetpack_recovery_finish_after_failure` | Jetpack | Recovery complete |

### Expected Recovery Times

| Backend | Backend re-election | Jetpack recovery | Total |
|---------|-------------------|------------------|-------|
| etcd | ~6.0-6.7s | ~80-110ms | ~6.1-6.8s |
| MongoDB | ~10.6-11.0s | ~80-110ms | ~10.7-11.1s |
| ZooKeeper | ~0.5-1.1s | ~80-110ms | ~0.6-1.2s |

### Recovery Log Lines

```
[INFO] JetpackRecoveryEntry: JETPACK-RECOVERY STARTING at <timestamp>
[INFO] ... JETPACK-RECOVERY ... COMPLETED in <duration_ms>ms
```

## 8. Troubleshooting

### Zero throughput for all processes

1. Check Docker output for crash/OOM: `docker run ... 2>&1 | head -100`
2. Verify privileged mode is active (required for tc/netem). For `docker run`,
   pass `--privileged`. For `docker compose run`, this is set in the compose file.
3. Increase file descriptors: `ulimit -n 65536` before running
4. Check Docker memory allocation (Docker Desktop > Resources > Memory)

### `SIMULATE_WAN` conflict

The `SIMULATE_WAN` macro in `src/deptran/constants.h` adds software sleeps that are
**additive** to tc/netem delays. When using Docker benchmarks with tc/netem, ensure
`SIMULATE_WAN` is **not** defined:

```cpp
// src/deptran/constants.h
// #define SIMULATE_WAN   // MUST be commented out for tc/netem benchmarks
```

### Stale signal files in `/tmp/`

Old `JM_Jetpack_*` files from previous runs can interfere with recovery tests.
Clean up before re-running:

```bash
docker run --rm jetpack-etcd bash -c "rm -f /tmp/JM_Jetpack_*"
```

### `too many open files` (EMFILE)

```bash
ulimit -n 65536
# Then re-run the benchmark
```

### Missing benchmark output lines

If Docker exits 0 but no `Mid throughput` lines appear, the benchmark may not have
reached steady state. Increase `TEST_DURATION`:

```bash
docker run --rm --privileged -e TEST_DURATION=60 jetpack-etcd benchmark
```

### Recovery takes unusually long (>1s Jetpack downtime)

Check tc/netem rules inside container: `tc qdisc show`

Expected Jetpack recovery time: `1ms (poll) + 2 * RTT`. At RTT=20ms, expect ~41ms.
If significantly longer, check for scheduling delays in single-process mode.

## 9. Where Results Live

| Path | Contents |
|------|----------|
| `docs/sweep_2026-02-28/*.tsv` | Raw sweep benchmark data |
| `docs/sweep_2026-02-28/*.md` | Markdown tables (generated from TSV) |
| `docs/sweep_2026-02-28/README.md` | Index of all data files |
| `docs/sweep_2026-02-28/logs/` | Per-run stdout/stderr logs |
| `docs/latency_analysis.md` | Consolidated performance analysis |
| `docs/failure_recovery_evaluation.md` | Recovery timing results |

## 10. Automated End-to-End Reproduction

For a fully automated evaluation run (build + sanity + sweep + recovery):

```bash
# Full end-to-end reproduction (builds fresh images, runs all tests)
./scripts/reproduce_evaluation.sh

# Preview all commands without executing
./scripts/reproduce_evaluation.sh --dry-run

# Individual phases
./scripts/reproduce_evaluation.sh --build-only     # Only build images
./scripts/reproduce_evaluation.sh --sanity-only    # Build + 6 sanity runs
./scripts/reproduce_evaluation.sh --sweep-only     # Build + 9-case sweep
./scripts/reproduce_evaluation.sh --recovery-only  # Build + 3 recovery tests
```

Results are saved to `results/reproduce_<timestamp>/` with build logs, sanity
run outputs, sweep TSV files, recovery logs, and a summary checklist.

## 11. Cleanup

```bash
docker compose -f docker/etcd/docker-compose.yml down -v
docker compose -f docker/mongodb/docker-compose.yml down -v
docker compose -f docker/zookeeper/docker-compose.yml down -v
```
