#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"
#include "../RW_command.h"

namespace janus {

// Per-instance state in the EPaxos instance space
struct EPaxosInstance {
  enum Status { NONE = 0, PREACCEPTED = 1, PREACCEPTED_EQ = 2, ACCEPTED = 3, COMMITTED = 4, EXECUTED = 5 };
  shared_ptr<Marshallable> cmd;
  ballot_t ballot = 0;
  ballot_t vbal = 0;    // validated ballot (corrected EPaxos)
  Status status = NONE;
  int32_t seq = 0;       // sequence number for execution ordering
  vector<int32_t> deps;  // deps[N]: one dependency per replica
  int64_t propose_time = 0;

  // Leader bookkeeping
  int pre_accept_oks = 0;
  int accept_oks = 0;
  bool all_equal = true;
  vector<int32_t> original_deps;
  std::function<void()> commit_callback;
};

// Per-key conflict tracking: last instance per replica that touched this key
struct EPaxosInstPair {
  int32_t last = -1;       // last instance touching this key
  int32_t last_write = -1; // last write instance touching this key
};

class EPaxosCServer : public TxLogServer {
 public:
  int n_replica_ = 0;

  // Instance space: instances_[replica][instance_number]
  map<int32_t, map<int32_t, EPaxosInstance>> instances_;

  // Current instance counter per replica
  vector<int32_t> crt_instance_;

  // Committed/executed watermarks per replica
  vector<int32_t> committed_up_to_;
  vector<int32_t> executed_up_to_;

  // Per-key conflict tracking: conflicts_[replica][key] = InstPair
  vector<unordered_map<key_t, EPaxosInstPair>> conflicts_;

  // Global max sequence per key
  unordered_map<key_t, int32_t> max_seq_per_key_;
  int32_t max_seq_ = 0;

  // Quorum sizes (corrected EPaxos)
  int f_ = 0;  // max failures tolerated = (N-1)/2
  int FastQuorumSize() const { return f_ + (f_ + 1) / 2; }
  int SlowQuorumSize() const { return (n_replica_ + 1) / 2; }

  EPaxosCServer(Frame* frame);
  ~EPaxosCServer();

  // Base class overrides
  void Setup() override {}
  bool IsLeader() override { return true; }  // EPaxos is leaderless, any replica can propose
  bool IsFPGALeader() override { return true; }

  // Get or create instance
  EPaxosInstance& GetInstance(int32_t replica, int32_t instance);

  // Normal path
  void OnPropose(const shared_ptr<Marshallable>& cmd,
                 const std::function<void()>& commit_cb = nullptr);

  // PreAccept handler (remote replica)
  void OnPreAccept(siteid_t leader, siteid_t replica, int64_t instance,
                   ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                   int32_t seq, const vector<int32_t>& deps,
                   int32_t* reply_status, ballot_t* reply_ballot,
                   int32_t* reply_seq, vector<int32_t>* reply_deps);

  // PreAccept reply handler (leader)
  void OnPreAcceptReply(siteid_t replica, int64_t instance,
                        int32_t status, ballot_t ballot,
                        int32_t seq, const vector<int32_t>& deps);

  // Accept handler
  void OnAccept(siteid_t leader, siteid_t replica, int64_t instance,
                ballot_t ballot, int32_t seq, const vector<int32_t>& deps,
                int32_t* reply_status, ballot_t* reply_ballot);

  // Accept reply handler
  void OnAcceptReply(siteid_t replica, int64_t instance,
                     int32_t status, ballot_t ballot);

  // Commit handler
  void OnCommit(siteid_t leader, siteid_t replica, int64_t instance,
                ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                int32_t seq, const vector<int32_t>& deps);

  // Dependency computation
  void UpdateAttributes(const shared_ptr<Marshallable>& cmd,
                        int32_t replica, int32_t instance,
                        int32_t* seq, vector<int32_t>* deps, bool* changed);
  void UpdateConflicts(const shared_ptr<Marshallable>& cmd,
                       int32_t replica, int32_t instance);

  // Execution
  void TryExecute(int32_t replica, int32_t instance);

  // Recovery (Phase 3.5)
  // Prepare: new leader for a stuck instance proposes a higher ballot
  void OnPrepare(siteid_t leader, siteid_t replica, int64_t instance,
                 ballot_t ballot,
                 int32_t* reply_status, ballot_t* reply_ballot,
                 ballot_t* reply_vbal, int32_t* reply_seq);

  // TryPreAccept: recovery optimization, checks for conflicts with existing instances
  void OnTryPreAccept(siteid_t leader, siteid_t replica, int64_t instance,
                      ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                      int32_t seq, const vector<int32_t>& deps,
                      int32_t* reply_status, ballot_t* reply_ballot,
                      ballot_t* reply_vbal,
                      siteid_t* conflict_replica, int64_t* conflict_instance,
                      int32_t* conflict_status);

  // Trigger recovery for a stuck instance
  void StartRecovery(int32_t replica, int32_t instance);

  // ---- Diagnostic counters (logged at intervals) ----
  // EPaxos is leaderless: every replica should host its own coordinator
  // and propose roughly an equal share. If our deployment funnels traffic
  // through one replica (per the SwiftPaxos investigation, deptran's
  // single-server-side-coordinator pattern routes all clients to server0),
  // these counters will be non-zero only on that replica.
  uint64_t propose_count_ = 0;       // calls to OnPropose
  uint64_t preaccept_in_count_ = 0;  // PreAccept RPCs received from peers
  uint64_t commit_in_count_ = 0;     // Commit RPCs received from peers
};

} // namespace janus
