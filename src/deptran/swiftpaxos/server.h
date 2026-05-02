#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"
#include "../RW_command.h"
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
};

// Per-command descriptor: tracks consensus progress + per-replica acks.
struct SwiftCmdDesc {
  enum Phase { START = 0, PRE_ACCEPT = 1, ACCEPT = 2, COMMIT = 3 };
  Phase phase = START;
  shared_ptr<Marshallable> cmd;
  uint64_t cmd_id = 0;
  key_t key = 0;
  int64_t seqnum = 0;

  // Anchor: leader's reported dep (set when leader's FastAck arrives).
  std::vector<uint64_t> leader_dep;
  bool leader_acked = false;

  // Per-replica acks. fast_acks_by_replica stores each replica's reported
  // dep — fast-path commit fires when 3N/4+1 of these equal leader_dep.
  // slow_ack_replicas counts replicas that explicitly slow-acked (after
  // detecting their dep mismatched the leader's).
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
  void Setup() override {}
  bool IsLeader() override { return IsSwiftLeader(); }
  bool IsFPGALeader() override { return IsSwiftLeader(); }

  // Status constants
  enum Status { NORMAL = 0, RECOVERING = 1 };

  // Normal path
  void OnPropose(const shared_ptr<Marshallable>& cmd,
                 const std::function<void()>& commit_cb = nullptr);
  void OnFastAck(const SwiftAck& ack);
  void OnSlowAck(const SwiftAck& ack);
  void CheckCommit(SwiftCmdDesc& desc);
  void Deliver(SwiftCmdDesc& desc);

  // Recovery path (Phase 2.5)
  // NewLeader: a replica proposes to become the new leader with a higher ballot.
  // All replicas enter RECOVERING status and respond with their committed state.
  void OnNewLeaderRecv(siteid_t replica, ballot_t ballot);

  // NewLeaderAck: the proposed new leader collects state from majority of replicas.
  // Each reply includes cballot (committed ballot) and committed commands.
  void OnNewLeaderAckRecv(siteid_t replica, ballot_t ballot, ballot_t cballot);

  // Sync: the new leader broadcasts the merged state to all replicas.
  // Replicas apply this state and return to NORMAL status.
  void OnSyncRecv(siteid_t replica, ballot_t ballot);

  // Trigger recovery: called when a replica detects leader failure
  void TriggerRecovery();

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
