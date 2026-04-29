#pragma once
#include <stdint.h>

namespace janus {

#define ballot_t int64_t
#define cooid_t uint32_t
#define rank_t int32_t
#define txid_t uint64_t
#define txnid_t uint64_t
#define cmdid_t uint64_t // txnid and cmdid are the same thing
#define innid_t uint32_t
#define parid_t uint32_t
#define shardid_t uint32_t
#define locid_t uint32_t
#define svrid_t uint16_t
#define cliid_t uint16_t
#define siteid_t uint16_t
#define slotid_t uint64_t
#define phase_t uint32_t
#define epoch_t uint32_t
#define status_t uint32_t
#define txntype_t uint32_t
#define cmdtype_t uint32_t
#define groupid_t uint32_t
#define bool_t int8_t
#define key_t int32_t
#define value_t int32_t
#define ver_t int32_t

/** read and write type */
#define OP_WRITE   (0x01)
#define OP_READ    (0x02)
#define OP_REREAD  (0x04)

/** transaction type */
#define TXN_UNKNOWN (0x00)
//#define TXN_START   (0x01)
//#define TXN_FINISH  (0x02)
//#define TXN_COMMIT  (0x04)
//#define TXN_ABORT   (0x08)

// a transaction (command) status
#define TXN_UKN (0x00)  // unknown
#define TXN_STD (0x01)  // started/dispatched
#define TXN_PAC (0x02)  // pre-accepted
#define TXN_ACC (0x04)  // accepted
#define TXN_CMT (0x08)  // committing
#define TXN_ALL_PREDECESORS_COMMITING (0x10)
#define TXN_DCD (0x20)  // decided
#define TXN_FNS (0x20)  // finished
#define TXN_ABT (0x40)  // aborted

#define TXN_BYPASS     (0x01)
#define TXN_SAFE       (0x02)
#define TXN_INSTANT    (0x02)
#define TXN_IMMEDIATE  (0x02)
#define TXN_DEFERRED   (0x04)
#define TXOP_MULTIHOP        (0x08) // for multi-hop data/flow dependency

#define DF_REAL (0x04)
#define DF_NO   (0x02)
#define DF_FAKE (0x0f)

#define RANK_UNDEFINED (0x00)
#define RANK_I (0x02)
#define RANK_D (0x04)
#define RANK_MAX (0x08)

#define SUCCESS     (0)
#define FAILURE     (-1)
#define CONTENTION  (-1)
#define REJECT      (-10)
#define ABSTAIN     (-10)
#define RETRY       (-10)
#define DELAYED     (1)
#define WRONG_LEADER (-20)

#define MODE_NONE   (0x00)
#define MODE_2PL    (0x01)
#define MODE_OCC    (0x02)
#define MODE_RCC    (0x04)
#define MODE_RO6    (0x08)
#define MODE_BRQ    (0x10)
#define MODE_JANUS    (0x10)
#define MODE_RULE    (0x15)
#define MODE_FEBRUUS    (0x20)
#define MODE_MDCC   (0x12)
#define MODE_TROAD    (0x03)
#define MODE_EXTERNC   (0x14)
#define MODE_RPC_NULL   (0x800)
#define MODE_NOTX   (0x1000)
#define MODE_NONE_COPILOT (0x18)

