# Zoo Failure-Recovery Experiment Design

## Leader Identification

All four protocols use `loc_id_ == 0` as the Jetpack-level "leader":

| Protocol   | Leader Detection          | Code Location                    |
|------------|---------------------------|----------------------------------|
| Raft       | `loc_id_ == 0` + dynamic election | `src/deptran/raft/server.cc`    |
| MongoDB    | `loc_id_ == 0`            | `src/deptran/mongodb/server.h:85`|
| etcd       | `loc_id_ == 0`            | `src/deptran/etcd/server.h:85`   |
| ZooKeeper  | `loc_id_ == 0`            | `src/deptran/zookeeper/server.h:97`|

In the Zoo config (`config/30c1s5r5p-zoo.yml`), `zoo0` (130.245.173.101)
gets `locale_id == 0` and is therefore the initial leader for all protocols.

### How to kill the leader

Use `--kill-target 0` to kill the deptran_server on zoo0:

```bash
cd scripts && bash 09-build_and_test_run_wan.sh \
    --kill-target 0 --kill-delay 20 \
    --filename rule_raft-failure-recovery
```

### How to kill a follower

Use `--kill-target 2` (or any index 1-4) to kill a follower:

```bash
cd scripts && bash 09-build_and_test_run_wan.sh \
    --kill-target 2 --kill-delay 20 \
    --filename rule_raft-failure-recovery-follower
```

### failover.yml integration

`config/failover.yml` provides **synthetic** failover (soft/hard method):
- `failserver: leader` targets `locale_id == 0` (zoo0)
- `failserver: follower` targets `locale_id == 1` (zoo1)
- `failserver: <N>` targets the Nth server

The `--kill-target` flag adds a **real** `pkill -9` on top of this.
Both mechanisms can coexist: `failover.yml` triggers the software-level
pause/recovery path, while `--kill-target` actually kills the process.

## Client Configuration

The failure-recovery experiments use `client_open_failure_recovery.yml`:
- **Type**: `open` (open-loop, not closed-loop)
- **Rate**: 1000 requests/second per client
- **max_undone**: 180 per client worker

This is confirmed open-loop. The `type: open` setting means clients submit
requests at a fixed rate regardless of completion, which is the correct
model for measuring recovery behavior under load.

## WAN Latency During Failure Recovery

The `09-build_and_test_run_wan.sh` script injects `WAN_DELAY_MS=20` for
Zoo environments (same as the benchmark experiments). This ensures:

- 20ms one-way latency at every RPC point
- ~40ms RTT baseline
- Consistent with experiment 0 results

The latency is **not silently dropped** for failure-recovery runs because
it is injected at the environment level (`export WAN_DELAY_MS=20`) in the
SSH command, not in the experiment config.

## Experiment Matrix

For each of the 4 protocols, one failure-recovery run:

| Protocol        | Config File         | Mode | Kill Target | Duration |
|-----------------|---------------------|------|-------------|----------|
| rule_raft       | rule_raft.yml       | 101  | 0 (leader)  | 70s      |
| rule_mongodb    | rule_mongodb.yml    | 101  | 0 (leader)  | 70s      |
| rule_etcd       | rule_etcd.yml       | 101  | 0 (leader)  | 70s      |
| rule_zookeeper  | rule_zookeeper.yml  | 101  | 0 (leader)  | 70s      |

- Concurrency: per-protocol fixed conc from experiment 0 (via `fixed_conc.json`)
- Workload: `rw_1000000`
- YCSB: `YCSB_A`
- Kill delay: 20s (kill occurs 20s into the 70s run)

## Evidence Requirements

Each run must produce:
1. `test_output/kill_evidence.json` — kill target, PID, timestamp, confirmation
2. `test_output/*.res` — per-server output logs showing recovery
3. `test_output/*.csv` — per-server latency CSV data for plotting
4. Post-kill log showing continued operation on remaining servers
