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

  // Diagnostic: log propose distribution every 200 cmds.
  propose_count_++;
  if (propose_count_ % 200 == 0) {
    Log_info("[EP-PROPOSE-CNT] loc_id=%d propose=%llu preaccept_in=%llu "
             "commit_in=%llu",
             (int)loc_id_,
             (unsigned long long)propose_count_,
             (unsigned long long)preaccept_in_count_,
             (unsigned long long)commit_in_count_);
  }

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

  // Self counts as the first PreAcceptOK.
  inst.pre_accept_oks = 1;

  // Broadcast PreAccept to all OTHER replicas. Each peer's reply hits
  // OnPreAcceptReply via the future callback below; once 3N/4 PreAcceptOK
  // accumulate (FastQuorumSize), we transition to COMMIT and broadcast
  // EPaxosCCommit. Previously this code SHORTCUT by setting
  // pre_accept_oks=n_replica_ and committing immediately — that produced
  // an artificially low latency (no inter-replica RTT) and didn't exercise
  // the fast-path consensus. The proper fast path requires waiting one
  // inter-replica RTT for 3N/4-1 peer PreAcceptReplies.
  if (commo()) {
    auto ep_commo = (EPaxosCCommo*)commo();
    auto config = Config::GetConfig();
    parid_t par_id = config->SiteById(site_id_).partition_id_;
    auto& proxies = ep_commo->rpc_par_proxies_[par_id];

    for (auto& p : proxies) {
      if ((int32_t)p.first == site_id_) continue;
      auto proxy = (EPaxosCServiceProxy*)p.second;
      MarshallDeputy md_cmd(cmd);
      MarshallDeputy md_deps(cmd);  // placeholder (handler recomputes)

      rrr::FutureAttr fuattr;
      // Capture (my_id, inst_id) by value; HandlePreAcceptReply uses them
      // to look up the instance in instances_[my_id][inst_id].
      int32_t cap_my_id = my_id;
      int32_t cap_inst_id = inst_id;
      fuattr.callback = [this, cap_my_id, cap_inst_id](rrr::Future* fu) {
        if (fu->get_error_code() != 0) return;
        rrr::i32 status; ballot_t ballot; rrr::i32 seq;
        MarshallDeputy reply_deps;
        fu->get_reply() >> status >> ballot >> seq >> reply_deps;
        this->HandlePreAcceptReply(cap_my_id, cap_inst_id, status, ballot, seq);
      };

      auto fu = proxy->async_EPaxosCPreAccept(
          my_id, my_id, inst_id, inst.ballot,
          md_cmd, inst.seq, md_deps, fuattr);
      Future::safe_release(fu);
    }
  } else {
    // Standalone (no peers): commit immediately. Mostly for tests.
    inst.status = EPaxosInstance::COMMITTED;
    TryExecute(my_id, inst_id);
  }
}

// Reply-counting helper for the EPaxosCPreAccept future callback.
// When pre_accept_oks reaches FastQuorumSize and all_equal holds, the
// instance commits, the leader broadcasts EPaxosCCommit, and the local
// SCC-execute kicks off.
void EPaxosCServer::HandlePreAcceptReply(int32_t my_id, int32_t inst_id,
                                          int32_t status, ballot_t ballot,
                                          int32_t /*seq*/) {
  auto& inst = GetInstance(my_id, inst_id);
  if (inst.status >= EPaxosInstance::COMMITTED) return;
  if (status == 0) {
    // NACK — peer's ballot is higher. Slow path / recovery would handle
    // this; for now just log and skip the count.
    if (ballot > inst.ballot) inst.ballot = ballot;
    return;
  }
  inst.pre_accept_oks++;
  if (inst.pre_accept_oks < FastQuorumSize() || !inst.all_equal) return;

  // Fast-commit threshold reached: transition to COMMITTED and broadcast.
  inst.status = EPaxosInstance::COMMITTED;
  if (commo()) {
    auto ep_commo = (EPaxosCCommo*)commo();
    auto config = Config::GetConfig();
    parid_t par_id = config->SiteById(site_id_).partition_id_;
    auto& proxies = ep_commo->rpc_par_proxies_[par_id];
    for (auto& p : proxies) {
      if ((int32_t)p.first == site_id_) continue;
      auto proxy = (EPaxosCServiceProxy*)p.second;
      MarshallDeputy md_cmd(inst.cmd);
      MarshallDeputy md_deps(inst.cmd);
      auto fu = proxy->async_EPaxosCCommit(
          my_id, my_id, inst_id, inst.ballot,
          md_cmd, inst.seq, md_deps);
      Future::safe_release(fu);
    }
  }
  TryExecute(my_id, inst_id);
}

