# MongoDB Integration Review

Review of the existing Jetpack + MongoDB integration code in `src/deptran/mongodb/`
and supporting headers `src/deptran/mongodb_*.h`.

## 1. File Inventory

### Core module (`src/deptran/mongodb/`)

| File | Lines | Purpose |
|------|-------|---------|
| `frame.h` | 23 | Frame factory declaration |
| `frame.cc` | 62 | Registers `MODE_MONGODB` (0x9000), creates Coordinator/Scheduler/Commo/Service |
| `coordinator.h` | 34 | `CoordinatorMongodb` — Submit forwards to server then broadcasts |
| `coordinator.cc` | 33 | Submit implementation |
| `server.h` | 191 | `MongodbServer` (TxLogServer) — core engine with thread pool and failover |
| `server.cc` | 3 | Empty (all logic is inline in server.h) |
| `commo.h` | 16 | `MongodbCommo` declaration |
| `commo.cc` | 23 | `BroadcastCommit()` — fire-and-forget async RPC to replicas |
| `service.h` | 17 | `MongodbServiceImpl` declaration |
| `service.cc` | 16 | Commit handler — calls `RuleCommandPoolGC()` only (no execution) |

### Supporting headers (`src/deptran/`)

| File | Lines | Purpose |
|------|-------|---------|
| `mongodb_kv_table_handler.h` | 142 | Low-level mongocxx wrapper: Write/Read/Clear/Setup |
| `mongodb_connection_thread_pool.h` | 304 | Worker thread pool with per-thread MongoDB connections |

**Total: ~860 lines** across 12 files.

## 2. Architecture

The integration follows the same plugin pattern as etcd:

```
Client → CoordinatorMongodb::Submit()
    ├─ MongodbServer::Submit(cmd)
    │   ├─ Create ThreadSafeIntEvent (mongodb_finished)
    │   ├─ MongodbConnectionThreadPool::MongodbRequest(cmd)  [enqueue]
    │   │   └─ Worker thread: parse SimpleRWCommand → mongocxx Write/Read
    │   │       └─ Set mongodb_finished event
    │   ├─ mongodb_finished->Wait()  [BLOCKING]
    │   ├─ RuleCommandPoolGC(cmd)
    │   └─ app_next_(*cmd)
    ├─ MongodbCommo::BroadcastCommit()  [fire-and-forget]
    └─ Callbacks
```

### Key differences from etcd integration

| Aspect | MongoDB | etcd |
|--------|---------|------|
| Driver | mongocxx (sync only) | etcd-cpp-apiv3 (async pplx or sync) |
| Thread model | Pre-created worker pool, round-robin queues | Per-request detached thread or pplx task |
| Data format | BSON documents ({key: N, value: N}) | String key-value (`JetPack/KVTable/N` → `N`) |
| Connections | One mongocxx client per worker thread | Shared client with inflight counter |

## 3. MongoDB Driver Usage

Uses **mongocxx v3** (C++ driver) with **bsoncxx** for serialization:

- **Database**: `"JetPack"`, **Collection**: `"KVTable"`
- **Write**: `collection.update_one({key: K}, {$set: {value: V}}, upsert=true)`
- **Read**: `collection.find_one({key: K})` — returns int value (0 if not found)
- **Clear**: `db.drop()` — drops entire database
- **Setup**: Creates index on `"key"` field

All operations are **synchronous blocking**. No async mongocxx API is used.

### Connection URI

```cpp
// Recovery mode: built from config replica hosts
"mongodb://host1:27017,host2:27017,host3:27017"

// Legacy fallback (hardcoded, should not be used):
"mongodb://184.72.49.232:27017"   // AWS
"mongodb://130.245.173.103:27017" // Local
```

The recovery-mode URI construction (lines 64-82 in server.h) mirrors the etcd
integration: it extracts hostnames from `Config::GetReplicaHosts()` and forces
port 27017.

## 4. Thread Pool Architecture

