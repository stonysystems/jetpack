#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"
#include "../RW_command.h"
#include "recovery_state.h"
#include "batched_acks.h"
#include <deque>
#include <map>
#include <set>
#include <vector>

namespace janus {

// Per-key info: mirrors imdea-software/swiftpaxos lightKeyInfo (key.go).
// Tracks the most recent cmds on each key so OnPropose can compute a
// dependency list to embed in its FastAck.
struct SwiftKeyInfo {
  std::vector<uint64_t> last_write;  // last write cmd on this key (size 0 or 1)
  std::vector<uint64_t> last_cmd;    // last cmd (read or write)    (size 0 or 1)
};

// Ack from a replica for a command. Carries the replica's computed
// dependency list so the receiver can verify all replicas agree on dep
// (the SwiftPaxos fast-path commit condition).
struct SwiftAck {
  siteid_t replica;
  ballot_t ballot;
  uint64_t cmd_id;
  bool is_slow;
  std::vector<uint64_t> dep;   // dep list this replica computed
  int64_t seqnum;              // leader-assigned seq (0 for non-leader)
  int32_t key{0};              // application-level key (carried for server-side cmd-desc bootstrapping when batched)
};

// Per-command descriptor: tracks consensus progress + per-replica acks.
struct SwiftCmdDesc {
  enum Phase { START = 0, PRE_ACCEPT = 1, ACCEPT = 2, COMMIT = 3 };
  Phase phase = START;
  shared_ptr<Marshallable> cmd;
  uint64_t cmd_id = 0;
  key_t key = 0;
  int64_t seqnum = 0;

  // This replica's own computed dep at Propose time. Stashed so when the
  // leader's FastAck later arrives we can compare against the leader's dep
  // (the IMDEA `neq` predicate in fastAckFromLeader).
  std::vector<uint64_t> my_dep;
  bool my_dep_set = false;

  // Anchor: leader's reported dep (set when leader's FastAck arrives).
  std::vector<uint64_t> leader_dep;
  bool leader_acked = false;

  // Has this replica already emitted a LightSlowAck for this cmd? Used to
  // suppress duplicate broadcasts if leader's FastAck is processed twice.
  bool slow_ack_sent = false;

  // Per-replica acks. fast_acks_by_replica stores each replica's reported
  // dep — fast-path commit fires when 3N/4+1 of these equal leader_dep.
  // slow_ack_replicas tracks non-leader replicas that broadcast a
  // LightSlowAck (adopting the leader's dep on the slow path).
  std::map<siteid_t, std::vector<uint64_t>> fast_acks_by_replica;
  std::set<siteid_t> slow_ack_replicas;

  bool delivered = false;
  bool committed = false;

  std::function<void()> commit_callback;

  // ---- profiling (filled by OnPropose / OnFastAck / CheckCommit) ----
  // All times are microseconds since the local steady_clock epoch. The
  // start anchor is t_propose_us (OnPropose entry on the LOCAL replica),
  // so all later fields are deltas from that point.
  bool prof_active = false;
  uint64_t t_propose_us = 0;            // OnPropose entry on local replica
  uint64_t t_self_acked_us = 0;         // After self-ack
  std::map<siteid_t, uint64_t> ack_arrival_us;  // FastAck arrival per peer
  uint64_t t_first_peer_ack_us = 0;
  uint64_t t_leader_ack_us = 0;
  uint64_t t_commit_us = 0;
  bool committed_via_fast_path = false;
};

class SwiftPaxosServer : public TxLogServer {
 public:
  // Protocol state
  ballot_t ballot_ = 0;
  ballot_t cballot_ = 0;  // committed ballot (for recovery)
  int status_ = 0;  // 0 = NORMAL, 1 = RECOVERING

  // Leader state
  int64_t seqnum_ = 0;  // leader's sequence counter

  // Per-key conflict tracking
  unordered_map<key_t, SwiftKeyInfo> keys_;

  // Command descriptors (indexed by cmd_id)
  unordered_map<uint64_t, SwiftCmdDesc> cmd_descs_;

  // Quorum sizes
  int n_replica_ = 0;
  int FastQuorum() const { return 3 * n_replica_ / 4 + 1; }
  int SlowQuorum() const { return n_replica_ / 2 + 1; }

  // Leader identification
  int32_t Leader() const { return ballot_ % n_replica_; }
  bool IsSwiftLeader() const { return (int32_t)loc_id_ == Leader(); }

  SwiftPaxosServer(Frame* frame);
  ~SwiftPaxosServer();

  // Base class overrides
  void Setup() override {
    auto config = Config::GetConfig();
    batch_enabled_ = config->get_batch_start();
    Log_info("[SwiftPaxos] Setup loc=%d batch_enabled=%d (from mode YAML 'batch:')",
             (int)loc_id_, (int)batch_enabled_);
    if (batch_enabled_) StartBatcherLoop();
  }
  bool IsLeader() override { return IsSwiftLeader(); }
  bool IsFPGALeader() override { return IsSwiftLeader(); }

  // Status constants
  enum Status { NORMAL = 0, RECOVERING = 1 };

  // Normal path
  void OnPropose(const shared_ptr<Marshallable>& cmd,
                 const std::function<void()>& commit_cb = nullptr);
  void OnFastAck(const SwiftAck& ack);
  // Light slow-ack handler: called when an MLightSlowAck arrives. The wire
  // message has no dep — the leader's earlier SwiftFastAck supplies the
  // authoritative dep. We just record that `replica` voted for the leader's
  // dep on the slow path and re-check the commit predicate.
  void OnLightSlowAck(siteid_t replica, ballot_t ballot, uint64_t cmd_id);
  void CheckCommit(SwiftCmdDesc& desc);
  void Deliver(SwiftCmdDesc& desc);

