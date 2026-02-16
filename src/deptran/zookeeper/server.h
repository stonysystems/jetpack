#pragma once

#include "__dep__.h"
#include "constants.h"
#include "../scheduler.h"
#include "../zookeeper_kv_table_handler.h"
#include "../zookeeper_connection_thread_pool.h"
#include "../communicator.h"
#include "../frame.h"
#include "../../rrr/reactor/event.h"
#include <cstdlib>

#ifdef JETPACK_ZOOKEEPER_RECOVERY
#include "../../../jm_file_signal.h"
#endif

namespace janus {

class ZookeeperServer : public TxLogServer {

#ifdef AWS
  const int zk_connection_ = 2500;
#endif
#ifndef AWS
  const int zk_connection_ = 80;
#endif
  std::string zk_uri_{kZookeeperUri};
  shared_ptr<ZookeeperConnectionThreadPool> zk_;

 public:

  void Setup() override {
    SimpleRWCommand::SetZeroTime();
#ifdef JETPACK_ZOOKEEPER_RECOVERY
    // Leader uses default single-host URI to avoid tc/netem delay through
    // multi-host loopback IPs. Non-leaders need multi-host URI for recovery
    // signal detection across the ZK ensemble.
    if (loc_id_ == 0) {
      zk_uri_ = kZookeeperUri;
    } else {
      auto cfg = Config::GetConfig();
      auto hosts = cfg->GetReplicaHosts(partition_id_);
      if (!hosts.empty()) {
        std::ostringstream oss;
        for (size_t i = 0; i < hosts.size(); ++i) {
          if (i > 0) oss << ",";
          auto pos = hosts[i].find(':');
          if (pos != std::string::npos) {
            oss << hosts[i].substr(0, pos) << ":2181";
          } else {
            oss << hosts[i] << ":2181";
          }
        }
        zk_uri_ = oss.str();
      }
    }
    Log_info("zk_uri_:%s, loc_id_:%d, zk_connection_:%d", zk_uri_.c_str(), loc_id_, zk_connection_);
    zk_ = make_shared<ZookeeperConnectionThreadPool>(loc_id_ == 0 ? zk_connection_ : 0, zk_uri_);
#else
    zk_uri_ = kZookeeperUri;
    Log_info("zk_uri_:%s, loc_id_:%d, zk_connection_:%d", zk_uri_.c_str(), loc_id_, zk_connection_);
    zk_ = make_shared<ZookeeperConnectionThreadPool>(loc_id_ == 0 ? zk_connection_ : 0, zk_uri_);
#endif

#ifdef JETPACK_ZOOKEEPER_RECOVERY
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
        Log_info("[ZOOKEEPER-FAILOVER] Waiting for zookeeper signal on JM_Jetpack_%s", host.c_str());
        while (true) {
          if (jm_signal::exists_key("zookeeper", "primary_elected", host)) {
            Log_info("[ZOOKEEPER-FAILOVER] Received zookeeper signal on JM_Jetpack_%s", host.c_str());
            JetpackRecoveryEntry();
            break;
          }
          auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(10 * 1000); // 10ms
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
          Log_info("[WRONG_LEADER_FLOW] ZookeeperServer rejecting tx_id=%lu at loc_id=%d because status=RECOVERY",
                   tpc_cmd->tx_id_, loc_id_);
#endif
          tpc_cmd->ret_ = WRONG_LEADER;
        }
      }
      app_next_(*cmd);
      return;
    }
    WAN_WAIT
    verify(cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT);
    shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
    cmd_content->zookeeper_finished = Reactor::CreateSpEvent<ThreadSafeIntEvent>();
    auto depth = zk_->ZookeeperRequest(cmd);
    request_queues_depth_.append(static_cast<double>(depth));
    cmd_content->zookeeper_finished->Wait();
    WAN_WAIT
    RuleWitnessGC(cmd);
    app_next_(*cmd);
  }

  ~ZookeeperServer() {
    if (zk_) {
      zk_->Close();
    }
  }
};

}
