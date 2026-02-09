# Etcd Integration Review

Review of the existing Jetpack + etcd integration code.

## Architecture

Etcd serves as an atomic broadcast (AB) layer for Jetpack. The integration
follows the standard Jetpack plugin pattern: Frame, Coordinator, Server,
Communicator, and RPC Service.

```
Client Request
    |
    v
CoordinatorEtcd::Submit(cmd)
    |
    v
EtcdServer::Submit(cmd)
    |-- Creates ThreadSafeIntEvent (etcd_finished)
    |-- Calls EtcdConnectionThreadPool::EtcdRequest(cmd)
    |-- Waits for completion signal
    v
EtcdConnectionThreadPool
    |-- Parses SimpleRWCommand
    |-- Dispatches to EtcdKVTableHandler (async or sync)
    |-- Signals completion: cmd_content->etcd_finished->Set(1)
    v
EtcdKVTableHandler
    |-- Uses etcd-cpp-apiv3 client
    |-- Reads/writes to etcd at http://127.0.0.1:2379
    |-- Key prefix: "JetPack/KVTable/"
    v
Post-completion (back in EtcdServer::Submit)
    |-- RuleWitnessGC(cmd)
    |-- app_next_(*cmd) -- downstream processing
    |
    v
EtcdCommo::BroadcastCommit(par_id, cmd)
    |-- RPC to all replicas via EtcdProxy::async_Commit()
    v
EtcdServiceImpl::Commit() (on replicas)
    |-- RuleWitnessGC on received command
    |-- Immediate reply (fire-and-forget)
```

## Files

| File | LOC | Description |
|------|-----|-------------|
| `etcd/frame.h` | ~25 | Frame factory interface |
| `etcd/frame.cc` | ~55 | Component creation, `REG_FRAME(MODE_ETCD, {"etcd"}, EtcdFrame)` |
| `etcd/coordinator.h` | ~35 | `CoordinatorEtcd` wrapping base `Coordinator` |
| `etcd/coordinator.cc` | ~20 | `Submit()`: server submit + broadcast + callbacks |
| `etcd/server.h` | ~190 | `EtcdServer`: core logic, recovery, submit pipeline |
| `etcd/commo.h` | ~15 | `EtcdCommo` communicator interface |
| `etcd/commo.cc` | ~25 | `BroadcastCommit()` via RPC proxies |
| `etcd/service.h` | ~15 | `EtcdServiceImpl` RPC service interface |
| `etcd/service.cc` | ~15 | `Commit()`: GC + immediate reply |
| `etcd_kv_table_handler.h` | ~120 | KV abstraction over etcd client (async/sync) |
| `etcd_connection_thread_pool.h` | ~250 | Inflight tracking, metrics, request dispatch |

## Key Design Decisions

1. **Dual API support**: Compile-time switch (`JANUS_ETCD_HAS_PPLX`) for async
   (pplx::task) vs sync (std::thread) etcd client API.

2. **Inflight throttling**: `max_inflight_` limits concurrent etcd requests;
   non-leader nodes can be set to 0 (drop all requests).

3. **File-based recovery signaling**: `jm_file_signal.h` uses `/tmp/JM_Jetpack_<host>`
   files to coordinate between etcd leader election and Jetpack failover.

4. **Leader-only writes**: `loc_id_ == 0` is the leader; non-leaders in recovery
   mode reject TPC commits with `WRONG_LEADER`.

## Compile-Time Feature Flags

| Flag | Default | Effect |
|------|---------|--------|
| `JETPACK_ETCD_RECOVERY` | Enabled | Failover signaling via jm_file_signal |
| `JETPACK_ETCD_SIMULATION` | Disabled | WAN latency simulation |
| `ETCD_DEBUG` | Disabled | Per-operation debug logging |
| `ETCD_STATISTICS` | Disabled | Latency/throughput metrics collection |
| `JANUS_ETCD_HAS_PPLX` | Auto-detected | Async API via C++ REST SDK pplx |

## Issues and Observations

1. **Hardcoded URIs**: ~~`kEtcdUri = "http://127.0.0.1:2379"` is hardcoded in
   `etcd_kv_table_handler.h`. For multi-node setups, this needs to be
   configurable per-node.~~ **FIXED**: In `JETPACK_ETCD_RECOVERY` mode,
   `EtcdServer::Setup()` now builds the URI from `Config::GetReplicaHosts()`
   (same pattern as MongoDB). The hardcoded constant is only used as fallback
   in non-recovery mode.

2. **No server.cc**: All `EtcdServer` logic is in the header file. This is
   functional but unconventional for a class this large (~190 lines).

3. **Thread-per-sync-request**: When pplx is unavailable, sync operations
   spawn a detached `std::thread` per request. This could be expensive under
   high load.

4. **Fire-and-forget replicas**: `EtcdServiceImpl::Commit()` calls GC and
   immediately replies without actually applying the command. This is by
   design (etcd handles replication) but means replicas only do GC.

5. **AWS-specific connection counts**: Connection pool sizes are hardcoded
   via `#ifdef AWS` (2500 vs 80). Should ideally be configurable.

6. **Recovery signal race**: The file-signal mechanism polls every 10ms.
   There's a window where the signal could be written between polls.
   This is acceptable for the current design (10ms granularity).

7. **Config file**: `config/none_etcd.yml` sets `ongoing: 1` (1 inflight
   per client), which limits throughput for benchmarking.

## Integration Status

The etcd integration is **functionally complete** for the basic read/write
path. The code compiles against `etcd-cpp-apiv3` and follows the same
patterns as the MongoDB integration. The failure recovery mechanism
(`JETPACK_ETCD_RECOVERY`) is implemented and uses file-based signaling.

## RPC Definition

From `src/deptran/rcc_rpc.rpc`:
```
abstract service Etcd {
  defer Commit(MarshallDeputy cmd);
}
```

This generates `EtcdService` (base), `EtcdServiceImpl` (server-side),
and `EtcdProxy` (client-side stub).

## API Verification

Verified the etcd API call chain against `etcd-cpp-apiv3` v0.2.14 headers:

| Jetpack Call | etcd-cpp-apiv3 Method | Return Type (async) | Return Type (sync) |
|---|---|---|---|
| `handler_->WriteAsync(key, value)` | `Client::put(string, string)` | `pplx::task<Response>` | N/A |
| `handler_->ReadAsync(key)` | `Client::get(string)` | `pplx::task<Response>` | N/A |
| `handler_->Write(key, value)` | `Client::put(...)` / `SyncClient::put(...)` | `pplx::task<Response>` | `Response` |
| `handler_->Read(key)` | `Client::get(...)` / `SyncClient::get(...)` | `pplx::task<Response>` | `Response` |
| `handler_->Clear()` | `Client::rmdir(prefix, true)` / `SyncClient::rmdir(...)` | `pplx::task<Response>` | `Response` |

All method signatures match. `Response::is_ok()` and `Response::value().as_string()`
are confirmed to exist in the library headers.

**Key observation**: Read results are intentionally discarded in
`EtcdConnectionThreadPool::EtcdRequest()`. Etcd serves as the atomic broadcast
(ordering) layer — the actual state machine lives in Jetpack. The read/write to
etcd ensures the command is ordered through etcd's Raft consensus, not for data
retrieval.
