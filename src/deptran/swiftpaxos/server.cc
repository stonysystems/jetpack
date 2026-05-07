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

  // Stash my_dep on the descriptor. We need it later when the leader's
  // FastAck arrives so we can compare (the IMDEA `neq` predicate). On a
  // remote replica this is the first time my_dep is known; on the local
  // replica it just overwrites with the same value.
  desc.my_dep = my_dep;
  desc.my_dep_set = true;

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

  // Broadcast (or enqueue) my fast-ack to the other replicas. They each
  // collect acks independently and the local replica that hosts the
  // coordinator will fire commit_callback when fast or slow quorum is met.
  SwiftAck broadcast_ack;
  broadcast_ack.replica = loc_id_;
  broadcast_ack.ballot = ballot_;
  broadcast_ack.cmd_id = cmd_id;
  broadcast_ack.dep = my_dep;
  broadcast_ack.seqnum = desc.seqnum;
  broadcast_ack.is_slow = false;
  // Carry the key so the receiver-side handler doesn't have to fish it back
  // out of the cmd descriptor (which it may not have built yet).
  broadcast_ack.key = (int32_t)key;
  EnqueueFastAck(broadcast_ack);

  // Retroactive slow-ack trigger (IMDEA's afterPropagate.Recall pattern):
  // if the leader's FastAck arrived before this Propose, MaybeSendLightSlowAck
  // was a no-op then (my_dep was unset). Now that my_dep is stashed, fire the
  // slow-ack predicate honestly. Skipped on the leader's own Propose.
  if (desc.leader_acked && !desc.slow_ack_sent && (int32_t)loc_id_ != Leader()) {
    SwiftAck synth_leader_ack;
    synth_leader_ack.replica = Leader();
    synth_leader_ack.ballot = ballot_;
    synth_leader_ack.cmd_id = cmd_id;
    synth_leader_ack.dep = desc.leader_dep;
    MaybeSendLightSlowAck(desc, synth_leader_ack);
  }
}

void SwiftPaxosServer::OnFastAck(const SwiftAck& ack) {
  auto& desc = cmd_descs_[ack.cmd_id];
  if (desc.committed || desc.delivered) return;

  // Record this replica's reported dep. emplace keeps the first vote;
  // the protocol assumes one FastAck per replica per cmd.
  desc.fast_acks_by_replica.emplace(ack.replica, ack.dep);

  if (desc.prof_active && desc.t_propose_us > 0) {
    uint64_t now = NowUs();
    desc.ack_arrival_us[ack.replica] = now - desc.t_propose_us;
    if (desc.t_first_peer_ack_us == 0 && (int32_t)ack.replica != (int32_t)loc_id_) {
      desc.t_first_peer_ack_us = now - desc.t_propose_us;
    }
  }

  // Leader's FastAck is the slow-path D-anchor and the trigger for the
  // optional double-vote (LightSlowAck). Mirrors IMDEA fastAckFromLeader.
  if ((int32_t)ack.replica == Leader()) {
    desc.leader_acked = true;
    desc.leader_dep = ack.dep;
    if (ack.seqnum > 0) desc.seqnum = ack.seqnum;
    if (desc.prof_active && desc.t_propose_us > 0 && desc.t_leader_ack_us == 0) {
      desc.t_leader_ack_us = NowUs() - desc.t_propose_us;
    }
    MaybeSendLightSlowAck(desc, ack);
  }

  CheckCommit(desc);
}

void SwiftPaxosServer::MaybeSendLightSlowAck(SwiftCmdDesc& desc,
                                              const SwiftAck& leader_ack) {
  // Predicate from IMDEA swift.go:434
  //     sendSlowAck := r.leader() != r.Id && (slow || (fast && neq))
  // Under size-only quorums (Janus default) every replica is in both FQ and
  // SQ, so `slow == true` for any non-leader → every non-leader broadcasts
  // a LightSlowAck unconditionally. We still compute `neq` honestly so this
  // code keeps working if we later switch to fixed-set quorums.
  if ((int32_t)loc_id_ == Leader()) return;
  if (desc.slow_ack_sent) return;
  if (desc.committed || desc.delivered) return;
  if (!desc.my_dep_set) return;  // we haven't pre-accepted this cmd yet

  bool fast = true;  // size-only FQ → contains every replica
  bool slow = true;  // size-only SQ → contains every replica
  bool neq = !DepsEqual(desc.my_dep, leader_ack.dep);
  if (!(slow || (fast && neq))) return;

  desc.slow_ack_sent = true;

  // Self-vote: record this replica as having adopted leader's dep on the
  // slow path. (IMDEA does the same via handleLightSlowAck called inline.)
  desc.slow_ack_replicas.insert(loc_id_);

  // Send LightSlowAck to every other replica. The wire message carries no
  // dep — the leader's FastAck already supplied it. EnqueueLightSlowAck
  // routes through the batcher when batch_enabled_ is set.
  EnqueueLightSlowAck(loc_id_, ballot_, leader_ack.cmd_id);
}