`MongodbConnectionThreadPool` creates N worker threads at construction:

1. Each worker thread creates its own `MongodbKVTableHandler` (separate connection)
2. Each worker has a dedicated `CommandQueue` (mutex + condition variable)
3. Requests dispatched via round-robin: `request_queues_[round_robin_++ % N]`
4. Worker pops from queue, parses `SimpleRWCommand`, calls Read/Write, signals completion

**Sizing**: 2500 threads on AWS, 80 locally. Non-leaders get 0 threads (drop all requests).

**Metrics** (compile-time `MONGODB_STATISTICS`):
- Queue wait time, queue depth, service time, end-to-end latency
- Dumped at shutdown via `Dump()` method

## 5. Failover Recovery

Identical pattern to etcd integration:

1. `KillMongodbPrimary()` in `s_main.cc` kills mongod via `pkill -KILL`
2. External MongoDB replica set elects new primary
3. New primary (or hooker) writes signal: `jm_signal::set_key("mongo", "primary_elected", host)`
4. Non-leader `MongodbServer::Setup()` coroutine polls for signal every 10ms
5. On detection: calls `JetpackRecoveryEntry()` → 3-phase Paxos recovery

**Compile flags** (`constants.h`):
- `JETPACK_MONGODB_RECOVERY`: Enables config-based URI and signal polling (enabled)
- `JETPACK_MONGODB_SIMULATION`: Fakes election via sleep+signal (disabled)

## 6. Replica Behavior

**Important**: `MongodbServiceImpl::Commit()` only calls `RuleCommandPoolGC()` — it does
**not** execute the transaction on replicas. Only the leader writes to MongoDB.
Replicas receive the commit RPC for command pool garbage collection only.

This means MongoDB acts as a **single-writer** system in the Jetpack integration.
Replicas do not maintain independent MongoDB state.

## 7. Status Assessment

### Functionally complete

- Frame registration and factory pattern
- Command dispatch through thread pool
- SimpleRWCommand parsing and MongoDB read/write
- Fire-and-forget broadcast to replicas
- Failover signaling infrastructure
- Recovery-mode URI construction from config

### Issues found

1. **Hardcoded legacy URIs** — `kMongoDbUri` still contains AWS/local IPs.
   Only overridden when `JETPACK_MONGODB_RECOVERY` is defined.

2. **server.cc is empty** — All 191 lines of server logic are inline in server.h.
   Works but unconventional.

3. **Commented-out ExecutionHandler** — Lines 91-94 in server.h show an abandoned
   async execution approach. Currently dead code.

4. **Coordinator::Restart() crashes** — Contains `verify(0)` (assertion failure).
   Will abort if ever called.

5. **No async MongoDB API** — Uses sync mongocxx only. The etcd integration has
   dual async/sync paths.

6. **Heavy thread pool** — 2500 threads on AWS with per-thread connections.
   Memory overhead: ~2.5GB for thread stacks alone.

7. **Replica service is a stub** — `MongodbServiceImpl::Commit()` only does GC,
   does not execute transactions on replicas.

8. **Single collection** — All data in `JetPack.KVTable`, no partitioning.

### What works well

- Clean separation of concerns (handler, pool, server, coordinator)
- Thread pool with queue-based dispatch and metrics
- Recovery signaling follows proven etcd pattern
- Config-based URI construction for multi-host replica sets

## 8. Comparison with etcd Integration

The MongoDB integration is structurally identical to etcd but simpler:

- **Same**: Frame/Coordinator/Server/Commo/Service pattern, fire-and-forget
  broadcast, file-based failover signaling, ThreadSafeIntEvent completion,
  SimpleRWCommand parsing, non-leader request dropping
- **Different**: Sync-only API (no pplx), pre-allocated thread pool (vs
  per-request threads), BSON documents (vs string KV), single-writer replicas

The integration is **functionally complete for basic read/write** and
**failover recovery** paths. The main gaps are async API support and
configuration flexibility.