void EPaxosCServer::OnPreAccept(siteid_t leader, siteid_t replica, int64_t instance,
                                 ballot_t ballot, const shared_ptr<Marshallable>& cmd,
                                 int32_t seq, const vector<int32_t>& deps,
                                 int32_t* reply_status, ballot_t* reply_ballot,
                                 int32_t* reply_seq, vector<int32_t>* reply_deps) {
  preaccept_in_count_++;
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
  commit_in_count_++;
  auto& inst = GetInstance(replica, instance);
  inst.cmd = cmd;
  inst.ballot = ballot;
  inst.seq = seq;
  inst.deps = deps;
  inst.status = EPaxosInstance::COMMITTED;
  UpdateConflicts(cmd, replica, instance);
}

// Tarjan's SCC algorithm state for EPaxos execution
// Based on /tmp/swiftpaxos/epaxos/exec.go (lines 46-172)

namespace {
struct InstanceKey {
  int32_t replica;
  int32_t instance;
  bool operator==(const InstanceKey& o) const {
    return replica == o.replica && instance == o.instance;
  }
};
struct InstanceKeyHash {
  size_t operator()(const InstanceKey& k) const {
    return ((size_t)k.replica << 32) | (size_t)k.instance;
  }
};
}

void EPaxosCServer::TryExecute(int32_t replica, int32_t instance) {
  auto& inst = GetInstance(replica, instance);
  if (inst.status != EPaxosInstance::COMMITTED) return;

  // Simple Tarjan's SCC algorithm
  // 1. Run DFS from (replica, instance), assigning index/lowlink to each node
  // 2. When an SCC is found (lowlink == index), sort by (seq, replica, propose_time)
  // 3. Execute commands in sorted order

  // Stack for DFS
  vector<InstanceKey> stack;
  unordered_map<InstanceKey, int, InstanceKeyHash> on_stack;
  unordered_map<InstanceKey, int, InstanceKeyHash> index_map;
  unordered_map<InstanceKey, int, InstanceKeyHash> lowlink_map;
  int next_index = 0;

  // Recursive-style DFS implemented iteratively
  std::function<bool(int32_t, int32_t)> strongconnect = [&](int32_t r, int32_t i) -> bool {
    InstanceKey key{r, i};
    index_map[key] = next_index;
    lowlink_map[key] = next_index;
    next_index++;
    stack.push_back(key);
    on_stack[key] = 1;

    auto inst_it = instances_.find(r);
    if (inst_it == instances_.end()) return false;
    auto ins_it = inst_it->second.find(i);
    if (ins_it == inst_it->second.end()) return false;
    auto& cur = ins_it->second;

    // If any dependency is not COMMITTED, we can't execute yet
    for (int q = 0; q < n_replica_; q++) {
      if (q == r) continue;
      int32_t dep_inst = cur.deps[q];
      if (dep_inst < 0) continue;
      // Check the dependency instance's status
      auto q_it = instances_.find(q);
      if (q_it == instances_.end()) return false;  // dep not known
      auto qi_it = q_it->second.find(dep_inst);
      if (qi_it == q_it->second.end()) return false;
      auto& dep_instance = qi_it->second;
      if (dep_instance.status < EPaxosInstance::COMMITTED) return false;

      InstanceKey dep_key{q, dep_inst};
      if (index_map.find(dep_key) == index_map.end()) {
        // Not yet visited — recurse
        if (!strongconnect(q, dep_inst)) return false;
        lowlink_map[key] = std::min(lowlink_map[key], lowlink_map[dep_key]);
      } else if (on_stack.find(dep_key) != on_stack.end()) {
        lowlink_map[key] = std::min(lowlink_map[key], index_map[dep_key]);
      }
    }

    // If this is an SCC root, pop the SCC from the stack and execute
    if (lowlink_map[key] == index_map[key]) {
      vector<InstanceKey> scc;
      while (!stack.empty()) {
        InstanceKey top = stack.back();
        stack.pop_back();
        on_stack.erase(top);
        scc.push_back(top);
        if (top == key) break;
      }
      // Sort by (seq, replica, propose_time)
      std::sort(scc.begin(), scc.end(), [this](const InstanceKey& a, const InstanceKey& b) {
        auto& ia = instances_[a.replica][a.instance];
        auto& ib = instances_[b.replica][b.instance];
        if (ia.seq != ib.seq) return ia.seq < ib.seq;
        if (a.replica != b.replica) return a.replica < b.replica;
        return ia.propose_time < ib.propose_time;
      });
      // Execute each instance in order
      for (auto& k : scc) {
        auto& exec_inst = instances_[k.replica][k.instance];
        if (exec_inst.status == EPaxosInstance::EXECUTED) continue;
        if (exec_inst.cmd) {
          app_next_(*exec_inst.cmd);
        }
        exec_inst.status = EPaxosInstance::EXECUTED;
        if (exec_inst.commit_callback) {
          exec_inst.commit_callback();
          exec_inst.commit_callback = nullptr;  // one-shot
        }
      }
    }
    return true;
  };

  strongconnect(replica, instance);
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
