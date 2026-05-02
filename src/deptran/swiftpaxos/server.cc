#include "server.h"
#include "commo.h"
#include "../config.h"
#include "../RW_command.h"

namespace janus {

SwiftPaxosServer::SwiftPaxosServer(Frame* frame)
    : TxLogServer() {
  auto config = Config::GetConfig();
  n_replica_ = config->GetPartitionSize(0);
  Log_info("[SwiftPaxos] Server created, n_replica=%d, FQ=%d, SQ=%d",
           n_replica_, FastQuorum(), SlowQuorum());
}

SwiftPaxosServer::~SwiftPaxosServer() {}

bool SwiftPaxosServer::HasConflict(key_t key, uint64_t cmd_id) {
  auto it = keys_.find(key);
  if (it == keys_.end()) return false;
  return it->second.last_write_cmd_id != 0 && it->second.last_write_cmd_id != cmd_id;
}

void SwiftPaxosServer::TrackKey(key_t key, uint64_t cmd_id, bool is_write) {
  auto& info = keys_[key];
  info.last_cmd_id = cmd_id;
  if (is_write) {
    info.last_write_cmd_id = cmd_id;
  }
}

void SwiftPaxosServer::OnPropose(const shared_ptr<Marshallable>& cmd,
                                  const std::function<void()>& commit_cb) {
  if (status_ != 0) return;

  auto cmd_id = SimpleRWCommand::GetCombinedCmdID(cmd);
  auto key = SimpleRWCommand::GetKey(cmd);
  bool is_write = SimpleRWCommand(cmd).IsWrite();

  auto& desc = cmd_descs_[cmd_id];
  if (desc.committed || desc.delivered) {
    // Already done
    if (commit_cb) commit_cb();
    return;
  }

  if (desc.phase == SwiftCmdDesc::START) {
    desc.phase = SwiftCmdDesc::PRE_ACCEPT;
    desc.cmd = cmd;
    desc.cmd_id = cmd_id;
    desc.key = key;
  }
  if (commit_cb && !desc.commit_callback) {
    desc.commit_callback = commit_cb;
  }

  // Check for conflicts
  bool has_conflict = HasConflict(key, cmd_id);

  // Track this key
  TrackKey(key, cmd_id, is_write);

  // Assign sequence number if leader
  if (IsSwiftLeader() && desc.seqnum == 0) {
    desc.seqnum = ++seqnum_;
  }

  // Self-ack: this replica's response to the propose
  SwiftAck ack;
  ack.replica = loc_id_;
  ack.ballot = ballot_;
  ack.cmd_id = cmd_id;
  ack.key = key;
  ack.seqnum = desc.seqnum;
  ack.is_slow = has_conflict;

  if (has_conflict) {
    OnSlowAck(ack);
  } else {
    OnFastAck(ack);
  }

  // Broadcast ack to all OTHER replicas via RPC (real inter-replica consensus).
  // Each replica is responsible for sending its own FastAck/SlowAck to every
  // other replica in the partition. This is the actual SwiftPaxos protocol —
  // the coordinator only triggers the propose; the replicas exchange acks.
  if (commo()) {
    auto swift_commo = (SwiftPaxosCommo*)commo();
    auto config = Config::GetConfig();
    parid_t par_id = config->SiteById(site_id_).partition_id_;
    auto& proxies = swift_commo->rpc_par_proxies_[par_id];
    for (auto& p : proxies) {
      // Don't send to self (self-ack already processed above)
      if ((int32_t)p.first == site_id_) continue;
      auto proxy = (SwiftPaxosServiceProxy*)p.second;
      if (has_conflict) {
        auto fu = proxy->async_SwiftSlowAck(loc_id_, ballot_, (int64_t)cmd_id);
        Future::safe_release(fu);
      } else {
        auto fu = proxy->async_SwiftFastAck(loc_id_, ballot_, (int64_t)cmd_id,
                                             (int32_t)key, desc.seqnum);
        Future::safe_release(fu);
      }
    }
  }
}

void SwiftPaxosServer::OnFastAck(const SwiftAck& ack) {
  auto& desc = cmd_descs_[ack.cmd_id];
  if (desc.committed || desc.delivered) return;

  desc.fast_ack_count++;
  if ((int32_t)ack.replica == Leader()) {
    desc.leader_acked = true;
    if (ack.seqnum > 0) desc.seqnum = ack.seqnum;
  }

  CheckCommit(desc);
}

void SwiftPaxosServer::OnSlowAck(const SwiftAck& ack) {
  auto& desc = cmd_descs_[ack.cmd_id];
  if (desc.committed || desc.delivered) return;

  desc.slow_ack_count++;
  if ((int32_t)ack.replica == Leader()) {
    desc.leader_acked = true;
    if (ack.seqnum > 0) desc.seqnum = ack.seqnum;
  }

  CheckCommit(desc);
}

void SwiftPaxosServer::CheckCommit(SwiftCmdDesc& desc) {
  if (desc.committed) return;

  // Fast path: 3*N/4+1 fast-acks, leader-independent (true SwiftPaxos 1-RTT).
  if (desc.fast_ack_count >= FastQuorum()) {
    desc.committed = true;
    desc.phase = SwiftCmdDesc::COMMIT;
    Deliver(desc);
    return;
  }

  // Slow path: needs leader's ordering before classic majority commit.
  if (!desc.leader_acked) return;
  int total_acks = desc.fast_ack_count + desc.slow_ack_count;
  if (total_acks >= SlowQuorum()) {
    desc.committed = true;
    desc.phase = SwiftCmdDesc::COMMIT;
    Deliver(desc);
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
  // A replica is proposing to become the new leader with a higher ballot.
  if (ballot <= ballot_) {
    // Stale request, ignore
    return;
  }
  Log_info("[SwiftPaxos] OnNewLeaderRecv: enter RECOVERING status, new ballot=%ld from replica=%d",
           (long)ballot, (int)replica);
  ballot_ = ballot;
  status_ = RECOVERING;
  // Stop processing new proposals. Pending commands stay in cmd_descs_
  // until the new leader sends a Sync message.
}

void SwiftPaxosServer::OnNewLeaderAckRecv(siteid_t replica, ballot_t ballot, ballot_t cballot) {
  // This replica (as the new leader candidate) is receiving state from other replicas.
  if (ballot != ballot_) return;  // stale
  // In the full SwiftPaxos spec, we would collect cmd_ids+phases+cmds+deps from each ack,
  // find the highest cballot group, merge, and broadcast Sync.
  // For the simplified implementation: just track that we received the ack.
  // When we have majority (SlowQuorum), broadcast Sync.
  Log_info("[SwiftPaxos] OnNewLeaderAckRecv from replica=%d cballot=%ld",
           (int)replica, (long)cballot);
  // (Counting logic would be added with full RPC implementation)
}

void SwiftPaxosServer::OnSyncRecv(siteid_t replica, ballot_t ballot) {
  // Apply the synced state and return to NORMAL operation.
  if (ballot < ballot_) return;
  ballot_ = ballot;
  cballot_ = ballot;
  status_ = NORMAL;
  Log_info("[SwiftPaxos] OnSyncRecv: back to NORMAL, ballot=%ld", (long)ballot);
}

void SwiftPaxosServer::TriggerRecovery() {
  // This replica proposes itself as the new leader.
  ballot_t new_ballot = ballot_ + n_replica_;  // ensure new_ballot % n_replica_ == loc_id_
  new_ballot = new_ballot - (new_ballot % n_replica_) + loc_id_;
  if (new_ballot <= ballot_) new_ballot += n_replica_;

  Log_info("[SwiftPaxos] TriggerRecovery: proposing new_ballot=%ld", (long)new_ballot);
  ballot_ = new_ballot;
  status_ = RECOVERING;

  // In full implementation: broadcast SwiftNewLeader RPC to all replicas.
  // The service handler will call OnNewLeaderRecv on each receiving replica.
  // When quorum of NewLeaderAck replies are received, broadcast SwiftSync
  // and return to NORMAL on all replicas.
  // For the current simplified implementation, this is a no-op stub.
}

} // namespace janus
