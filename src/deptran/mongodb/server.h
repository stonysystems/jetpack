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
#include "../jetpack_term_source.h"
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
#ifdef JETPACK_MONGODB_RECOVERY
  // Self-detection probe (only with Jetpack recovery) and the poller's
  // liveness flag (cleared by the destructor, read by the poller coroutine).
  std::shared_ptr<JetpackLeaderProbe> jp_probe_;
  std::shared_ptr<std::atomic<bool>> jp_poller_alive_;

  // Self-detection: `hello` on the co-located mongod (JpMongoHelloTerm:
  // isWritablePrimary and the replica-set term). Runs on the probe thread with
  // its own client: a mongocxx::client must not be shared between threads.
  // A driver exception (mongod down) is a failed probe. The current term
  // (T_rejoin) is a primary's electionId term; on a secondary hello only has
  // its last write's term, so a restarted (amnesiac) replica also asks
  // replSetGetStatus for the term this member knows, until it has one.
  static JetpackLeaderProbe::FnEx MongoHelloProbe(const std::string& uri, bool want_current_term) {
    auto client = std::make_shared<std::unique_ptr<mongocxx::client>>();
    auto need_status = std::make_shared<bool>(want_current_term);
    return [uri, client, need_status](JetpackLeaderProbe::Answer* a, std::string* err) -> bool {
      (void) err;
      GetMongoInstance();
      if (!*client) {
        client->reset(new mongocxx::client(mongocxx::uri(uri)));
      }
      bsoncxx::document::value cmd =
          bsoncxx::builder::stream::document{} << "hello" << 1 << bsoncxx::builder::stream::finalize;
      bsoncxx::document::value reply = (**client)["admin"].run_command(cmd.view());
      // A standalone mongod reports term 0: it never baselines and never
      // triggers, which is right, since it has no failover.
      bool from_election_id = false;
      a->term = JpMongoHelloTerm(reply.view(), &a->leader, &from_election_id);
      if (a->leader && from_election_id) {
        a->current_term = a->term;
      }
      if (*need_status) {
        try {
          bsoncxx::document::value st_cmd = bsoncxx::builder::stream::document{}
                                            << "replSetGetStatus" << 1 << bsoncxx::builder::stream::finalize;
          bsoncxx::document::value st = (**client)["admin"].run_command(st_cmd.view());
          a->current_term = std::max<uint64_t>(a->current_term, JpMongoStatusTerm(st.view()));
        } catch (const std::exception&) {
          // No status (e.g. a standalone mongod): the current term stays unknown.
        }
        if (a->current_term != 0) {
          *need_status = false;  // T_rejoin takes only the first one
        }
      }
      return true;
    };
  }