void SwiftPaxosServer::OnLightSlowAck(siteid_t replica, ballot_t ballot,
                                       uint64_t cmd_id) {
  auto& desc = cmd_descs_[cmd_id];
  if (desc.committed || desc.delivered) return;
  if (ballot != ballot_) return;  // stale or future ballot — ignore.

  desc.slow_ack_replicas.insert(replica);
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

  // Both quorum predicates require the leader's FastAck as the D-anchor —
  // until then we don't know which dep the cmd is committing on, so neither
  // matching FastAcks nor LightSlowAcks can be counted.
  if (!desc.leader_acked) return;

  // Fast path: |replicas whose FastAck dep equals leader_dep| >= FastQuorum.
  // Mirrors IMDEA's fastPathH MsgSet (acceptFastAndSlowAck filters to
  // matching deps; size threshold = r.FQ.Size()). The leader is counted
  // because its self-FastAck sits in fast_acks_by_replica with leader_dep.
  {
    int matching = 0;
    for (auto& kv : desc.fast_acks_by_replica) {
      if (DepsEqual(kv.second, desc.leader_dep)) matching++;
    }
    if (matching >= FastQuorum()) {
      fire_commit(true);
      return;
    }
  }

  // Slow path: |replicas whose vote endorses leader_dep| >= SlowQuorum,
  // where a vote endorses leader_dep iff (a) the replica's FastAck.dep
  // equals leader_dep, OR (b) the replica sent a LightSlowAck (which by
  // construction adopts leader_dep). Each replica is counted at most once.
  // Mirrors IMDEA's slowPathH MsgSet — same accept predicate, threshold
  // r.SQ.Size().
  {
    std::set<siteid_t> endorsers = desc.slow_ack_replicas;
    for (auto& kv : desc.fast_acks_by_replica) {
      if (DepsEqual(kv.second, desc.leader_dep)) endorsers.insert(kv.first);
    }
    if ((int)endorsers.size() >= SlowQuorum()) {
      fire_commit(false);
      return;
    }
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

// =====================================================================
// Recovery flow — mirrors IMDEA swift/recovery.go
// =====================================================================

shared_ptr<SwiftRecoveryState> SwiftPaxosServer::SnapshotLocalState() const {
  auto state = std::make_shared<SwiftRecoveryState>();
  for (const auto& kv : cmd_descs_) {
    const auto& desc = kv.second;
    // Skip cmds we never received a payload for — recovery merges by
    // ACCEPT/COMMIT phase, and we have no command body to replay otherwise.
    if (desc.phase == SwiftCmdDesc::START) continue;
    if (!desc.cmd) continue;
    state->cmd_ids.push_back((rrr::i64)desc.cmd_id);
    state->phases.push_back((rrr::i32)desc.phase);
    state->keys.push_back((rrr::i32)desc.key);
    std::vector<rrr::i64> dep_i64(desc.leader_dep.begin(), desc.leader_dep.end());
    if (dep_i64.empty()) {
      // Fall back to my_dep if leader's anchor was never set (PRE_ACCEPT).
      dep_i64.assign(desc.my_dep.begin(), desc.my_dep.end());
    }
    state->deps.push_back(std::move(dep_i64));
    state->cmds.emplace_back(desc.cmd);
  }
  return state;
}

void SwiftPaxosServer::InstallRecoveryState(const SwiftRecoveryState& state) {
  // Reset per-key tracking; the merged state defines the new authoritative
  // view of recent activity per key.
  keys_.clear();

  // Wipe per-cmd descriptors that aren't in the merged state. For cmds that
  // ARE in the merged state, install the recovered phase/dep and re-track
  // the key. We deliberately do not deliver here — the application layer's
  // commit_callback for any in-flight Submit is left dangling; the client
  // can resubmit if needed (matches IMDEA's "go r.ProposeChan <- propose"
  // for un-recovered cmds).
  std::set<uint64_t> in_merged;
  for (size_t i = 0; i < state.cmd_ids.size(); ++i) {
    in_merged.insert((uint64_t)state.cmd_ids[i]);
  }

  // Drop cmd descriptors that didn't make it.
  for (auto it = cmd_descs_.begin(); it != cmd_descs_.end();) {
    if (in_merged.count(it->first) == 0 && !it->second.committed) {
      it = cmd_descs_.erase(it);
    } else {
      ++it;
    }
  }

  // Install merged cmds.
  for (size_t i = 0; i < state.cmd_ids.size(); ++i) {
    uint64_t cid = (uint64_t)state.cmd_ids[i];
    auto& desc = cmd_descs_[cid];
    desc.cmd_id = cid;
    desc.key = (key_t)state.keys[i];
    desc.phase = (SwiftCmdDesc::Phase)state.phases[i];
    desc.leader_dep.assign(state.deps[i].begin(), state.deps[i].end());
    desc.leader_acked = true;
    if (!desc.cmd && i < state.cmds.size() && state.cmds[i].sp_data_) {
      desc.cmd = state.cmds[i].sp_data_;
    }
    if (desc.phase >= SwiftCmdDesc::ACCEPT) {
      // Re-track key state so subsequent cmds see the right "last cmd."
      bool is_write = false;
      if (desc.cmd) is_write = SimpleRWCommand(desc.cmd).IsWrite();
      auto& info = keys_[desc.key];
      info.last_cmd = {cid};
      if (is_write) info.last_write = {cid};
    }
    if (desc.phase == SwiftCmdDesc::COMMIT && !desc.committed) {
      desc.committed = true;
      Deliver(desc);
    }
  }
}

void SwiftPaxosServer::BroadcastNewLeader(ballot_t bal) {
  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    if ((int32_t)p.first == site_id_) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    auto fu = proxy->async_SwiftNewLeader(loc_id_, bal);
    Future::safe_release(fu);
  }
}

void SwiftPaxosServer::BroadcastSync(
    ballot_t bal, const shared_ptr<SwiftRecoveryState>& merged) {
  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    if ((int32_t)p.first == site_id_) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    MarshallDeputy md(merged);
    auto fu = proxy->async_SwiftSync(loc_id_, bal, md);
    Future::safe_release(fu);
  }
}

