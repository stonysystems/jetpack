# Jetpack

Jetpack is a plugin consensus protocol that sits on top of a base protocol (e.g. Raft, CoPilot, Mencius). It provides failure recovery via a 3-phase Paxos protocol that is independent of the base consensus layer.

## Build

### Prerequisites

- C++14 compiler (g++ or clang++)
- Python 3 (< 3.12 for WAF build system)
- Docker Engine >= 17.05 (for multi-stage builds in Dockerfiles)
- Docker Compose V2 >= 2.0 (the `docker compose` CLI plugin, not the legacy standalone `docker-compose`)

Docker Compose V2 is required because the compose files use the modern format (no
`version:` field) with `depends_on: condition: service_healthy`. Verify your
installation with:

```bash
docker --version          # Docker Engine 17.05+
docker compose version    # Docker Compose V2.0+
```

Some tests require additional Docker flags:
- `--network=host` during `docker build` (so the builder can fetch third-party dependencies)
- `--privileged` at runtime for multi-process tests (tc/netem latency simulation) and TLA+ model checking (cgroup access)

### Build RPC

```
bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc
```

### Build source

```
python3 waf configure build -J
```

### Build for Raft testing

```
python3 waf configure build -J --enable-raft-test
```

## Run experiments locally

### Raft with 3 replicas, 1 client (closed loop)

```
build/deptran_server -f config/none_raft.yml -f config/1c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml -d 30 -m 100 -P localhost
```

### Raft with 3 replicas, 12 clients (closed loop)

```
build/deptran_server -f config/none_raft.yml -f config/12c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_12.yml -d 30 -m 100 -P localhost
```

### Raft + Jetpack failure recovery

```
build/deptran_server -f config/rule_raft.yml -f config/1c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml -f config/failover.yml -d 30 -m 100 -P localhost
```

### Raft lab tests

```
build/deptran_server -f config/raft_lab_test.yml
```

### Process results

```
python3 results_processor.py <directory name under results/>
```

## TLA+ Model Checking

TLA+ specifications live in the `tla/` directory. All model checking runs in Docker via `tla/run-tlc.sh`.

### Specifications

| Spec | Description | Config |
|------|-------------|--------|
| `raft.tla` | Standalone Raft protocol | `raft.cfg` / `raft_small.cfg` |
| `copilot.tla` | Standalone CoPilot protocol | `copilot.cfg` / `copilot_small.cfg` |
| `mencius.tla` | Standalone Mencius protocol | `mencius.cfg` / `mencius_small.cfg` |
| `jetpack.tla` | Jetpack plugin layer (not standalone) | - |
| `jetpack_raft.tla` | Jetpack + Raft composition | `jetpack_raft.cfg` / `jetpack_raft_small.cfg` |
| `jetpack_copilot.tla` | Jetpack + CoPilot composition | `jetpack_copilot.cfg` / `jetpack_copilot_small.cfg` |
| `jetpack_mencius.tla` | Jetpack + Mencius composition | `jetpack_mencius.cfg` / `jetpack_mencius_small.cfg` |
| `raft_ongaro.tla` | Original Diego Ongaro Raft (reference) | - |

### Build the Docker image

```
docker build -t tlaplus tla/
```

### Run model checking

Use the helper script (builds Docker image automatically if needed):

```bash
# Run with default config (spec_name.cfg):
tla/run-tlc.sh raft.tla

# Run with small state constraint for faster exhaustive checking:
tla/run-tlc.sh raft.tla -config raft_small.cfg

# Run with extra workers:
tla/run-tlc.sh raft.tla -workers 4

# Other specs:
tla/run-tlc.sh copilot.tla
tla/run-tlc.sh mencius.tla
tla/run-tlc.sh jetpack_raft.tla
tla/run-tlc.sh jetpack_copilot.tla
tla/run-tlc.sh jetpack_mencius.tla
```

Or run Docker directly:

```bash
docker run --rm --privileged -v $(pwd)/tla:/tla tlaplus \
  tlc2.TLC -nowarning -deadlock -config raft.cfg raft.tla
```

### Verified properties

