#pragma once

#include "__dep__.h"
#include "constants.h"
#include "../scheduler.h"
#include "../mongodb_kv_table_handler.h"
#include "../mongodb_connection_thread_pool.h"
#include "../communicator.h"
#include <cstdlib>

namespace janus {

class MongodbServer : public TxLogServer {
  
#ifdef AWS
  const int mongodb_connection_ = 2000; // maximum connection maybe limited by ulimit, increase ulimit may solve connection limit problem. 2000 is designed for 0.66s latency 3000 clients open loop
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
        svr->RuleWitnessGC(cmd);
#ifdef MONGODB_DEBUG
        Log_info("%.2f After RuleWitnessGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
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
    // Determine Mongo URI: prefer env override, else co-located host, else loopback.
    if (frame_ && frame_->site_info_) {
      std::string host;
      if (!frame_->site_info_->host.empty()) {
        host = frame_->site_info_->host;
      } else if (!frame_->site_info_->proc_name.empty()) {
        host = frame_->site_info_->proc_name;
      } else if (!frame_->site_info_->name.empty()) {
        host = frame_->site_info_->name;
      }
      if (!host.empty()) {
        mongo_uri_ = "mongodb://" + host + ":27017";
      }
    }
    const char* env_uri = std::getenv("JM_MONGODB_URI");
    if (env_uri && *env_uri) {
      mongo_uri_ = env_uri;
    }
    mongodb_ = make_shared<MongodbConnectionThreadPool>(mongodb_connection_, mongo_uri_);
#else
    // Default legacy behavior: only leader connects using the legacy fixed URI.
    mongo_uri_ = kMongoDbUri;
    mongodb_ = make_shared<MongodbConnectionThreadPool>(loc_id_ == 0 ? mongodb_connection_ : 0, mongo_uri_);
#endif
    // Coroutine::CreateRun([&]() { 
    //   ExecutionHandler(this, mongodb_); 
    // });
    // execution_thread = std::thread(ExecutionHandler, this, std::ref(mongodb_));
  }
  bool IsLeader() override {
    return loc_id_ == 0;
  }
  void Submit(const shared_ptr<Marshallable>& cmd) {
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
    mongodb_->MongodbRequest(cmd);
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
    Log_info("%.2f Before RuleWitnessGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    RuleWitnessGC(cmd);
#ifdef MONGODB_DEBUG
    Log_info("%.2f After RuleWitnessGC <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
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
