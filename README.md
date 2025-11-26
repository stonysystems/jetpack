# Jetpack

## Run the experiments locally

### build

build rpc
```
bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc
```

build src code
```
python3 waf configure build -J
```

### run raft with local 3 machines close loop 1 * 1 clinents

```
build/deptran_server -f config/none_raft.yml -f config/1c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml -d 30 -m 100 -P localhost
```

### run raft with local 3 machines close loop 12 * 12 clinents

```
build/deptran_server -f config/none_raft.yml -f config/12c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_12.yml -d 30 -m 100 -P localhost
```

### run raft + jetpack failure recovery

```
build/deptran_server -f config/rule_raft.yml -f config/1c1s3r1p.yml -f config/rw.yml -f config/client_closed.yml -f config/concurrent_1.yml -f config/failover.yml -d 30 -m 100 -P localhost
```

### build for raft testing

```
python3 waf configure build -J --enable-raft-test
```

### run raft tests

```
build/deptran_server -f config/raft_lab_test.yml
```

### results process

```
python3 results_processor.py <Experiment time (directory name under results folder)>
```
e.g.
```
python3 results_processor.py 2023-10-10-03:38:03
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