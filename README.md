# Jetpack

Jetpack is a plugin consensus protocol that sits on top of a base protocol (e.g. Raft, CoPilot, Mencius). It provides failure recovery via a 3-phase Paxos protocol that is independent of the base consensus layer.

## Build

### Prerequisites

- C++14 compiler (g++ or clang++)
- Python 3 (< 3.12 for WAF build system)
- Docker (for TLA+ model checking and integration tests)

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