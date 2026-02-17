# Failure Recovery Evaluation Methodology

This document describes how to evaluate failure recovery downtime for Jetpack and its
backend protocols (etcd, MongoDB, ZooKeeper). It covers what to measure, which
timestamps/log lines to use, and how to distinguish each recovery phase.

## Recovery Phases

A failure recovery test has three distinct phases:

1. **Leader Kill** — The test script kills the backend protocol's leader/primary process.
2. **Backend Re-election** — The backend's remaining nodes detect the failure and elect
   a new leader. This is the **original protocol downtime**.
3. **Jetpack Recovery** — Once the backend has a new leader, Jetpack detects the change
   (via signal file) and performs its own recovery. This is the **Jetpack downtime**.

```
Timeline:
  T_kill                T_new_leader              T_jetpack_done
    |--- backend downtime ---|--- Jetpack downtime ---|
```

## How Each Phase Is Measured

### T_kill: Leader Kill Timestamp

Captured in each script immediately before calling the kill function:

```bash
kill_ns=$(date +%s%N)       # nanosecond timestamp
kill_<backend>_node "$leader_ip"
```

### T_new_leader: Backend Re-election Complete

**etcd**: `wait_etcd_new_leader()` polls surviving nodes with `etcdctl endpoint status`
until a node reports itself as Raft leader (`raft_leader == member_id`), excluding the
killed IP. Elapsed time from `kill_ns` = etcd downtime.

**MongoDB**: `wait_mongodb_new_primary()` polls surviving nodes with `rs.status()` until
a member reports `stateStr === "PRIMARY"` and it's not the killed IP. Elapsed time from
`kill_ns` = MongoDB downtime.

**ZooKeeper**: `wait_zookeeper_new_leader()` polls surviving nodes with the `srvr`
four-letter command until one reports `Mode: leader`, excluding the killed IP. Elapsed
time from `kill_ns` = ZooKeeper downtime.

### T_jetpack_done: Jetpack Recovery Complete

After the backend elects a new leader, the script writes a signal file:

```bash
echo "<backend>:primary_elected" > /tmp/JM_Jetpack_0.0.0.0
```

Jetpack's recovery hooker (in `src/deptran/jm_file_signal.h`) polls for this file. When
found, it triggers `JetpackRecoveryEntry()`, which performs Jetpack's internal recovery
(re-establish leadership, replay log, etc.).

Recovery completion is detected by polling for either:
- The signal file `/tmp/JM_Jetpack_recovery_finish_after_failure`, or
- The log line matching `JETPACK-RECOVERY.*COMPLETED` in server output.

Jetpack downtime = T_jetpack_done - T_new_leader (i.e., from signal file write to
recovery completion detection).

## How Leader Identity Is Verified Before Kill

Each script dynamically identifies the actual leader (not hardcoded):

| Backend    | Detection Method                                                |
|------------|----------------------------------------------------------------|
| etcd       | `etcdctl endpoint status -w json`: `raft_leader == member_id`  |
| MongoDB    | `mongosh rs.status()`: member with `stateStr === "PRIMARY"`    |
| ZooKeeper  | `echo srvr \| nc`: node with `Mode: leader`                   |

All kill by targeted PID from the cluster PID array (not `pkill`), ensuring only the
leader process is killed while followers remain running.

## Key Log Lines and Signal Files

### Signal Files (in `/tmp/`)

| File                                       | Written By   | Meaning                           |
|-------------------------------------------|-------------|-----------------------------------|
| `JM_Jetpack_failure_triggered`            | Test script  | Leader kill has been triggered     |
| `JM_Jetpack_0.0.0.0`                     | Test script  | Backend re-election complete       |
| `JM_Jetpack_recovery_finish_after_failure`| Jetpack      | Jetpack recovery complete          |

### Jetpack Server Log Lines

| Pattern                            | Meaning                                 |
|-----------------------------------|-----------------------------------------|
| `JETPACK-RECOVERY STARTING`      | Jetpack detected signal, beginning recovery |
| `JETPACK-RECOVERY.*COMPLETED`    | Jetpack recovery finished               |
| `JetpackRecoveryEntry`           | Entry point of Jetpack's recovery code  |

### Backend-Specific Indicators

**etcd**: `etcdctl endpoint status` shows new leader ID after election.

**MongoDB**: `rs.status()` shows new PRIMARY member after election. MongoDB logs show
`transition to primary complete; database writes are now permitted`.

**ZooKeeper**: `srvr` command shows `Mode: leader` on new leader. ZK source code writes
signal file after `setZabState(BROADCAST)` in `Leader.java:lead()`.

## Interpreting Results

| Metric                      | Typical Range     | Notes                              |
|----------------------------|------------------|------------------------------------|
| etcd Raft election         | ~6.0-6.3s        | Default election timeout           |
| MongoDB replica set election| ~10.6s           | Default `electionTimeoutMillis`    |
| ZooKeeper ZAB election     | ~0.5-1.1s        | Fast Leader Election (FLE)         |
| Jetpack internal recovery  | ~106-281ms       | Independent of backend choice      |

Jetpack's recovery time is dominated by its own protocol work (log replay, leadership
re-establishment) and is largely independent of which backend is used.

## Running Recovery Tests

```bash
# etcd
docker/etcd/run-etcd-test.sh recovery

# MongoDB
docker/mongodb/run-mongodb-test.sh recovery

# ZooKeeper
docker/zookeeper/run-zookeeper-test.sh recovery
```

Each test prints a summary with backend downtime and Jetpack downtime in milliseconds.
