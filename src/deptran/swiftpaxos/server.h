#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"
#include "../RW_command.h"

namespace janus {

// Per-key conflict info: tracks last command on each key
struct SwiftKeyInfo {
  uint64_t last_write_cmd_id = 0;  // last write on this key
  uint64_t last_cmd_id = 0;        // last command (read or write) on this key
};

// Ack from a replica for a command
struct SwiftAck {
  siteid_t replica;
  ballot_t ballot;
  uint64_t cmd_id;
  bool is_slow;       // true = slow ack (deps mismatch), false = fast ack
  key_t key;          // key from the command (for hash comparison)
  int64_t seqnum;     // leader's sequence number (0 for non-leader)
};

// Per-command descriptor: tracks consensus progress
struct SwiftCmdDesc {
  enum Phase { START = 0, PRE_ACCEPT = 1, ACCEPT = 2, COMMIT = 3 };
  Phase phase = START;
  shared_ptr<Marshallable> cmd;
  uint64_t cmd_id = 0;
  key_t key = 0;
  int64_t seqnum = 0;  // leader-assigned sequence number

  // Ack tracking
  int fast_ack_count = 0;
  int slow_ack_count = 0;
  bool leader_acked = false;
  bool delivered = false;
  bool committed = false;

  // Callback when committed
  std::function<void()> commit_callback;
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

  // Conflict detection
  bool HasConflict(key_t key, uint64_t cmd_id);
  void TrackKey(key_t key, uint64_t cmd_id, bool is_write);
};

} // namespace janus
