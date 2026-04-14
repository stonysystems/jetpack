#pragma once

#include "__dep__.h"
#include "constants.h"
#include "../scheduler.h"
#include "../mongodb_kv_table_handler.h"
#include "../mongodb_connection_thread_pool.h"
#include "../communicator.h"
#include "../frame.h"
#include "../../rrr/reactor/event.h"
#include <cstdlib>

#ifdef JETPACK_MONGODB_RECOVERY
#include "../../../jm_file_signal.h"
#endif

namespace janus {

class MongodbServer : public TxLogServer {
  
#ifdef AWS
  const int mongodb_connection_ = 2500; // maximum connection maybe limited by ulimit, increase ulimit may solve connection limit problem. 2000 is designed for 0.66s latency 3000 clients open loop, change to 2500 to saturate CPU usage
#endif
#ifndef AWS
  const int mongodb_connection_ = 80; // seems maximum connextion between 95 * 5 and 100 * 5 at local
#endif
  std::string mongo_uri_{kMongoDbUri};
  shared_ptr<MongodbConnectionThreadPool> mongodb_;
  std::thread execution_thread;

  static void ExecutionHandler(MongodbServer* svr, shared_ptr<MongodbConnectionThreadPool>& db) {
    Log_info("Enter ExecutionHandler");
    while (true) { // This is not hot loop
      Log_info("db->MongodbFinishedEmpty() is %d", db->MongodbFinishedEmpty());
      while (!db->MongodbFinishedEmpty()) {
        shared_ptr<Marshallable> cmd = db->MongodbFinishedPop();
        if (cmd == nullptr) {
          Log_info("Exit ExecutionHandler for nullptr");
          break;
        }
        svr->RuleCommandPoolGC(cmd);
#ifdef MONGODB_DEBUG
        Log_info("%.2f After RuleCommandPoolGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
        svr->app_next_(*cmd);
#ifdef MONGODB_DEBUG
        Log_info("%.2f After app_next_ <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
      }
      Log_info("before Reactor::CreateSpEvent<TimeoutEvent>(5 * 1000)");
      // auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(5 * 1000);
      // sp_e->Wait();
      auto sp_e = Reactor::CreateSpEvent<NeverEvent>();
      sp_e->Wait(5);
      Log_info("After Reactor::CreateSpEvent<TimeoutEvent>(5 * 1000) wait");
    }
    Log_info("Exit ExecutionHandler");
  }

 public:

  void Setup() override { 
    SimpleRWCommand::SetZeroTime();
#ifdef JETPACK_MONGODB_RECOVERY
    // Determine Mongo URI: use only the first 3 replica hosts (matching
    // the 3-node MongoDB replica set in Docker). The Jetpack config may
    // list 5 hosts (5 Jetpack replicas), but only 3 run mongod.
    // Also set serverSelectionTryOnce=false and a generous timeout so
    // the driver retries on transient topology failures under high
    // concurrency instead of failing immediately.
    auto cfg = Config::GetConfig();
    auto hosts = cfg->GetReplicaHosts(partition_id_);
    if (!hosts.empty()) {
      const size_t mongo_nodes = std::min(hosts.size(), static_cast<size_t>(3));
      std::ostringstream oss;
      oss << "mongodb://";
      for (size_t i = 0; i < mongo_nodes; ++i) {
        if (i > 0) oss << ",";
        auto pos = hosts[i].find(':');
        if (pos != std::string::npos) {
          oss << hosts[i].substr(0, pos) << ":27017";
        } else {
          oss << hosts[i] << ":27017";
        }
      }
      oss << "/?replicaSet=jetpack-rs"
          << "&serverSelectionTryOnce=false"
          << "&serverSelectionTimeoutMS=10000";
      mongo_uri_ = oss.str();
    }
    Log_info("mongo_uri_:%s, loc_id_:%d, mongodb_connection_:%d", mongo_uri_.c_str(), loc_id_, mongodb_connection_);
    // Only the leader (loc_id_==0) needs actual MongoDB connections for writes.
    // Non-leaders use 0 connections so they don't overwhelm mongod in WAN mode.
    mongodb_ = make_shared<MongodbConnectionThreadPool>(loc_id_ == 0 ? mongodb_connection_ : 0, mongo_uri_);
#else
    // Default legacy behavior: only leader connects using the legacy fixed URI.
    mongo_uri_ = kMongoDbUri;
    Log_info("mongo_uri_:%s, loc_id_:%d, mongodb_connection_:%d", mongo_uri_.c_str(), loc_id_, mongodb_connection_);
    mongodb_ = make_shared<MongodbConnectionThreadPool>(loc_id_ == 0 ? mongodb_connection_ : 0, mongo_uri_);
#endif
    // Coroutine::CreateRun([&]() { 
    //   ExecutionHandler(this, mongodb_); 
    // });
    // execution_thread = std::thread(ExecutionHandler, this, std::ref(mongodb_));

#ifdef JETPACK_MONGODB_RECOVERY
	  // Coroutine-based waiter for MongoDB signal with periodic timeout.
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
      Log_info("[MONGODB-FAILOVER] Waiting for mongo signal on JM_Jetpack_%s", host.c_str());
        while (true) {
        if (jm_signal::exists_key("mongo", "primary_elected", host)) {
          Log_info("[MONGODB-FAILOVER] Received mongo signal on JM_Jetpack_%s", host.c_str());
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
          Log_info("[WRONG_LEADER_FLOW] MongodbServer rejecting tx_id=%lu at loc_id=%d because status=RECOVERY",
                   tpc_cmd->tx_id_, loc_id_);
#endif
          tpc_cmd->ret_ = WRONG_LEADER;
        }
      }
      app_next_(*cmd);
      return;
    }
#ifdef MONGODB_DEBUG
    Log_info("%.2f Submit <%d, %d> loc_id %d", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second, loc_id_);
#endif
    WAN_WAIT
    verify(cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT);
    shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
    cmd_content->mongodb_finished = Reactor::CreateSpEvent<ThreadSafeIntEvent>();
#ifdef MONGODB_DEBUG
    Log_info("%.2f Before MongodbRequest <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    auto depth = mongodb_->MongodbRequest(cmd);
    request_queues_depth_.append(static_cast<double>(depth));
#ifdef MONGODB_DEBUG
    Log_info("%.2f Before cmd_content->mongodb_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
//     cmd_content->mongodb_finished->Set(1);
// #ifdef MONGODB_DEBUG
//     Log_info("%.2f xxxxx <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
// #endif
    cmd_content->mongodb_finished->Wait();
#ifdef MONGODB_DEBUG
    Log_info("%.2f After cmd_content->mongodb_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    WAN_WAIT
#ifdef MONGODB_DEBUG
    Log_info("%.2f Before RuleCommandPoolGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    RuleCommandPoolGC(cmd);
#ifdef MONGODB_DEBUG
    Log_info("%.2f After RuleCommandPoolGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    app_next_(*cmd);
#ifdef MONGODB_DEBUG
    Log_info("%.2f After app_next_ <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
  }
  ~MongodbServer() {
    mongodb_->Close();
    // execution_thread.join();
  }
};
}