- **Raft**: CommittedLogAgreement, ElectionSafety (195M+ states explored)
- **CoPilot**: CommittedLogAgreement, ActiveProposerBound (114M+ states explored)
- **Mencius**: SlotAgreement (119M+ states explored)
- **Jetpack + Raft**: CommittedLogAgreement, ElectionSafety (47M+ states explored)
- **Jetpack + CoPilot**: CommittedLogAgreement, ActiveProposerBound (49M+ states explored)
- **Jetpack + Mencius**: SlotAgreement (37M+ states explored)

## Integration Testing

Jetpack integrates with MongoDB, etcd, and ZooKeeper as backend data/coordination stores. Each integration runs in Docker with three test modes: single-process, multi-process, and failure recovery.

### etcd Integration

Code: `src/deptran/etcd/` | Docker: `docker/etcd/`

#### Build

```bash
docker compose -f docker/etcd/docker-compose.yml build
```

#### Single-process test

Starts an embedded etcd server and runs 3 Jetpack replicas + 1 client in one container:

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm jetpack-etcd single
```

#### Multi-process test

Runs 5 Jetpack replicas + 5 clients with simulated network latency (5ms +/- 2ms via tc/netem):

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm --privileged jetpack-etcd multi
```

Customize latency:

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm --privileged \
  -e LATENCY_MS=10 -e LATENCY_JITTER=5 jetpack-etcd multi
```

#### Failure recovery test

Creates a 3-node etcd cluster, kills the leader after 5s, and measures etcd + Jetpack recovery:

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm --privileged jetpack-etcd recovery
```

#### Infrastructure validation

```bash
docker compose -f docker/etcd/docker-compose.yml run --rm jetpack-etcd bash -c "./test-etcd-setup.sh"
```

#### Cleanup

```bash
docker compose -f docker/etcd/docker-compose.yml down -v
```

### MongoDB Integration

Code: `src/deptran/mongodb/` | Docker: `docker/mongodb/`

#### Build

```bash
docker compose -f docker/mongodb/docker-compose.yml build
```

#### Single-process test

Starts an embedded mongod and runs 3 Jetpack replicas + 1 client in one container:

```bash
docker compose -f docker/mongodb/docker-compose.yml run --rm jetpack-mongodb single
```

#### Multi-process test

Runs 5 Jetpack replicas + 5 clients with simulated network latency:

```bash
docker compose -f docker/mongodb/docker-compose.yml run --rm --privileged jetpack-mongodb multi
```

#### Failure recovery test

Creates a 3-member MongoDB replica set, kills the primary after 5s, and measures MongoDB + Jetpack recovery:

```bash
docker compose -f docker/mongodb/docker-compose.yml run --rm --privileged jetpack-mongodb recovery
```

#### Infrastructure validation

```bash
docker compose -f docker/mongodb/docker-compose.yml run --rm jetpack-mongodb bash -c "./test-mongodb-setup.sh"
```

#### Cleanup

```bash
docker compose -f docker/mongodb/docker-compose.yml down -v
```

### ZooKeeper Integration

Code: `src/deptran/zookeeper/` | Docker: `docker/zookeeper/`

#### Build

```bash
docker compose -f docker/zookeeper/docker-compose.yml build
```

#### Single-process test

Starts an embedded ZooKeeper server and runs 3 Jetpack replicas + 1 client in one container:

```bash
docker compose -f docker/zookeeper/docker-compose.yml run --rm jetpack-zookeeper single
```

#### Multi-process test

Runs 5 Jetpack replicas + 5 clients with simulated network latency:

```bash
docker compose -f docker/zookeeper/docker-compose.yml run --rm --privileged jetpack-zookeeper multi
```

#### Failure recovery test

Creates a 3-node ZooKeeper ensemble, kills the leader after 5s, and measures ZooKeeper + Jetpack recovery:

```bash
docker compose -f docker/zookeeper/docker-compose.yml run --rm --privileged jetpack-zookeeper recovery
```

#### Infrastructure validation

```bash
docker compose -f docker/zookeeper/docker-compose.yml run --rm jetpack-zookeeper bash -c "./test-zookeeper-setup.sh"
```

