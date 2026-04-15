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
  if (!desc.leader_acked) return;

  if (desc.fast_ack_count >= FastQuorum()) {
    desc.committed = true;
    desc.phase = SwiftCmdDesc::COMMIT;
    Deliver(desc);
    return;
  }

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

} // namespace janus