void SwiftPaxosServer::TriggerRecovery() {
  // Pick the smallest ballot strictly greater than the current ballot for
  // which (ballot mod N) == loc_id_. Mirrors IMDEA TriggerRecovery semantics
  // (one ballot per replica, rotating leadership).
  ballot_t new_ballot = ballot_ + 1;
  while (new_ballot % n_replica_ != (int32_t)loc_id_) ++new_ballot;
  if (new_ballot <= ballot_) new_ballot += n_replica_;

  Log_info("[SwiftPaxos] TriggerRecovery: loc=%d proposing new_ballot=%ld (was %ld)",
           (int)loc_id_, (long)new_ballot, (long)ballot_);
  ballot_ = new_ballot;
  status_ = RECOVERING;
  pending_newleader_acks_.clear();
  sync_broadcast_done_ = false;

  // Self-ack: include the candidate's own state so it can win recovery
  // alone if its state is already a superset of a majority.
  pending_newleader_acks_[loc_id_] = {cballot_, SnapshotLocalState()};
  BroadcastNewLeader(new_ballot);
}

void SwiftPaxosServer::OnNewLeaderRecv(siteid_t replica, ballot_t ballot) {
  if (ballot <= ballot_) return;  // stale or already adopted.
  Log_info("[SwiftPaxos] OnNewLeaderRecv: enter RECOVERING ballot=%ld from replica=%d",
           (long)ballot, (int)replica);
  ballot_ = ballot;
  status_ = RECOVERING;
  // Don't clear cmd_descs_ — the candidate needs our state.

  auto snapshot = SnapshotLocalState();
  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  // Unicast the ack to the candidate. proxies is a vector of (site_id, proxy).
  for (auto& p : proxies) {
    if ((int32_t)p.first != (int32_t)replica) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    MarshallDeputy md(snapshot);
    auto fu = proxy->async_SwiftNewLeaderAck(loc_id_, ballot_, cballot_, md);
    Future::safe_release(fu);
    break;
  }
}

