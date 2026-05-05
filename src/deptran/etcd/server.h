#pragma once

#include "__dep__.h"
#include "constants.h"
#include "../scheduler.h"
#include "../etcd_kv_table_handler.h"
#include "../etcd_connection_thread_pool.h"
#include "../communicator.h"
#include "../frame.h"
#include "../../rrr/reactor/event.h"
#include <cstdlib>

#ifdef JETPACK_ETCD_RECOVERY
#include "../../../jm_file_signal.h"
#endif

namespace janus {

class EtcdServer : public TxLogServer {

#ifdef AWS
  const int etcd_connection_ = 2500;
#endif
#ifndef AWS
  const int etcd_connection_ = 80;
#endif
  std::string etcd_uri_{kEtcdUri};
  shared_ptr<EtcdConnectionThreadPool> etcd_;

 public:

  void Setup() override {
    SimpleRWCommand::SetZeroTime();
#ifdef JETPACK_ETCD_RECOVERY
    // Build etcd URI from config replica hosts for this partition.
    auto cfg = Config::GetConfig();
    auto hosts = cfg->GetReplicaHosts(partition_id_);
    if (!hosts.empty()) {
      auto pos = hosts[0].find(':');
      if (pos != std::string::npos) {
        etcd_uri_ = "http://" + hosts[0].substr(0, pos) + ":2379";
      } else {
        etcd_uri_ = "http://" + hosts[0] + ":2379";
      }
    }
    Log_info("etcd_uri_:%s, loc_id_:%d, etcd_connection_:%d", etcd_uri_.c_str(), loc_id_, etcd_connection_);
    etcd_ = make_shared<EtcdConnectionThreadPool>(etcd_connection_, etcd_uri_);
#else
    etcd_uri_ = kEtcdUri;
    Log_info("etcd_uri_:%s, loc_id_:%d, etcd_connection_:%d", etcd_uri_.c_str(), loc_id_, etcd_connection_);
    etcd_ = make_shared<EtcdConnectionThreadPool>(loc_id_ == 0 ? etcd_connection_ : 0, etcd_uri_);
#endif

#ifdef JETPACK_ETCD_RECOVERY
    if (loc_id_ != 0) {
      Coroutine::CreateRun([this]() {
        std::string host;
        if (frame_ && frame_->site_info_) {
          auto* si = frame_->site_info_;
          if (!si->host.empty()) {
            host = si->host;
          } else if (!si->proc_name.empty()) {
            host = si->proc_name;
          } else if (!si->name.empty()) {
            host = si->name;
          }
        }
#ifdef AWS
        host = "0.0.0.0";
#endif
        Log_info("[ETCD-FAILOVER] Waiting for etcd signal on JM_Jetpack_%s", host.c_str());
        while (true) {
          if (jm_signal::exists_key("etcd", "primary_elected", host)) {
            Log_info("[ETCD-FAILOVER] Received etcd signal on JM_Jetpack_%s", host.c_str());
            JetpackRecoveryEntry();
            break;
          }
          auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(1 * 1000); // 1ms (reduced from 10ms)
          sp_e->Wait();
        }
      });
    }
#endif
  }
  bool IsLeader() override {
    return loc_id_ == 0;
  }
  void Submit(const shared_ptr<Marshallable>& cmd) {
    bool is_recovery_cmd = SimpleRWCommand(cmd).IsRecoveryCommand();

    if (!is_recovery_cmd &&
        jetpack_status_ == TxLogServer::JetpackStatus::RECOVERY) {
      if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT) {
        auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
        if (tpc_cmd) {
#ifdef JETPACK_WRONG_LEADER_DEBUG
          Log_info("[WRONG_LEADER_FLOW] EtcdServer rejecting tx_id=%lu at loc_id=%d because status=RECOVERY",
                   tpc_cmd->tx_id_, loc_id_);
#endif
          tpc_cmd->ret_ = WRONG_LEADER;
        }
      }
      app_next_(*cmd);
      return;
    }
#ifdef ETCD_DEBUG
    Log_info("%.2f Submit <%d, %d> loc_id %d", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second, loc_id_);
#endif
    // The pair of WAN_WAITs bracketing EtcdRequest models etcd's internal
    // Raft round trip — the heartbeat-to-majority (read) or append-entries
    // -to-majority (write) cost that a real geo-distributed etcd cluster
    // would pay. In our cluster etcd is LAN-local, so the real cost is
    // sub-millisecond; these WAN_WAITs are what makes the simulation
    // faithful to an inter-DC deployment.
    //
    // When etcd is configured with ReadOnlyLeaseBased (server-side flag
    // ETCD_READ_ONLY_OPTION=lease) and we mirror that with
    // etcd_lease_reads: true on this side, linearizable reads are served
    // from the leader's lease-validated state without talking to
    // followers, so the leader-to-follower round doesn't happen. Skip
    // both WAN_WAITs for reads in that mode. Writes and non-lease reads
    // still pay the full round.
    auto* _cfg = Config::GetConfig();
    bool _lease_read_skip =
        (_cfg != nullptr) &&
        _cfg->GetEtcdLeaseReads() &&
        SimpleRWCommand(cmd).IsRead();
    if (!_lease_read_skip) { WAN_WAIT }
    verify(cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT);
    shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
    cmd_content->etcd_finished = Reactor::CreateSpEvent<ThreadSafeIntEvent>();
#ifdef ETCD_DEBUG
    Log_info("%.2f Before EtcdRequest <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    auto depth = etcd_->EtcdRequest(cmd);
    request_queues_depth_.append(static_cast<double>(depth));
#ifdef ETCD_DEBUG
    Log_info("%.2f Before cmd_content->etcd_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    cmd_content->etcd_finished->Wait();
#ifdef ETCD_DEBUG
    Log_info("%.2f After cmd_content->etcd_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    if (!_lease_read_skip) { WAN_WAIT }
#ifdef ETCD_DEBUG
    Log_info("%.2f Before RuleCommandPoolGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    RuleCommandPoolGC(cmd);
#ifdef ETCD_DEBUG
    Log_info("%.2f After RuleCommandPoolGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    app_next_(*cmd);
#ifdef ETCD_DEBUG
    Log_info("%.2f After app_next_ <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
  }
  ~EtcdServer() {
    if (etcd_) {
      etcd_->Close();
    }
  }
};
}