  // Slow-path adoption: invoked when this replica receives the leader's
  // SwiftFastAck. Mirrors IMDEA's fastAckFromLeader: a non-leader broadcasts
  // a SwiftSlowAck (light) iff `slow || (fast && neq)`. Under size-only
  // quorums (the default config), every non-leader sends unconditionally.
  void MaybeSendLightSlowAck(SwiftCmdDesc& desc, const SwiftAck& leader_ack);

  // Recovery flow (mirrors IMDEA recovery.go).
  // (1) A replica suspects leader failure and calls TriggerRecovery, which
  //     picks a higher ballot owned by this replica and broadcasts NewLeader.
  // (2) Each peer transitions to RECOVERING on receipt of NewLeader, packages
  //     its per-cmd state into a SwiftRecoveryState, and unicasts NewLeaderAck
  //     back to the sender (the candidate new leader).
  // (3) The candidate collects a majority of NewLeaderAcks. From the subset
  //     reporting the highest cballot it builds a merged SwiftRecoveryState
  //     (committed/accepted cmds win) and broadcasts Sync.
  // (4) Each peer installs the Sync state, clears stale per-cmd state, and
  //     returns to NORMAL with the new ballot/cballot.
  void TriggerRecovery();
  void OnNewLeaderRecv(siteid_t replica, ballot_t ballot);
  void OnNewLeaderAckRecv(siteid_t replica, ballot_t ballot, ballot_t cballot,
                          shared_ptr<SwiftRecoveryState> state);
  void OnSyncRecv(siteid_t replica, ballot_t ballot,
                  shared_ptr<SwiftRecoveryState> state);

  // Heartbeat / failure detector. The leader bumps `last_leader_activity_ns_`
  // every time it processes a Propose; followers compare it against a
  // monotonic clock at a periodic timer and call TriggerRecovery if the
  // gap exceeds LEADER_TIMEOUT_NS.
  void HeartbeatTick();          // periodic, started from Setup()
  uint64_t last_leader_activity_ns_ = 0;
  bool failure_detector_enabled_ = false;
  static constexpr uint64_t LEADER_TIMEOUT_NS = 2'000'000'000ULL;  // 2s
  static constexpr uint64_t HEARTBEAT_TICK_NS =   500'000'000ULL;  // 500ms

  // Internal helpers.
  shared_ptr<SwiftRecoveryState> SnapshotLocalState() const;
  void InstallRecoveryState(const SwiftRecoveryState& state);
  void BroadcastNewLeader(ballot_t bal);
  void BroadcastSync(ballot_t bal,
                     const shared_ptr<SwiftRecoveryState>& merged);

  // Per-recovery-attempt state: collected NewLeaderAcks at the candidate.
  struct NewLeaderAckEntry {
    ballot_t cballot;
    shared_ptr<SwiftRecoveryState> state;
  };
  std::map<siteid_t, NewLeaderAckEntry> pending_newleader_acks_;
  bool sync_broadcast_done_ = false;

  // ----- Batching (Phase 4) ---------------------------------------------
  // Toggleable via the `batch:` field in the mode YAML (parsed into
  // Config::do_logging_batching()). When enabled, FastAck and LightSlowAck
  // sends are queued here and drained by a periodic coroutine into a single
  // SwiftBatchedAcks RPC per drain interval per peer. When disabled, the
  // legacy per-cmd SwiftFastAck/SwiftSlowAck broadcasts are used.
  bool batch_enabled_ = false;
  bool batcher_started_ = false;
  bool shutdown_ = false;
  std::deque<SwiftAck> pending_fast_acks_;
  std::deque<SwiftAck> pending_slow_acks_;  // .replica/.ballot/.cmd_id only

  // Drain interval in microseconds. ~1 ms is a reasonable balance between
  // batching efficiency and added latency for steady traffic.
  static constexpr uint64_t BATCH_DRAIN_INTERVAL_US = 1000;

  // Send hooks: enqueue if batching is on, otherwise direct broadcast.
  void EnqueueFastAck(const SwiftAck& ack);
  void EnqueueLightSlowAck(siteid_t replica, ballot_t ballot, uint64_t cmd_id);

  // Direct (unbatched) broadcasts — used when batch_enabled_ is false.
  void BroadcastFastAckDirect(const SwiftAck& ack);
  void BroadcastLightSlowAckDirect(ballot_t ballot, uint64_t cmd_id);

  // Drain the pending queues into a SwiftBatchedAcks payload and broadcast.
  void DrainBatcher();

  // Service-side unpacker: turns a SwiftBatchedAcks payload back into
  // OnFastAck / OnLightSlowAck calls.
  void OnBatchedAcks(shared_ptr<SwiftBatchedAcks> acks);

  // Spawned from Setup() once the partition layout is known.
  void StartBatcherLoop();

  // Dependency computation (mirrors lightKeyInfo.getConflictCmds in the
  // reference impl). For a write, returns last_cmd; for a read, last_write.
  std::vector<uint64_t> GetDep(key_t key, uint64_t cmd_id, bool is_write);
  void TrackKey(key_t key, uint64_t cmd_id, bool is_write);

  // Compare two dep lists for set-equality. Empty == empty.
  static bool DepsEqual(const std::vector<uint64_t>& a,
                        const std::vector<uint64_t>& b);

  // Diagnostic only: how many local commands have we profile-traced so far?
  // Cap to keep log volume bounded at c=1 we expect ~120 cmds per host /30s.
  uint64_t prof_traced_count_ = 0;
  static constexpr uint64_t kProfTraceLimit = 60;
  static uint64_t NowUs();
};

} // namespace janus