void SwiftPaxosServer::OnNewLeaderAckRecv(
    siteid_t replica, ballot_t ballot, ballot_t cballot,
    shared_ptr<SwiftRecoveryState> state) {
  if (ballot != ballot_) return;  // stale ack from a prior recovery attempt.
  if (status_ != RECOVERING) return;
  if (sync_broadcast_done_) return;

  pending_newleader_acks_[replica] = {cballot, state};
  Log_info("[SwiftPaxos] OnNewLeaderAckRecv from replica=%d cballot=%ld (collected %d/%d)",
           (int)replica, (long)cballot,
           (int)pending_newleader_acks_.size(), (int)SlowQuorum());

  if ((int)pending_newleader_acks_.size() < SlowQuorum()) return;

  // Pick the subset reporting the maximum cballot.
  ballot_t max_cballot = -1;
  for (auto& kv : pending_newleader_acks_) {
    if (kv.second.cballot > max_cballot) max_cballot = kv.second.cballot;
  }

  // Merge: for each cmd_id that appears in any "max-cballot" reply with phase
  // ACCEPT or COMMIT, take the highest-phase entry. Mirrors IMDEA's
  // handleNewLeaderAckNs (recovery.go:67-106).
  std::map<uint64_t, size_t> best_idx;
  std::map<uint64_t, std::pair<int32_t, std::pair<int32_t, std::vector<rrr::i64>>>> best_meta;
  std::map<uint64_t, MarshallDeputy> best_cmd;
  for (auto& kv : pending_newleader_acks_) {
    if (kv.second.cballot != max_cballot) continue;
    auto& s = *kv.second.state;
    for (size_t i = 0; i < s.cmd_ids.size(); ++i) {
      int32_t phase = s.phases[i];
      if (phase != (int32_t)SwiftCmdDesc::ACCEPT &&
          phase != (int32_t)SwiftCmdDesc::COMMIT) {
        continue;
      }
      uint64_t cid = (uint64_t)s.cmd_ids[i];
      auto it = best_meta.find(cid);
      if (it == best_meta.end() || phase > it->second.first) {
        best_meta[cid] = {phase, {s.keys[i], s.deps[i]}};
        best_cmd[cid] = s.cmds[i];
      }
    }
  }

  auto merged = std::make_shared<SwiftRecoveryState>();
  for (auto& kv : best_meta) {
    merged->cmd_ids.push_back((rrr::i64)kv.first);
    merged->phases.push_back(kv.second.first);
    merged->keys.push_back(kv.second.second.first);
    merged->deps.push_back(kv.second.second.second);
    merged->cmds.push_back(best_cmd[kv.first]);
  }

  Log_info("[SwiftPaxos] sync candidate (loc=%d) merged %d cmds at max_cballot=%ld",
           (int)loc_id_, (int)merged->size(), (long)max_cballot);

  sync_broadcast_done_ = true;
  cballot_ = ballot_;
  // Install locally first so we restart in NORMAL even if the broadcast
  // races with the next message; mirrors IMDEA's r.handleSync(sync).
  InstallRecoveryState(*merged);
  status_ = NORMAL;
  last_leader_activity_ns_ = NowUs() * 1000ULL;
  BroadcastSync(ballot_, merged);
}

void SwiftPaxosServer::OnSyncRecv(siteid_t replica, ballot_t ballot,
                                   shared_ptr<SwiftRecoveryState> state) {
  if (ballot < ballot_) return;
  Log_info("[SwiftPaxos] OnSyncRecv: install %d cmds, ballot=%ld (from replica=%d)",
           (int)(state ? state->size() : 0), (long)ballot, (int)replica);
  ballot_ = ballot;
  cballot_ = ballot;
  if (state) InstallRecoveryState(*state);
  status_ = NORMAL;
  pending_newleader_acks_.clear();
  sync_broadcast_done_ = false;
  last_leader_activity_ns_ = NowUs() * 1000ULL;
}

// =====================================================================
// Phase 4 — Batching (toggleable via `batch:` field in mode YAML)
// =====================================================================

void SwiftPaxosServer::EnqueueFastAck(const SwiftAck& ack) {
  if (!batch_enabled_) {
    BroadcastFastAckDirect(ack);
    return;
  }
  pending_fast_acks_.push_back(ack);
  StartBatcherLoop();
}

