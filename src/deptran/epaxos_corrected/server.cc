#include "server.h"
#include "commo.h"
#include "../config.h"
#include "../RW_command.h"

namespace janus {

EPaxosCServer::EPaxosCServer(Frame* frame) : TxLogServer() {
  auto config = Config::GetConfig();
  n_replica_ = config->GetPartitionSize(0);
  f_ = (n_replica_ - 1) / 2;
  crt_instance_.resize(n_replica_, 0);
  committed_up_to_.resize(n_replica_, -1);
  executed_up_to_.resize(n_replica_, -1);
  conflicts_.resize(n_replica_);
  Log_info("[EPaxos] Server created, n_replica=%d, f=%d, FQ=%d, SQ=%d",
           n_replica_, f_, FastQuorumSize(), SlowQuorumSize());
}

EPaxosCServer::~EPaxosCServer() {}

EPaxosInstance& EPaxosCServer::GetInstance(int32_t replica, int32_t instance) {
  auto& inst = instances_[replica][instance];
  if (inst.deps.empty()) {
    inst.deps.resize(n_replica_, -1);
  }
  return inst;
}

void EPaxosCServer::UpdateAttributes(const shared_ptr<Marshallable>& cmd,
                                      int32_t replica, int32_t instance,
                                      int32_t* seq, vector<int32_t>* deps,
                                      bool* changed) {
  *changed = false;
  auto key = SimpleRWCommand::GetKey(cmd);
  bool is_write = SimpleRWCommand(cmd).IsWrite();

  // For each other replica, check if there's a conflicting instance on this key
  for (int q = 0; q < n_replica_; q++) {
    if (q == replica) continue;
    auto& conflict_map = conflicts_[q];
    auto it = conflict_map.find(key);
    if (it != conflict_map.end()) {
      int32_t dep_inst = is_write ? it->second.last : it->second.last_write;
      if (dep_inst >= 0 && dep_inst > (*deps)[q]) {
        (*deps)[q] = dep_inst;
        *changed = true;
      }
      // Update seq
      auto& dep_instance = instances_[q][dep_inst];
      if (dep_instance.seq >= *seq) {
        *seq = dep_instance.seq + 1;
        *changed = true;
      }
    }
  }

  // Check global max seq for this key
  auto it = max_seq_per_key_.find(key);
  if (it != max_seq_per_key_.end() && it->second >= *seq) {
    *seq = it->second + 1;
    *changed = true;
  }
}

void EPaxosCServer::UpdateConflicts(const shared_ptr<Marshallable>& cmd,
                                     int32_t replica, int32_t instance) {
  auto key = SimpleRWCommand::GetKey(cmd);
  bool is_write = SimpleRWCommand(cmd).IsWrite();

  auto& info = conflicts_[replica][key];
  info.last = instance;
  if (is_write) {
    info.last_write = instance;
  }

  auto& inst = GetInstance(replica, instance);
  if (inst.seq > max_seq_per_key_[key]) {
    max_seq_per_key_[key] = inst.seq;
  }
  if (inst.seq > max_seq_) {
    max_seq_ = inst.seq;
  }
}

void EPaxosCServer::OnPropose(const shared_ptr<Marshallable>& cmd,
                               const std::function<void()>& commit_cb) {
  // This replica proposes a new instance
  int32_t my_id = loc_id_;
  int32_t inst_id = crt_instance_[my_id];
  crt_instance_[my_id]++;

  auto& inst = GetInstance(my_id, inst_id);
  inst.cmd = cmd;
  inst.ballot = 0;
  inst.vbal = 0;
  inst.status = EPaxosInstance::PREACCEPTED;
  inst.seq = 0;
  inst.propose_time = SimpleRWCommand::GetCurrentMsTime();
  if (commit_cb) inst.commit_callback = commit_cb;

  // Compute initial deps and seq
  bool changed = false;
  UpdateAttributes(cmd, my_id, inst_id, &inst.seq, &inst.deps, &changed);

  // Track conflicts
  UpdateConflicts(cmd, my_id, inst_id);

  // Save original deps for fast-path comparison
  inst.original_deps = inst.deps;
  inst.all_equal = true;
  inst.pre_accept_oks = 0;
  inst.accept_oks = 0;

  // Simplified model: assume all replicas agree on deps (valid for
  // non-conflicting workloads and single-process mode where all replicas
  // share the same conflict table).
  // TODO: implement proper RPC broadcast for multi-process (Phase 3.3 full)
  inst.pre_accept_oks = n_replica_;  // all agree
  inst.all_equal = true;

  // Check if fast path: all FQ replicas agreed with same deps
  if (inst.pre_accept_oks >= FastQuorumSize() && inst.all_equal) {
    // Fast commit!
    inst.status = EPaxosInstance::COMMITTED;

    // Broadcast commit
    // TODO: broadcast Commit RPC

    // Execute
    if (inst.cmd) {
      app_next_(*inst.cmd);
    }
    inst.status = EPaxosInstance::EXECUTED;

    if (inst.commit_callback) {
      inst.commit_callback();
    }
  }
}

void EPaxosCServer::OnPreAccept(siteid_t leader, siteid_t replica, int64_t instance,
                                 ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                                 int32_t seq, const vector<int32_t>& deps,
                                 int32_t* reply_status, ballot_t* reply_ballot,
                                 int32_t* reply_seq, vector<int32_t>* reply_deps) {
  auto& inst = GetInstance(replica, instance);

  if (ballot < inst.ballot) {
    *reply_status = 0;  // NACK
    *reply_ballot = inst.ballot;
    return;
  }

  inst.cmd = cmd;
  inst.ballot = ballot;
  inst.status = EPaxosInstance::PREACCEPTED;
  inst.seq = seq;
  inst.deps = deps;

  // Compute our own deps
  bool changed = false;
  UpdateAttributes(cmd, replica, instance, &inst.seq, &inst.deps, &changed);
  UpdateConflicts(cmd, replica, instance);

  *reply_status = changed ? EPaxosInstance::PREACCEPTED : EPaxosInstance::PREACCEPTED_EQ;
  *reply_ballot = inst.ballot;
  *reply_seq = inst.seq;
  *reply_deps = inst.deps;
}

void EPaxosCServer::OnPreAcceptReply(siteid_t replica, int64_t instance,
                                      int32_t status, ballot_t ballot,
                                      int32_t seq, const vector<int32_t>& deps) {
  // TODO: collect replies, merge deps, check fast path (Phase 3.3 full)
}

void EPaxosCServer::OnAccept(siteid_t leader, siteid_t replica, int64_t instance,
                              ballot_t ballot, int32_t seq, const vector<int32_t>& deps,
                              int32_t* reply_status, ballot_t* reply_ballot) {
  auto& inst = GetInstance(replica, instance);
  if (ballot < inst.ballot) {
    *reply_status = 0;
    *reply_ballot = inst.ballot;
    return;
  }
  inst.ballot = ballot;
  inst.seq = seq;
  inst.deps = deps;
  inst.status = EPaxosInstance::ACCEPTED;
  *reply_status = EPaxosInstance::ACCEPTED;
  *reply_ballot = inst.ballot;
}

void EPaxosCServer::OnAcceptReply(siteid_t replica, int64_t instance,
                                   int32_t status, ballot_t ballot) {
  // TODO: count accept replies, commit when majority (Phase 3.3 full)
}

void EPaxosCServer::OnCommit(siteid_t leader, siteid_t replica, int64_t instance,
                              ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                              int32_t seq, const vector<int32_t>& deps) {
  auto& inst = GetInstance(replica, instance);
  inst.cmd = cmd;
  inst.ballot = ballot;
  inst.seq = seq;
  inst.deps = deps;
  inst.status = EPaxosInstance::COMMITTED;
  UpdateConflicts(cmd, replica, instance);
}

void EPaxosCServer::TryExecute(int32_t replica, int32_t instance) {
  // TODO: Tarjan SCC-based execution (Phase 3.4)
}

// ============================================================
// Recovery (Phase 3.5)
// ============================================================

void EPaxosCServer::OnPrepare(siteid_t leader, siteid_t replica, int64_t instance,
                               ballot_t ballot,
                               int32_t* reply_status, ballot_t* reply_ballot,
                               ballot_t* reply_vbal, int32_t* reply_seq) {
  auto& inst = GetInstance(replica, instance);
  if (ballot < inst.ballot) {
    *reply_status = 0;  // NACK (stale ballot)
    *reply_ballot = inst.ballot;
    *reply_vbal = inst.vbal;
    *reply_seq = inst.seq;
    return;
  }

  // Adopt the new ballot for this instance. The leader will collect replies
  // from a majority and decide the outcome.
  inst.ballot = ballot;
  *reply_status = inst.status;
  *reply_ballot = inst.ballot;
  *reply_vbal = inst.vbal;
  *reply_seq = inst.seq;
}

void EPaxosCServer::OnTryPreAccept(siteid_t leader, siteid_t replica, int64_t instance,
                                    ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                                    int32_t seq, const vector<int32_t>& deps,
                                    int32_t* reply_status, ballot_t* reply_ballot,
                                    ballot_t* reply_vbal,
                                    siteid_t* conflict_replica, int64_t* conflict_instance,
                                    int32_t* conflict_status) {
  auto& inst = GetInstance(replica, instance);
  if (ballot < inst.ballot) {
    *reply_status = 0;  // NACK
    *reply_ballot = inst.ballot;
    *reply_vbal = inst.vbal;
    *conflict_replica = 0;
    *conflict_instance = 0;
    *conflict_status = 0;
    return;
  }

  // In the full EPaxos recovery, we'd check for conflicting instances in our
  // conflict table. For now, always accept (simplified).
  inst.ballot = ballot;
  if (inst.status == EPaxosInstance::NONE) {
    inst.cmd = cmd;
    inst.seq = seq;
    inst.deps = deps;
    inst.status = EPaxosInstance::PREACCEPTED;
  }
  *reply_status = inst.status;
  *reply_ballot = inst.ballot;
  *reply_vbal = inst.vbal;
  *conflict_replica = 0;
  *conflict_instance = 0;
  *conflict_status = 0;
}

void EPaxosCServer::StartRecovery(int32_t replica, int32_t instance) {
  auto& inst = GetInstance(replica, instance);
  // Increment ballot beyond all ballots we've seen
  inst.ballot = inst.ballot + n_replica_ + 1;
  // In full impl: broadcast EPaxosCPrepare to all replicas, collect majority
  // of PrepareReply, decide fate based on 6 corrected subcases.
  Log_info("[EPaxos] StartRecovery for replica=%d instance=%d new_ballot=%ld",
           replica, instance, (long)inst.ballot);
}

} // namespace janus
