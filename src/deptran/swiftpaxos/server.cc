#include "server.h"
#include "commo.h"
#include "../config.h"
#include "../RW_command.h"
#include <algorithm>
#include <chrono>
#include <sstream>

namespace janus {

uint64_t SwiftPaxosServer::NowUs() {
  using namespace std::chrono;
  return duration_cast<microseconds>(
             steady_clock::now().time_since_epoch()).count();
}

SwiftPaxosServer::SwiftPaxosServer(Frame* frame)
    : TxLogServer() {
  auto config = Config::GetConfig();
  n_replica_ = config->GetPartitionSize(0);
  Log_info("[SwiftPaxos] Server created, n_replica=%d, FQ=%d, SQ=%d",
           n_replica_, FastQuorum(), SlowQuorum());
}

SwiftPaxosServer::~SwiftPaxosServer() {}

// Mirrors lightKeyInfo.getConflictCmds in the reference. For a write the dep
// is "last cmd on this key" (could be a read); for a read it is "last write."
// Empty result means "no dependency" — fast path will fire trivially when all
// replicas observe the same state.
std::vector<uint64_t> SwiftPaxosServer::GetDep(key_t key, uint64_t cmd_id,
                                                bool is_write) {
  std::vector<uint64_t> dep;
  auto it = keys_.find(key);
  if (it == keys_.end()) return dep;
  const auto& info = it->second;
  if (is_write) {
    if (!info.last_cmd.empty() && info.last_cmd.front() != cmd_id) {
      dep = info.last_cmd;
    }
  } else {
    if (!info.last_write.empty() && info.last_write.front() != cmd_id) {
      dep = info.last_write;
    }
  }
  return dep;
}

void SwiftPaxosServer::TrackKey(key_t key, uint64_t cmd_id, bool is_write) {
  auto& info = keys_[key];
  info.last_cmd = {cmd_id};
  if (is_write) info.last_write = {cmd_id};
}

bool SwiftPaxosServer::DepsEqual(const std::vector<uint64_t>& a,
                                  const std::vector<uint64_t>& b) {
  if (a.size() != b.size()) return false;
  // Set-equality: dep order is not significant.
  std::vector<uint64_t> sa(a), sb(b);
  std::sort(sa.begin(), sa.end());
  std::sort(sb.begin(), sb.end());
  return sa == sb;
}

void SwiftPaxosServer::OnPropose(const shared_ptr<Marshallable>& cmd,
                                  const std::function<void()>& commit_cb) {
  if (status_ != 0) return;

  auto cmd_id = SimpleRWCommand::GetCombinedCmdID(cmd);
  auto key = SimpleRWCommand::GetKey(cmd);
  bool is_write = SimpleRWCommand(cmd).IsWrite();

  auto& desc = cmd_descs_[cmd_id];
  bool first_arrival = (desc.phase == SwiftCmdDesc::START);

  // Diagnostic: log first few entries per process to see whether OnPropose
  // sees commit_callback set on this host's local cmds.
  static thread_local int onp_log_count = 0;
  if (onp_log_count < 10) {
    Log_info("[SP-ONPROPOSE] loc_id=%d cmd_id=%llu phase_was=%d "
             "cb_set=%d commit_cb_arg=%d",
             (int)loc_id_, (unsigned long long)cmd_id, (int)desc.phase,
             desc.commit_callback ? 1 : 0,
             commit_cb ? 1 : 0);
    onp_log_count++;
  }

  if (desc.committed || desc.delivered) {
    if (commit_cb) commit_cb();
    return;
  }

  if (first_arrival) {
    desc.phase = SwiftCmdDesc::PRE_ACCEPT;
    desc.cmd = cmd;
    desc.cmd_id = cmd_id;
    desc.key = key;

    // Activate profiling on the LOCAL replica only. The local replica is
    // the one whose Coordinator::Submit ran in this process — so it has
    // already populated desc.commit_callback before broadcasting, while
    // remote replicas first see this cmd via the SwiftPropose RPC handler
    // (which calls OnPropose with commit_cb=nullptr and so leaves
    // desc.commit_callback empty until/unless this replica is the local
    // one for some other coordinator).
    if (desc.commit_callback && prof_traced_count_ < kProfTraceLimit) {
      desc.prof_active = true;
      desc.t_propose_us = NowUs();
      prof_traced_count_++;
    }
  }
  if (commit_cb && !desc.commit_callback) {
    desc.commit_callback = commit_cb;
  }

  // Compute this replica's dep BEFORE updating key tracking — the dep is
  // "what existed prior to this command."
  auto my_dep = GetDep(key, cmd_id, is_write);
  TrackKey(key, cmd_id, is_write);

  if (IsSwiftLeader() && desc.seqnum == 0) {
    desc.seqnum = ++seqnum_;
  }

  // Self-ack with my dep.
  SwiftAck ack;
  ack.replica = loc_id_;
  ack.ballot = ballot_;
  ack.cmd_id = cmd_id;
  ack.dep = my_dep;
  ack.seqnum = desc.seqnum;
  ack.is_slow = false;
  OnFastAck(ack);
  if (desc.prof_active) {
    desc.t_self_acked_us = NowUs();
  }

  // Broadcast my fast-ack (with dep) to the other replicas. They each
  // collect acks independently and the local replica that hosts the
  // coordinator will fire commit_callback when fast or slow quorum is met.
  if (commo()) {
    auto swift_commo = (SwiftPaxosCommo*)commo();
    auto config = Config::GetConfig();
    parid_t par_id = config->SiteById(site_id_).partition_id_;
    auto& proxies = swift_commo->rpc_par_proxies_[par_id];
    std::vector<rrr::i64> dep_i64(my_dep.begin(), my_dep.end());
    for (auto& p : proxies) {
      if ((int32_t)p.first == site_id_) continue;
      auto proxy = (SwiftPaxosServiceProxy*)p.second;
      auto fu = proxy->async_SwiftFastAck(loc_id_, ballot_, (int64_t)cmd_id,
                                           (int32_t)key, desc.seqnum, dep_i64);
      Future::safe_release(fu);
    }
  }
}

void SwiftPaxosServer::OnFastAck(const SwiftAck& ack) {
  auto& desc = cmd_descs_[ack.cmd_id];
  if (desc.committed || desc.delivered) return;

  // Record this replica's dep. If the same replica was already counted,
  // we keep its first vote (the protocol assumes one ack per replica).
  desc.fast_acks_by_replica.emplace(ack.replica, ack.dep);

  if (desc.prof_active && desc.t_propose_us > 0) {
    uint64_t now = NowUs();
    desc.ack_arrival_us[ack.replica] = now - desc.t_propose_us;
    if (desc.t_first_peer_ack_us == 0 && (int32_t)ack.replica != (int32_t)loc_id_) {
      desc.t_first_peer_ack_us = now - desc.t_propose_us;
    }
  }

  if ((int32_t)ack.replica == Leader()) {
    desc.leader_acked = true;
    desc.leader_dep = ack.dep;
    if (ack.seqnum > 0) desc.seqnum = ack.seqnum;
    if (desc.prof_active && desc.t_propose_us > 0 && desc.t_leader_ack_us == 0) {
      desc.t_leader_ack_us = NowUs() - desc.t_propose_us;
    }
  }

  CheckCommit(desc);
}

void SwiftPaxosServer::OnSlowAck(const SwiftAck& ack) {
  auto& desc = cmd_descs_[ack.cmd_id];
  if (desc.committed || desc.delivered) return;

  desc.slow_ack_replicas.insert(ack.replica);
  if ((int32_t)ack.replica == Leader()) {
    desc.leader_acked = true;
    desc.leader_dep = ack.dep;
  }

  CheckCommit(desc);
}

void SwiftPaxosServer::CheckCommit(SwiftCmdDesc& desc) {
  if (desc.committed) return;

  auto fire_commit = [&](bool fast) {
    desc.committed = true;
    desc.phase = SwiftCmdDesc::COMMIT;
    if (desc.prof_active && desc.t_propose_us > 0) {
      desc.t_commit_us = NowUs() - desc.t_propose_us;
      desc.committed_via_fast_path = fast;
      // Format: cid=X path=fast/slow leader_loc=L total_us=T leader_ack=A
      //         self=S first_peer=F  per_replica="r0:dt0,r1:dt1,..."
      std::ostringstream ss;
      for (auto& kv : desc.ack_arrival_us) {
        ss << kv.first << ":" << kv.second << ",";
      }
      Log_info("[SP-PROF] cid=%llu loc=%d leader=%d path=%s "
               "total_us=%llu leader_ack_us=%llu self_us=%llu "
               "first_peer_us=%llu acks=[%s]",
               (unsigned long long)desc.cmd_id,
               (int)loc_id_,
               (int)Leader(),
               fast ? "FAST" : "SLOW",
               (unsigned long long)desc.t_commit_us,
               (unsigned long long)desc.t_leader_ack_us,
               (unsigned long long)desc.t_self_acked_us,
               (unsigned long long)desc.t_first_peer_ack_us,
               ss.str().c_str());
    }
    Deliver(desc);
  };

  // Fast path: 3N/4+1 fast-acks whose dep matches the leader's dep.
  // Requires the leader's fast-ack as the dep anchor.
  if (desc.leader_acked) {
    int matching = 0;
    for (auto& kv : desc.fast_acks_by_replica) {
      if (DepsEqual(kv.second, desc.leader_dep)) matching++;
    }
    if (matching >= FastQuorum()) {
      fire_commit(true);
      return;
    }
  }

  // Slow path: leader's ack arrived AND a majority of replicas have
  // contributed any ack (fast or slow). Counts each replica at most once.
  if (!desc.leader_acked) return;
  std::set<siteid_t> all_responders = desc.slow_ack_replicas;
  for (auto& kv : desc.fast_acks_by_replica) all_responders.insert(kv.first);
  if ((int)all_responders.size() >= SlowQuorum()) {
    fire_commit(false);
    return;
  }
}

void SwiftPaxosServer::Deliver(SwiftCmdDesc& desc) {
  if (desc.delivered) return;
  desc.delivered = true;

  if (desc.cmd) {
    app_next_(*desc.cmd);
  }

  if (desc.commit_callback) {
    desc.commit_callback();
  }
}

// ============================================================
// Recovery path (Phase 2.5)
// ============================================================

void SwiftPaxosServer::OnNewLeaderRecv(siteid_t replica, ballot_t ballot) {
  if (ballot <= ballot_) return;
  Log_info("[SwiftPaxos] OnNewLeaderRecv: enter RECOVERING status, new ballot=%ld from replica=%d",
           (long)ballot, (int)replica);
  ballot_ = ballot;
  status_ = RECOVERING;
}

void SwiftPaxosServer::OnNewLeaderAckRecv(siteid_t replica, ballot_t ballot, ballot_t cballot) {
  if (ballot != ballot_) return;
  Log_info("[SwiftPaxos] OnNewLeaderAckRecv from replica=%d cballot=%ld",
           (int)replica, (long)cballot);
}

void SwiftPaxosServer::OnSyncRecv(siteid_t replica, ballot_t ballot) {
  if (ballot < ballot_) return;
  ballot_ = ballot;
  cballot_ = ballot;
  status_ = NORMAL;
  Log_info("[SwiftPaxos] OnSyncRecv: back to NORMAL, ballot=%ld", (long)ballot);
}

void SwiftPaxosServer::TriggerRecovery() {
  ballot_t new_ballot = ballot_ + n_replica_;
  new_ballot = new_ballot - (new_ballot % n_replica_) + loc_id_;
  if (new_ballot <= ballot_) new_ballot += n_replica_;

  Log_info("[SwiftPaxos] TriggerRecovery: proposing new_ballot=%ld", (long)new_ballot);
  ballot_ = new_ballot;
  status_ = RECOVERING;
}

} // namespace janus