void SwiftPaxosServer::EnqueueLightSlowAck(siteid_t replica, ballot_t ballot,
                                            uint64_t cmd_id) {
  if (!batch_enabled_) {
    BroadcastLightSlowAckDirect(ballot, cmd_id);
    return;
  }
  SwiftAck ack;
  ack.replica = replica;
  ack.ballot = ballot;
  ack.cmd_id = cmd_id;
  pending_slow_acks_.push_back(ack);
  StartBatcherLoop();
}

void SwiftPaxosServer::BroadcastFastAckDirect(const SwiftAck& ack) {
  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  std::vector<rrr::i64> dep_i64(ack.dep.begin(), ack.dep.end());
  for (auto& p : proxies) {
    if ((int32_t)p.first == site_id_) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    auto fu = proxy->async_SwiftFastAck(ack.replica, ack.ballot,
                                         (int64_t)ack.cmd_id, ack.key,
                                         ack.seqnum, dep_i64);
    Future::safe_release(fu);
  }
}

void SwiftPaxosServer::BroadcastLightSlowAckDirect(ballot_t ballot,
                                                    uint64_t cmd_id) {
  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    if ((int32_t)p.first == site_id_) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    auto fu = proxy->async_SwiftSlowAck(loc_id_, ballot, (int64_t)cmd_id);
    Future::safe_release(fu);
  }
}

void SwiftPaxosServer::DrainBatcher() {
  if (pending_fast_acks_.empty() && pending_slow_acks_.empty()) return;

  auto batch = std::make_shared<SwiftBatchedAcks>();
  batch->sender_replica = (rrr::i32)loc_id_;
  while (!pending_fast_acks_.empty()) {
    const auto& ack = pending_fast_acks_.front();
    batch->fa_ballots.push_back((rrr::i64)ack.ballot);
    batch->fa_cmd_ids.push_back((rrr::i64)ack.cmd_id);
    batch->fa_keys.push_back((rrr::i32)ack.key);
    batch->fa_seqnums.push_back((rrr::i64)ack.seqnum);
    batch->fa_deps.emplace_back(ack.dep.begin(), ack.dep.end());
    pending_fast_acks_.pop_front();
  }
  while (!pending_slow_acks_.empty()) {
    const auto& ack = pending_slow_acks_.front();
    batch->sa_ballots.push_back((rrr::i64)ack.ballot);
    batch->sa_cmd_ids.push_back((rrr::i64)ack.cmd_id);
    pending_slow_acks_.pop_front();
  }

  if (!commo()) return;
  auto swift_commo = (SwiftPaxosCommo*)commo();
  auto config = Config::GetConfig();
  parid_t par_id = config->SiteById(site_id_).partition_id_;
  auto& proxies = swift_commo->rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    if ((int32_t)p.first == site_id_) continue;
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    MarshallDeputy md(batch);
    auto fu = proxy->async_SwiftAcks(md);
    Future::safe_release(fu);
  }
}

void SwiftPaxosServer::OnBatchedAcks(shared_ptr<SwiftBatchedAcks> acks) {
  if (!acks) return;
  // Unpack each FastAck and dispatch through the existing OnFastAck path.
  for (size_t i = 0; i < acks->fa_cmd_ids.size(); ++i) {
    SwiftAck a;
    a.replica = (siteid_t)acks->sender_replica;
    a.ballot = (ballot_t)acks->fa_ballots[i];
    a.cmd_id = (uint64_t)acks->fa_cmd_ids[i];
    a.key = acks->fa_keys[i];
    a.seqnum = acks->fa_seqnums[i];
    a.dep.assign(acks->fa_deps[i].begin(), acks->fa_deps[i].end());
    a.is_slow = false;
    OnFastAck(a);
  }
  for (size_t i = 0; i < acks->sa_cmd_ids.size(); ++i) {
    OnLightSlowAck((siteid_t)acks->sender_replica,
                   (ballot_t)acks->sa_ballots[i],
                   (uint64_t)acks->sa_cmd_ids[i]);
  }
}

void SwiftPaxosServer::StartBatcherLoop() {
  if (batcher_started_) return;
  batcher_started_ = true;
  Coroutine::CreateRun([this]() {
    while (!shutdown_) {
      Coroutine::Sleep(BATCH_DRAIN_INTERVAL_US);
      if (shutdown_) break;
      DrainBatcher();
    }
  });
}

} // namespace janus