#endif

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
    // Camera-ready / AWS deployment:
    //   Each of server0..server4 runs its own mongod, all in one replica set
    //   (jetpack-rs) with server0 = PRIMARY (enforced by
    //   start_mongodb_cluster.sh's stepDown loop, plus member[0].priority=2.0
    //   from init_mongodb_replicaset.sh). Without Jetpack recovery only
    //   loc_id_==0 (server0) opens driver connections (see below for the
    //   Jetpack case); all replication to followers happens server-side
    //   via the replica-set channel using public IPs in rs.config.
    //
    //   We connect via 127.0.0.1 with directConnection=true because:
    //     1. AWS EC2 instances cannot reach their own public IP from inside
    //        the instance (the public IP is NAT'd; binding fails). Connecting
    //        to "<my_public_ip>:27017" yielded "connection error calling hello"
    //        on the first prep run.
    //     2. Replica-set discovery on a multi-host seed list would still
    //        re-resolve members from rs.config — i.e. back to public IPs that
    //        the driver tried to reach via its own public IP. Avoiding
    //        discovery sidesteps this entirely.
    //     3. The local mongod IS the primary (start_mongodb_cluster.sh enforces
    //        this), so directConnection=true is safe — we know the seed is
    //        the right target. If a future re-election lands the primary
    //        elsewhere, mongod itself will reject the request with a
    //        NotMaster error rather than serve stale state.
    // serverSelectionTryOnce=false + 10s timeout — without these, the mongo C
    // driver defaults serverSelectionTryOnce=true and refuses to retry on the
    // brief window after `systemctl restart mongod` when 2500 pool connections
    // open in parallel. Observed empirically: mongosh from the same host
    // succeeds with this URI but the C++ driver fails ~"connection error
    // calling hello" without these retry knobs. Mirror the values the original
    // (replicaSet) URI builder used.
    mongo_uri_ = "mongodb://127.0.0.1:27017/?directConnection=true"
                 "&serverSelectionTryOnce=false"
                 "&serverSelectionTimeoutMS=10000"
                 "&" JANUS_MONGO_LINEARIZABLE_OPTS;
    // Without Jetpack recovery only the static leader (loc_id_==0) submits, so
    // the others use 0 connections and do not overwhelm mongod in WAN mode.
    // With it the leader follows the installed view, so every replica
    // opens loc0's pool to its local mongod. directConnection means only the
    // replica next to the primary can write; elsewhere mongod refuses and the
    // Submit fails (it answers WRONG_LEADER), which is the natural fencing.
    const bool open_pool = loc_id_ == 0 || JetpackRecoveryEnabled();
    Log_info("mongo_uri_:%s, loc_id_:%d, mongodb_connection_:%d", mongo_uri_.c_str(), loc_id_,
             open_pool ? mongodb_connection_ : 0);
    mongodb_ = make_shared<MongodbConnectionThreadPool>(open_pool ? mongodb_connection_ : 0, mongo_uri_);
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
    // Every replica runs the term poller (nobody knows in advance whose
    // mongod wins an election). View id = the replica-set term. Sources:
    //  - self-detection (only with Jetpack recovery): the co-located mongod,
    //    the one this replica's pool writes to, is the writable primary of a
    //    newer term; so the coordinator, and with it the leader of the view
    //    it installs, sits next to the primary (directConnection: only that
    //    replica's Submits can write);
    //  - term-bearing lines "mongo:primary_elected term=T [loc=L]" (patched
    //    mongod, docker harness, simulation, MongodbLeaderWatcher); with
    //    recovery disabled they still get the leader_paused ack.
    // The startup state is a baseline, not a failover (the initial primary is
    // assumed co-located with locale 0, whose view is the initial one).
    jp_poller_alive_ = std::make_shared<std::atomic<bool>>(true);
    if (JetpackRecoveryEnabled()) {
      // The mongod of mongo_uri_, with short timeouts of its own.
      const std::string probe_uri =
          "mongodb://127.0.0.1:27017/?directConnection=true"
          "&connectTimeoutMS=1000&socketTimeoutMS=1000&serverSelectionTimeoutMS=1000";
      jp_probe_ = std::make_shared<JetpackLeaderProbe>(
          "[MONGODB-FAILOVER]", MongoHelloProbe(probe_uri, /*want_current_term=*/jp_rejoin_.amnesiac()),
          JpLeaderPollMs());
      jp_probe_->Start();
    }
    {
      auto alive = jp_poller_alive_;
      auto probe = jp_probe_;
      Coroutine::CreateRun([this, alive, probe]() {
        JpRunTermPoller("[MONGODB-FAILOVER]", "mongo", "primary_elected", probe, alive);
      });
    }
    // Rejoin startup state (T_rejoin comes from the probe, in the poller),
    // then the takeover timer (with Jetpack recovery). A takeover runs only
    // next to the primary of the frozen term (JpTakeoverAllowedHere), since
    // only that replica can write (directConnection).
    JpLogRejoinState("[MONGODB-FAILOVER]");
    JpStartTakeoverTimer(jp_poller_alive_);
#endif

  }
  // The leader of the installed fast-path view (static locale 0 without
  // Jetpack recovery); see EtcdServer::IsLeader.
  bool IsLeader() override {
    return JpBackendIsLeader();
  }
#ifdef JETPACK_MONGODB_RECOVERY
  // Takeover on MongoDB: only the replica next to the primary can write
  // (directConnection), so a takeover of view v installs a leader that can
  // write only if its co-located mongod is the primary of term v. Elsewhere it
  // would leave the partition READY behind a leader whose writes all fail
  // (with an empty recovery set nothing even fails before FinishRecovery).
  bool JpTakeoverAllowedHere(epoch_t v, std::string* why) override {
    if (!jp_probe_) {
      *why = "no self-detection probe";
      return false;
    }
    return JpProbeLeadsTerm(jp_probe_->Latest(), v, why);
  }
#endif
  // Returns true iff the command is durable in MongoDB; see
  // EtcdServer::Submit.
  bool Submit(const shared_ptr<Marshallable>& cmd) {
    if (JpBackendBounce(cmd, "MongodbServer")) {
      app_next_(*cmd);
      return false;
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
    // Untimed: the pool always signals, 1 = acked by mongod, 2 = failed.
    cmd_content->mongodb_finished->Wait();
#ifdef MONGODB_DEBUG
    Log_info("%.2f After cmd_content->mongodb_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    const bool durable = cmd_content->mongodb_finished->get() == 1;
    WAN_WAIT
    if (!durable) {
      // Possibly applied (e.g. a w:majority timeout): keep it in the pool and
      // let the client retry, at-least-once.
      JpMarkWrongLeader(cmd);
      app_next_(*cmd);
      return false;
    }
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
    return true;
  }
  ~MongodbServer() {
#ifdef JETPACK_MONGODB_RECOVERY
    if (jp_poller_alive_) jp_poller_alive_->store(false);
    if (jp_probe_) jp_probe_->Stop();
#endif
    mongodb_->Close();
    // execution_thread.join();
  }
};
}
