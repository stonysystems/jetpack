# Jetpack Failure Recovery and MongoDB Integration

This document explains how Jetpack's failure recovery mechanism works and how Jetpack integrates with MongoDB as a consensus backend.

---

## Table of Contents

1. [Overview](#overview)
2. [Part 1: Failure Recovery Mechanism](#part-1-failure-recovery-mechanism)
   - [Recovery Entry Point](#recovery-entry-point)
   - [Recovery Protocol Steps](#recovery-protocol-steps)
   - [Recovery Trigger Flow](#recovery-trigger-flow)
   - [Key Data Structures](#key-data-structures)
3. [Part 2: Jetpack + MongoDB Integration](#part-2-jetpack--mongodb-integration)
   - [Architecture Overview](#architecture-overview)
   - [MongoDB as Consensus Backend](#mongodb-as-consensus-backend)
   - [Command Execution Flow](#command-execution-flow)
   - [Thread Pool Design](#thread-pool-design)
   - [Database Operations](#database-operations)
4. [Configuration](#configuration)
5. [Key Files Reference](#key-files-reference)

---

## Overview

**Jetpack** is a framework that supports a "fast path" for distributed transactions, running on top of consensus protocols like **Raft** or **MongoDB**. The system provides:

1. **Fast Path Execution**: When possible, commands execute without full consensus overhead
2. **Failure Recovery**: When leaders fail, a Paxos-based protocol recovers uncommitted commands
3. **Pluggable Consensus**: Can use either Raft or MongoDB for atomic broadcast

---

## Part 1: Failure Recovery Mechanism

### Recovery Entry Point

The recovery process starts at `TxLogServer::JetpackRecoveryEntry()`:

**File**: [scheduler.cc:696-710](src/deptran/scheduler.cc#L696-L710)

```cpp
void TxLogServer::JetpackRecoveryEntry() {
  jetpack_recovery_start_time_ = std::chrono::steady_clock::now();
  Log_info("[JETPACK-RECOVERY] ===== STARTING JETPACK RECOVERY ======");
  jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;

  JetpackRecovery();  // Main recovery function

  // Measure and log recovery duration
}
```

**Key Points**:
- Sets `jetpack_status_` to `RECOVERY` to block new fast-path commands
- Calls `JetpackRecovery()` which orchestrates the 8-step protocol
- Measures total recovery duration

### Recovery Protocol Steps

The recovery protocol consists of **8 steps** using a Paxos-like consensus:

```
┌─────────────────────────────────────────────────────────────┐
│                   JETPACK RECOVERY PROTOCOL                  │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Step 1: BeginRecovery                                       │
│    ├─ Broadcast to all replicas                              │
│    ├─ Update views (old_view → new_view)                     │
│    └─ Wait for majority quorum                               │
│                                                              │
│  Step 2: PullRecovery                                        │
│    ├─ Pull uncommitted commands from replicas                │
│    ├─ Collect witness candidate commands                     │
│    └─ Aggregate all commands needing recovery                │
│                                                              │
│  Step 3: RecordCmd                                           │
│    ├─ Assign (sid, rid) pairs to recovered commands          │
│    ├─ Broadcast commands to all replicas                     │
│    └─ Store in rec_set_ indexed by (sid, rid)                │
│                                                              │
│  Step 4: Paxos Prepare                                       │
│    ├─ Send prepare request with current ballot               │
│    ├─ Collect highest accepted values                        │
│    └─ Determine which (sid, set_size) to propose             │
│                                                              │
│  Step 5: Paxos Accept                                        │
│    ├─ Increment ballot number                                │
│    ├─ Broadcast accept with (sid, set_size)                  │
│    └─ Wait for majority acceptance                           │
│                                                              │
│  Step 6: Commit                                              │
│    ├─ Broadcast commit notification (fire-and-forget)        │
│    └─ Committed (sid, set_size) is now consensus             │
│                                                              │
│  Step 7: Resubmit                                            │
│    ├─ For each command in [0, set_size):                     │
│    │   ├─ Pull missing commands from replicas                │
│    │   └─ Dispatch to application layer                      │
│    └─ Wait for all resubmissions to complete                 │
│                                                              │
│  Step 8: FinishRecovery                                      │
│    ├─ Broadcast recovery completion                          │
│    ├─ Update jepoch (Jetpack epoch)                          │
│    └─ Re-enable fast path execution                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### Step-by-Step Details

**Step 1: BeginRecovery** ([scheduler.cc:712-726](src/deptran/scheduler.cc#L712-L726))
```cpp
void TxLogServer::JetpackBeginRecovery() {
  auto e = commo()->JetpackBroadcastBeginRecovery(
    partition_id_, site_id_, old_view_, new_view_, oepoch_);
  e->Wait();  // Wait for majority quorum
}
```
- Broadcasts view change to all replicas
- Old view contains previous leader, new view contains current leader
- Replicas set their status to `RECOVERY` mode

**Step 2-3: PullRecovery + RecordCmd** ([scheduler.cc:728-786](src/deptran/scheduler.cc#L728-L786))
```cpp
auto recovery_e = commo()->JetpackBroadcastPullRecovery(...);
recovery_e->Wait();
auto recovered_entries = recovery_e->GetRecoveredCommands();

// Assign IDs and record
sid = ((sid_cnt_++) << 8) | loc_id_;
auto record_e = commo()->JetpackBroadcastRecordCmd(
  partition_id_, site_id_, jepoch_, oepoch_, sid, rid, recovered_entries);
```
- Pulls uncommitted commands from all replicas
- Each command assigned unique (sid, rid) identifier
- Commands stored in `rec_set_` on all replicas

**Step 4-5: Paxos Prepare/Accept** ([scheduler.cc:788-892](src/deptran/scheduler.cc#L788-L892))
```cpp
// Prepare phase
auto e = commo()->JetpackBroadcastPrepare(
  partition_id_, site_id_, jepoch_, oepoch_, witness_.max_seen_ballot_);

// Accept phase
witness_.max_seen_ballot_++;

auto e = commo()->JetpackBroadcastAccept(
  partition_id_, site_id_, jepoch_, oepoch_,
  witness_.max_seen_ballot_, propose_sid, propose_set_size);
```
- Uses classic Paxos 2-phase commit
- Consensus on (sid, set_size) pair that defines which commands to recover
- Handles ballot conflicts and epoch updates

**Step 6: Commit** ([scheduler.cc:894-908](src/deptran/scheduler.cc#L894-L908))
```cpp
auto e = commo()->JetpackBroadcastCommit(
  partition_id_, site_id_, jepoch_, oepoch_, commit_sid, commit_set_size);
// Note: Optimized - no wait needed after successful Accept
```
- Notifies all replicas of the committed decision
- Fire-and-forget (no wait) for performance

**Step 7: Resubmit** ([scheduler.cc:910-1031](src/deptran/scheduler.cc#L910-L1031))
```cpp
for (int rid = 0; rid < set_size; rid++) {
  auto cmd = rec_set_.get(sid, rid);
  if (!cmd) {
    // Pull missing command from replicas
    auto pull_e = commo()->JetpackBroadcastPullRecSetIns(...);
    pull_e->Wait();
    cmd = pull_e->GetRecoveredCmd();
  }
  DispatchRecoveredCommand(cmd, recovery_event);
}
recovery_event->Wait();  // Wait for all dispatches
```
- Iterates through all commands [0, set_size)
- Pulls missing commands from other replicas
- Dispatches each command to application layer
- Waits for all resubmissions to complete

**Step 8: FinishRecovery** ([scheduler.cc:1024-1031](src/deptran/scheduler.cc#L1024-L1031))
```cpp
auto e = commo()->JetpackBroadcastFinishRecovery(partition_id_, site_id_, oepoch_);
e->Wait();
Log_info("[JETPACK-RECOVERY] FinishRecovery broadcast completed, fast path restored");
```
- Broadcasts recovery completion
- Fast path is re-enabled for new commands

### Recovery Trigger Flow

Recovery is triggered when a new leader is elected:

```
                     Failure Detection
                           │
                           ▼
              ┌────────────────────────┐
              │  Raft Election Timeout │
              │   (0.4-0.7 seconds)    │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  Raft::RequestVote()   │
              │   Collect votes        │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ RaftServer::setIsLeader│
              │      (true)            │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ Create new_view with   │
              │  current server as     │
              │       leader           │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │TriggerJetpackRecovery()│
              │ "setIsLeader transition│
              │     to leader"         │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ JetpackRecoveryEntry() │
              │   Execute 8-step       │
              │     protocol           │
              └────────────────────────┘
```

**Trigger Location**: [raft/server.cc:430-432](src/deptran/raft/server.cc#L430-L432)
```cpp
void RaftServer::setIsLeader(bool isLeader) {
  if (become_new_leader) {
    old_view_ = new_view_;
    new_view_ = View(n_replicas, site_id_, currentTerm);
    TriggerJetpackRecovery("setIsLeader transition to leader");
  }
}
```

### Key Data Structures

**Witness** ([scheduler.h:164-230](src/deptran/scheduler.h#L164-L230))
```cpp
class Witness {
  int64_t max_seen_ballot_;      // Highest ballot seen (Paxos)
  int64_t max_accepted_ballot_;  // Highest ballot accepted
  int sid_;                      // Server ID for recovery set
  int set_size;                  // Size of recovery set
  bool committed_;               // Whether committed
  // Recovery candidate commands per key
  std::unordered_map<int, std::vector<shared_ptr<Marshallable>>> recovery_candidates_;
};
```

**RecoverySet** ([scheduler.h:297-312](src/deptran/scheduler.h#L297-L312))
```cpp
class RecoverySet {
  std::unordered_map<int, std::vector<shared_ptr<Marshallable>>> rec_set_;
  // Indexed by (sid, rid) pairs for O(1) lookup
};
```

**JetpackStatus** ([scheduler.h](src/deptran/scheduler.h))
```cpp
enum JetpackStatus { RECOVERY, READY };
int jetpack_status_ = JetpackStatus::READY;  // Default: accepting commands
```

**Epochs**:
- `jepoch_`: Jetpack epoch - incremented on recovery completion
- `oepoch_`: Operational epoch - tracks view changes

---

## Part 2: Jetpack + MongoDB Integration

### Architecture Overview

MongoDB serves as a **pluggable consensus backend** for Jetpack. Instead of using Raft for atomic broadcast, MongoDB's built-in replication handles command ordering and durability.

```
┌───────────────────────────────────────────────────────────────────────┐
│                        JETPACK + MONGODB ARCHITECTURE                  │
├───────────────────────────────────────────────────────────────────────┤
│                                                                        │
│   ┌──────────────┐     ┌───────────────────┐     ┌─────────────────┐  │
│   │    Client    │────▶│ CoordinatorMongodb │────▶│  MongodbServer  │  │
│   └──────────────┘     └───────────────────┘     └─────────────────┘  │
│                               │                          │             │
│                               │ BroadcastCommit()        │ Submit()    │
│                               ▼                          ▼             │
│                        ┌─────────────┐         ┌─────────────────────┐│
│                        │ MongodbCommo│         │MongodbConnection    ││
│                        │  (RPC)      │         │   ThreadPool        ││
│                        └─────────────┘         └─────────────────────┘│
│                                                         │              │
│                                                         │ Round-robin  │
│                                                         ▼              │
│                        ┌────────────────────────────────────────────┐ │
│                        │           Worker Threads (2000)            │ │
│                        │  ┌────────┐ ┌────────┐ ┌────────┐         │ │
│                        │  │Thread 0│ │Thread 1│ │Thread N│  ...    │ │
│                        │  └────────┘ └────────┘ └────────┘         │ │
│                        └────────────────────────────────────────────┘ │
│                                           │                           │
│                                           ▼                           │
│                        ┌────────────────────────────────────────────┐ │
│                        │        MongodbKVTableHandler               │ │
│                        │    Database: "JetPack"                     │ │
│                        │    Collection: "KVTable"                   │ │
│                        │    Operations: Read(key) / Write(key,val)  │ │
│                        └────────────────────────────────────────────┘ │
│                                           │                           │
│                                           ▼                           │
│                        ┌────────────────────────────────────────────┐ │
│                        │            MongoDB Instance                │ │
│                        │        (External Replica Set)              │ │
│                        └────────────────────────────────────────────┘ │
│                                                                        │
└───────────────────────────────────────────────────────────────────────┘
```

### MongoDB as Consensus Backend

**Key Insight**: MongoDB's replica set provides:
1. **Atomic Broadcast**: Commands are ordered via MongoDB's oplog
2. **Durability**: Data persisted in MongoDB's storage engine
3. **Leader Election**: MongoDB handles primary election (see [Mongodb_Leader_election.md](Mongodb_Leader_election.md))

**Leader Detection** ([mongodb/server.h:63-65](src/deptran/mongodb/server.h#L63-L65)):
```cpp
bool IsLeader() override {
  return loc_id_ == 0;  // Only loc_id 0 is the leader
}
```

**Connection Configuration** ([mongodb/server.h:54-57](src/deptran/mongodb/server.h#L54-L57)):
```cpp
void Setup() override {
  // Only leader creates MongoDB connections
  mongodb_ = make_shared<MongodbConnectionThreadPool>(
    loc_id_ == 0 ? mongodb_connection_ : 0);  // 0 connections for followers
}
```

### Command Execution Flow

When a client submits a command:

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        COMMAND EXECUTION FLOW                            │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. Client sends command                                                 │
│     │                                                                    │
│     ▼                                                                    │
│  2. CoordinatorMongodb::Submit()                                         │
│     ├─ Server()->Submit(cmd)  ──────────────┐                            │
│     │                                        │                           │
│     └─ commo()->BroadcastCommit(cmd)        │                            │
│        (async to all replicas)              │                            │
│                                              │                           │
│  3. MongodbServer::Submit(cmd)  ◀───────────┘                            │
│     │                                                                    │
│     ├─ Extract TxPieceData from command                                  │
│     │                                                                    │
│     ├─ Create mongodb_finished event (ThreadSafeIntEvent)                │
│     │                                                                    │
│     ├─ mongodb_->MongodbRequest(cmd)  ──────┐                            │
│     │  (push to request queue)              │                            │
│     │                                        │                           │
│     ├─ cmd_content->mongodb_finished->Wait() │  (blocked)                │
│     │                                        │                           │
│  4. MongodbHandler (worker thread)  ◀───────┘                            │
│     │                                                                    │
│     ├─ Pop command from request_queues_[thread_id]                       │
│     │                                                                    │
│     ├─ Parse as SimpleRWCommand                                          │
│     │                                                                    │
│     ├─ If READ:  mongodb_handlers_[i]->Read(key)                         │
│     │  If WRITE: mongodb_handlers_[i]->Write(key, value)                 │
│     │                                                                    │
│     └─ cmd_content->mongodb_finished->Set(1)  ──────┐                    │
│        (signal completion)                          │                    │
│                                                      │                   │
│  5. MongodbServer::Submit() resumes  ◀──────────────┘                    │
│     │                                                                    │
│     ├─ RuleWitnessGC(cmd)   // Clean up witness info                     │
│     │                                                                    │
│     └─ app_next_(*cmd)      // Application callback                      │
│                                                                          │
│  6. Response to client                                                   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**Server Submit Implementation** ([mongodb/server.h:66-101](src/deptran/mongodb/server.h#L66-L101)):
```cpp
void Submit(const shared_ptr<Marshallable>& cmd) {
  // 1. Extract command content
  shared_ptr<TxPieceData> cmd_content = ...;

  // 2. Create completion event
  cmd_content->mongodb_finished = Reactor::CreateSpEvent<ThreadSafeIntEvent>();

  // 3. Send to thread pool
  mongodb_->MongodbRequest(cmd);

  // 4. Wait for MongoDB operation to complete
  cmd_content->mongodb_finished->Wait();

  // 5. Cleanup and callback
  RuleWitnessGC(cmd);
  app_next_(*cmd);
}
```

### Thread Pool Design

**MongodbConnectionThreadPool** manages concurrent MongoDB operations:

**File**: [mongodb_connection_thread_pool.h](src/deptran/mongodb_connection_thread_pool.h)

```
┌─────────────────────────────────────────────────────────────────┐
│                  MongodbConnectionThreadPool                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Configuration:                                                  │
│  ├─ AWS:   2000 threads (for high latency, 3000 clients)        │
│  └─ Local: 80 threads (limited by system ulimit)                │
│                                                                  │
│  Components:                                                     │
│  ├─ request_queues_[N]     // Per-thread command queues         │
│  ├─ mongodb_handlers_[N]   // Per-thread DB connections         │
│  ├─ durations_[N]          // Per-thread latency tracking       │
│  └─ round_robin_           // Load balancer counter             │
│                                                                  │
│  Request Distribution:                                           │
│      MongodbRequest(cmd) {                                       │
│        request_queues_[round_robin_]->push(cmd);                │
│        round_robin_ = (round_robin_ + 1) % thread_num_;         │
│      }                                                           │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Worker Thread Loop** ([mongodb_connection_thread_pool.h:53-87](src/deptran/mongodb_connection_thread_pool.h#L53-L87)):
```cpp
void MongodbHandler(int thread_id) {
  while (true) {
    // 1. Wait for command from queue
    shared_ptr<Marshallable> cmd = request_queues_[thread_id]->pop();
    if (cmd == nullptr) break;  // Shutdown signal

    // 2. Parse command
    SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);

    // 3. Execute on MongoDB
    auto start_time = std::chrono::high_resolution_clock::now();

    if (parsed_cmd.IsRead())
      mongodb_handlers_[thread_id]->Read(parsed_cmd.key_);
    else if (parsed_cmd.IsWrite())
      mongodb_handlers_[thread_id]->Write(parsed_cmd.key_, parsed_cmd.value_);

    // 4. Track latency
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(...);
    durations_[thread_id]->append(duration.count());

    // 5. Signal completion
    cmd_content->mongodb_finished->Set(1);
  }
}
```

### Database Operations

**MongodbKVTableHandler** provides the MongoDB driver interface:

**File**: [mongodb_kv_table_handler.h](src/deptran/mongodb_kv_table_handler.h)

**Configuration**:
```cpp
// Connection URI
#ifdef AWS
constexpr char kMongoDbUri[] = "mongodb://184.72.49.232:27017";
#else
constexpr char kMongoDbUri[] = "mongodb://130.245.173.103:27017";
#endif

// Database and Collection
constexpr char kDatabaseName[] = "JetPack";
constexpr char kCollectionName[] = "KVTable";
```

**Write Operation** ([mongodb_kv_table_handler.h:43-74](src/deptran/mongodb_kv_table_handler.h#L43-L74)):
```cpp
bool Write(int key, int value) {
  // Build filter: { "key": key }
  bsoncxx::document::value filter =
    filter_builder << "key" << key << finalize;

  // Build update: { "$set": { "value": value } }
  bsoncxx::document::value update =
    update_builder << "$set" << open_document
                   << "value" << value << close_document
                   << finalize;

  // Upsert (insert or update)
  collection.update_one(filter.view(), update.view(),
                        options::update{}.upsert(true));
  return true;
}
```

**Read Operation** ([mongodb_kv_table_handler.h:77-105](src/deptran/mongodb_kv_table_handler.h#L77-L105)):
```cpp
int Read(int key) {
  // Build filter: { "key": key }
  bsoncxx::document::value filter =
    filter_builder << "key" << key << finalize;

  // Find document
  auto result = collection.find_one(filter.view());

  if (result) {
    auto value_element = result->view()["value"];
    if (value_element.type() == bsoncxx::type::k_int32) {
      return value_element.get_int32().value;
    }
  }
  return 0;  // Default if not found
}
```

---

## Configuration

### Mode Registration

**File**: [constants.h](src/deptran/constants.h)
```cpp
#define MODE_MONGODB (0x9000)
```

**Frame Registration** ([mongodb/frame.cc](src/deptran/mongodb/frame.cc)):
```cpp
REG_FRAME(MODE_MONGODB, vector<string>({"mongodb"}), MongodbFrame);
```

### Configuration Files

- `config/none_mongodb.yml` - No concurrency control + MongoDB consensus
- `config/rule_mongodb.yml` - Rule-based CC + MongoDB consensus

**Example configuration**:
```yaml
cc: none       # Concurrency control: none, rule, etc.
ab: mongodb    # Atomic broadcast: mongodb, raft, etc.
```

---

## Key Files Reference

| Component | File Path | Purpose |
|-----------|-----------|---------|
| **Recovery Entry** | [scheduler.cc:696-710](src/deptran/scheduler.cc#L696-L710) | `JetpackRecoveryEntry()` |
| **8-Step Protocol** | [scheduler.cc:712-1031](src/deptran/scheduler.cc#L712-L1031) | All recovery steps |
| **Recovery Trigger** | [raft/server.cc:430-432](src/deptran/raft/server.cc#L430-L432) | `setIsLeader()` triggers recovery |
| **MongoDB Server** | [mongodb/server.h](src/deptran/mongodb/server.h) | `MongodbServer` class |
| **Thread Pool** | [mongodb_connection_thread_pool.h](src/deptran/mongodb_connection_thread_pool.h) | Worker thread management |
| **DB Handler** | [mongodb_kv_table_handler.h](src/deptran/mongodb_kv_table_handler.h) | MongoDB CRUD operations |
| **RPC Service** | [mongodb/service.cc](src/deptran/mongodb/service.cc) | `MongodbServiceImpl::Commit()` |
| **Communicator** | [mongodb/commo.cc](src/deptran/mongodb/commo.cc) | `BroadcastCommit()` |
| **Frame Factory** | [mongodb/frame.cc](src/deptran/mongodb/frame.cc) | Component factory |
| **View Management** | [view.h](src/deptran/view.h) | `View` class for leader tracking |
| **Witness Tracking** | [scheduler.h:164-230](src/deptran/scheduler.h#L164-L230) | `Witness` class |
| **MongoDB Elections** | [Mongodb_Leader_election.md](Mongodb_Leader_election.md) | MongoDB leader election protocol |

---

## Summary

### Failure Recovery

1. **Detection**: Raft detects leader failure via election timeout (0.4-0.7s)
2. **Election**: New leader elected via Raft voting
3. **Trigger**: `setIsLeader(true)` calls `TriggerJetpackRecovery()`
4. **Protocol**: 8-step Paxos-based recovery ensures no commands are lost
5. **Completion**: Fast path re-enabled after `FinishRecovery` broadcast

### MongoDB Integration

1. **Role**: MongoDB provides atomic broadcast (consensus) instead of Raft
2. **Leader**: `loc_id_ == 0` is always the MongoDB leader
3. **Execution**: Thread pool with round-robin load balancing
4. **Storage**: Key-value pairs in `JetPack.KVTable` collection
5. **Scalability**: 2000 threads on AWS for high-throughput workloads

### Design Principles

- **Pluggable Consensus**: Same Jetpack logic works with Raft or MongoDB
- **Paxos Safety**: Recovery uses classic 2-phase commit for correctness
- **High Concurrency**: Thread pool isolates MongoDB latency from coordination
- **Automatic Failover**: Recovery triggered automatically on leader election