#### Cleanup

```bash
docker compose -f docker/zookeeper/docker-compose.yml down -v
```

## Benchmark Results

See [`result.md`](result.md) for detailed performance and recovery benchmark data.
See [`docs/latency_analysis.md`](docs/latency_analysis.md) for the latency model explanation.

### Benchmark mode

The Docker images support a `benchmark` mode that runs 5 Jetpack processes on separate
loopback IPs (127.0.0.1-5) with tc/netem simulated network latency. Each process runs
a server and client, and results are printed per-process.

**Requirements**: `--privileged` flag is needed for tc/netem and cgroup access.

#### Quick sanity check (1 client per process, concurrency=1)

```bash
# etcd — Jetpack OFF (expected: ~42ms non-leader, ~2ms leader)
docker run --rm --privileged jetpack-etcd benchmark

# etcd — Jetpack ON (expected: ~40ms all processes)
docker run --rm --privileged -e MODE_CONFIG=rule_etcd.yml jetpack-etcd benchmark

# MongoDB — Jetpack OFF (expected: ~87ms non-leader, ~47ms leader)
docker run --rm --privileged jetpack-mongodb benchmark

# ZooKeeper — Jetpack OFF (expected: ~85-90ms all processes)
docker run --rm --privileged jetpack-zookeeper benchmark
```

#### High-concurrency throughput test (60 clients, concurrency=200)

```bash
# etcd — Jetpack OFF
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e CONCURRENT_CONFIG=concurrent_200.yml \
  jetpack-etcd benchmark

# MongoDB — Jetpack ON
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_mongodb.yml \
  -e CONCURRENT_CONFIG=concurrent_200.yml \
  jetpack-mongodb benchmark

# ZooKeeper — Jetpack ON
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_zookeeper.yml \
  -e CONCURRENT_CONFIG=concurrent_200.yml \
  jetpack-zookeeper benchmark
```

#### Environment variables

| Variable | Description | Default |
|---|---|---|
| `SITE_CONFIG` | Site/topology config | `5c1s5r1p_<proto>.yml` |
| `MODE_CONFIG` | Protocol mode (`none_*.yml` or `rule_*.yml`) | `none_<proto>.yml` |
| `CLIENT_CONFIG` | Client mode | `client_open.yml` |
| `CONCURRENT_CONFIG` | Concurrency | `concurrent_1.yml` |
| `LATENCY_MS` | One-way tc/netem delay (ms) | `20` |
| `LATENCY_JITTER` | Latency jitter (ms) | `0` |
| `TEST_DURATION` | Test duration (seconds) | `30` |

#### Reading the output

The benchmark prints per-process results in the `--- Benchmark Results ---` section:

```
[INFO]   h1: ... All-efficient-attempts  statistics  count 10  50pct 2.43  90pct 4.69  99pct 4.69  ave 3.12
[INFO]   h1: ... All-efficient-attempts  distribution  2.41  2.41  3.73  ...
[INFO]   h1: ... Mid throughput is 0.70
```

- **50pct**: Median latency (ms)
- **90pct/99pct**: Tail latencies (ms)
- **ave**: Average latency (ms)
- **Mid throughput**: Transactions per second (steady-state)
- h1 = leader (127.0.0.1), h2-h5 = followers (127.0.0.2-5)

#### Note on SIMULATE_WAN

`SIMULATE_WAN` must be disabled in `src/deptran/constants.h` (currently commented out)
when using tc/netem for network simulation. Otherwise software delays double the latency.

## Failure simulation structure

- svr_workers_g[idx].Pause() ;
  - rep_sched_->Pause();
    - commo_->Pause();
      - for (auto it = rpc_clients_.begin(); it != rpc_clients_.end(); it++) {
      - it->second->pause();
      - }
        - void Client::pause() {
        - paused_ = true;
        - }
  - svr_poll_mgr_->pause();
    - for (int idx = 0; idx < n_threads_; idx++) {
    - poll_threads_[idx].pause();
    - }
      - void pause() { pause_flag_ = true; }