    // deprecated.
#define MODE_DEPTRAN (4)

#define MODE_MULTI_PAXOS   (0x40)
#define MODE_MULTI_PAXOS_PLUS   (0x41)
#define MODE_EPAXOS        (0x80)
#define MODE_TAPIR         (0x100)
#define MODE_MENCIUS       (0x200)
#define MODE_CAROUSEL (0x2000)
#define MODE_RAFT (0x400)
#define MODE_FPGA_RAFT (0x401)
#define MODE_COPILOT        (0x4000)
#define MODE_MONGODB (0x9000)
#define MODE_ETCD (0x9001)
#define MODE_ZOOKEEPER (0x9002)
#define MODE_SWIFTPAXOS (0x8000)
#define MODE_EPAXOS_CORRECTED (0x8001)
// naive_rpc: no replication, no consensus. All client RPCs go to a single
// server (locale_id=1, i.e. .102). Used as a baseline to measure the floor
// cost (pure RPC round-trip + server processing) and to saturate a single
// server for a CPU ceiling measurement without any consensus work interfering.
#define MODE_NAIVE_RPC (0xA000)
// naive_fastpath: no real consensus. Client broadcasts the Dispatch RPC to
// all 5 replicas; each server executes the R/W and replies unconditionally
// (no conflict check, no ordering, no log). Client commits once it collects
// 4 of 5 replies. Serves as the distributed-work baseline for protocols
// like CURP/EPaxos/SwiftPaxos that also broadcast and rely on a quorum.
#define MODE_NAIVE_FASTPATH (0xA001)
// naive_raft: no real consensus, just a Raft-shaped broadcast on the leader.
// Client sends Dispatch to the fixed leader (locale_id=1, zoo2/.102); leader
// broadcasts Dispatch to the 4 followers with dep_id.str="nr_replicate";
// leader counts itself + waits for 2 follower replies (3/5 simple majority)
// before executing locally and replying to the client. Followers just
// execute locally and ack. No log, no election, no heartbeats — a baseline
// for the CPU/latency cost of the leader-broadcast + majority-quorum shape
// without the bookkeeping of real Raft.
#define MODE_NAIVE_RAFT (0xA002)
// naive_epaxos: no real consensus, EPaxos-shaped leader-per-site
// broadcast. Each client sends Dispatch to its *co-located* server
// (locale_id == client's own locale); that server broadcasts to the 4
// others with dep_id.str="ne_replicate" and waits for 2 follower acks
// (3/5 simple majority counting self). No log, no election, no dep
// tracking — a distributed-leader baseline that matches EPaxos's
// request routing without any EPaxos bookkeeping.
#define MODE_NAIVE_EPAXOS (0xA003)
#define MODE_NOT_READY     (0x00)

// CURP mode flag for -m parameter (not a protocol mode constant)
// Used with rule_raft.yml -m 200: leader checks Raft log, witnesses check command pool, no recovery
#define CURP_MODE 200

#define OP_IR   (0x1)
#define OP_DR   (0x2)
#define OP_R    (0x3)
#define OP_W    (0x4)

#define EDGE_ALL (0x0)
#define EDGE_I  (0x2)
#define EDGE_D  (0x4)

#define RR  (0x0)
#define WW  (0x1)
#define RW  (0x2)
#define WR  (0x4)
#define IRW (0x2)
#define WIR (0x4)
#define DRW (0x1)
#define WDR (0x1)


#define TPCA (0)
#define TPCC (1)
#define RW_BENCHMARK (2)
#define TPCC_DIST_PART (3)
#define TPCC_REAL_DIST_PART (4)
#define MICRO_BENCH (5)

#define YES (1)
#define NO  (0)

// #define COPILOT_DEBUG
// #define COPILOT_TIME_DEBUG
// #define FINISH_COUNTDOWN_MAX (1)
// #define TC

#define AWS
// #define SIMULATE_WAN
// #define FULL_LOG_DEBUG
// #define LATENCY_DEBUG
// #define LATENCY_LOG_DEBUG
// #define MONGODB_DEBUG
// #define ETCD_DEBUG
#define CHECK_KEY_DISTRIBUTION
#define READ_NOT_CONFLICT_OPTIMIZATION
#define JETPACK_DEDUPLICATE_OPTIMIZATION
// #define CHECK_LONG_POLL_WAIT
// #define ZERO_OVERHEAD
// #define DB_CHECKSUM

// #define CPU_PROFILE_MAIN
// #define CPU_PROFILE_SEVER
// #define COMMAND_POOL_LOG_DEBUG
#define FAILOVER_DEBUG
// #define JETPACK_WRONG_LEADER_DEBUG
// #define RAFT_LEADER_ELECTION_LOGIC
// #define RAFT_LEADER_ELECTION_DEBUG
// Allow only one initial election and one post-failure election (jm_signal gated).
#define RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH

// RAFT_BATCH_OPTIMIZATION is on by default; pass `--disable-raft-batch` to
// `waf configure` (or define `RAFT_BATCH_OFF` via CXXFLAGS) to disable it.
// Used by results/<DATE>-akkio/run.sh to produce both a no_batch and a
// batch binary without editing this file in-tree on AWS.
#ifndef RAFT_BATCH_OFF
#define RAFT_BATCH_OPTIMIZATION
#endif

// RAFT_PIPELINE_OPTIMIZATION is on by default; pass
// `--disable-raft-pipeline` to `waf configure` (or define
// `RAFT_PIPELINE_OFF` via CXXFLAGS) to disable it. When defined, the
// per-follower HeartbeatLoop fires AppendEntries asynchronously
// (multiple in-flight per follower, optimistic next_index advance, AE
// reply handled in the rrr callback) instead of the legacy
// request→Wait→reply serial loop.
#ifndef RAFT_PIPELINE_OFF
#define RAFT_PIPELINE_OPTIMIZATION
#endif

// #define JETPACK_RECOVERY_DEBUG

// #define MONGODB_STATISTICS
// #define ETCD_STATISTICS
// #define JM_SIGNAL_DEBUG

// Feature toggle: enable MongoDB-specific JetPack recovery wiring.
// Keep disabled by default so it does not affect other paths unless explicitly opted in.


// Jetpack-mongodb failover
#define JETPACK_MONGODB_RECOVERY
// #define JETPACK_MONGODB_SIMULATION
// Jetpack-etcd failover
#define JETPACK_ETCD_RECOVERY
// #define JETPACK_ETCD_SIMULATION
// Jetpack-zookeeper failover
#define JETPACK_ZOOKEEPER_RECOVERY

#define COMMAND_POOL_ON_DISK

#define CLIENT_SIGNAL_PAUSE_SIGNAL_RESUME

} // namespace janus
