#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"

namespace janus {

// Command descriptor — tracks per-command consensus state
struct SwiftCmdDesc {
  enum Phase { START = 0, PRE_ACCEPT = 1, ACCEPT = 2, COMMIT = 3 };
  Phase phase = START;
  shared_ptr<Marshallable> cmd;
  vector<uint64_t> dep;       // dependency set (command IDs)
  bool slow_path = false;
  bool delivered = false;
  int64_t seqnum = 0;        // leader-assigned sequence number
};

// Per-key conflict info
struct SwiftKeyInfo {
  uint64_t last_write_cmd_id = 0;   // last write command on this key
  uint64_t last_cmd_id = 0;         // last command (read or write) on this key
};

class SwiftPaxosServer : public TxLogServer {
 public:
  // Protocol state
  ballot_t ballot_ = 0;
  ballot_t cballot_ = 0;        // committed ballot
  int status_ = 0;              // 0 = NORMAL, 1 = RECOVERING

  // Leader state
  int64_t seqnum_ = 0;          // leader's sequence counter

  // Per-key conflict tracking
  unordered_map<key_t, SwiftKeyInfo> keys_;

  // Command descriptors
  unordered_map<uint64_t, SwiftCmdDesc> cmd_descs_;

  // Quorum sizes
  int FastQuorum() const { return 3 * n_replica_ / 4 + 1; }
  int SlowQuorum() const { return n_replica_ / 2 + 1; }
  int n_replica_ = 0;

  // Leader identification
  int32_t Leader() const { return ballot_ % n_replica_; }
  bool IsSwiftLeader() const { return loc_id_ == Leader(); }

  SwiftPaxosServer(Frame* frame);
  ~SwiftPaxosServer();

  // Normal path handlers (to be implemented in Phase 2.3)
  void OnPropose(const shared_ptr<Marshallable>& cmd);
  void OnFastAck(siteid_t replica, ballot_t ballot, int64_t cmd_id,
                 const vector<uint64_t>& dep, int64_t seqnum);
  void OnSlowAck(siteid_t replica, ballot_t ballot, int64_t cmd_id);

  // Recovery handlers (to be implemented in Phase 2.5)
  void OnNewLeader(siteid_t replica, ballot_t ballot);
  void OnSync(siteid_t replica, ballot_t ballot);

  // Helper: compute dependencies for a command
  vector<uint64_t> GetDeps(const shared_ptr<Marshallable>& cmd, uint64_t cmd_id);
};

} // namespace janus
