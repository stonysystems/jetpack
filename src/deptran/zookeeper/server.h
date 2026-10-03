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
#include "../jetpack_term_source.h"
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
#ifdef JETPACK_ZOOKEEPER_RECOVERY
  // Self-detection probe (only with Jetpack recovery) and the poller's
  // liveness flag (cleared by the destructor, read by the poller coroutine).
  std::shared_ptr<JetpackLeaderProbe> jp_probe_;
  std::shared_ptr<std::atomic<bool>> jp_poller_alive_;

  // Self-detection: four-letter word "srvr" to the co-located ZooKeeper
  // server: "Mode: leader" and the ZAB epoch = Zxid >> 32. Blocking socket
  // I/O, so it runs on the probe thread, never on the reactor. The current
  // epoch (T_rejoin) is a leader's srvr epoch (its zxid starts the new
  // epoch on activation); a follower's srvr Zxid is its last processed zxid,
  // possibly from an older epoch, so a restarted (amnesiac) replica reads the
  // epoch files of the server's data directory (env JETPACK_ZK_DATA_DIR)
  // instead, until it has one.
  static JetpackLeaderProbe::FnEx ZkSrvrProbe(const std::string& host, int port,
                                              bool want_current_term, const std::string& data_dir) {
    auto need_files = std::make_shared<bool>(want_current_term && !data_dir.empty());
    return [host, port, need_files, data_dir](JetpackLeaderProbe::Answer* a, std::string* err) -> bool {
      std::string reply;
      if (!JpZkFourLetter(host, port, "srvr", 1000, &reply, err)) return false;
      if (!JpZkParseSrvr(reply, &a->leader, &a->term, err)) return false;
      if (a->leader) {
        a->current_term = a->term;
      } else if (*need_files) {
        std::string ferr;
        uint64_t e = 0;
        if (JpZkDataDirEpoch(data_dir, &e, &ferr)) {
          a->current_term = e;
        }
      }
      if (a->current_term != 0) {
        *need_files = false;  // T_rejoin takes only the first one
      }
      return true;
    };
  }
#endif

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
    // Without Jetpack recovery only the static leader (loc_id_==0) submits.
    // With it the leader follows the installed view, so every replica
    // opens loc0's pool size (locales other than 0 on the multi-host URI
    // above; a ZK follower forwards writes to the ZK leader).
    const bool open_pool = loc_id_ == 0 || JetpackRecoveryEnabled();
    Log_info("zk_uri_:%s, loc_id_:%d, zk_connection_:%d", zk_uri_.c_str(), loc_id_,
             open_pool ? zk_connection_ : 0);
    zk_ = make_shared<ZookeeperConnectionThreadPool>(open_pool ? zk_connection_ : 0, zk_uri_);
#else
    zk_uri_ = kZookeeperUri;
    Log_info("zk_uri_:%s, loc_id_:%d, zk_connection_:%d", zk_uri_.c_str(), loc_id_, zk_connection_);
    zk_ = make_shared<ZookeeperConnectionThreadPool>(loc_id_ == 0 ? zk_connection_ : 0, zk_uri_);
#endif

#ifdef JETPACK_ZOOKEEPER_RECOVERY
    // Every replica runs the term poller; view id = the ZAB epoch.
    // Sources: self-detection (only with Jetpack recovery) of the co-located
    // ZooKeeper server leading a newer epoch, and term-bearing lines
    // "zookeeper:primary_elected term=E [loc=L]" (patched ZooKeeper, docker
    // harness); with recovery disabled the lines still get the leader_paused
    // ack. The startup state is a baseline, not a failover (the initial leader
    // is assumed co-located with locale 0, whose view is the initial one).
    jp_poller_alive_ = std::make_shared<std::atomic<bool>>(true);
    if (JetpackRecoveryEnabled()) {
      // The co-located server: kZookeeperUri (loc0's pool endpoint), or env
      // JETPACK_ZK_SELF_ADDR=host:port where it listens elsewhere (e.g. one
      // host running several servers on different client ports).
      std::string zk_host;
      int zk_port = 0;
      JpParseHostPort(kZookeeperUri, &zk_host, &zk_port);
      const char* self_addr = std::getenv("JETPACK_ZK_SELF_ADDR");
      if (self_addr != nullptr && *self_addr != '\0' &&
          !JpParseHostPort(self_addr, &zk_host, &zk_port)) {
        Log_warn("[ZOOKEEPER-FAILOVER] ignoring malformed JETPACK_ZK_SELF_ADDR=%s (want host:port)", self_addr);
        JpParseHostPort(kZookeeperUri, &zk_host, &zk_port);
      }
      // Where a restarted replica finds the current epoch of its server
      // while that server is a follower (see ZkSrvrProbe).
      const char* data_dir_env = std::getenv("JETPACK_ZK_DATA_DIR");
      const std::string data_dir = data_dir_env != nullptr ? data_dir_env : "";
      Log_info("[ZOOKEEPER-FAILOVER] self-detection via srvr on %s:%d (loc_id=%d%s%s)",
               zk_host.c_str(), zk_port, loc_id_, data_dir.empty() ? "" : ", data dir ",
               data_dir.c_str());
      if (jp_rejoin_.amnesiac() && data_dir.empty()) {
        Log_warn("[ZOOKEEPER-FAILOVER] [JETPACK-REJOIN] JETPACK_ZK_DATA_DIR is not set: this restarted replica "
                 "learns T_rejoin only while its ZooKeeper server leads (a follower's srvr Zxid may be from "
                 "an older epoch)");
      }
      jp_probe_ = std::make_shared<JetpackLeaderProbe>(
          "[ZOOKEEPER-FAILOVER]",
          ZkSrvrProbe(zk_host, zk_port, /*want_current_term=*/jp_rejoin_.amnesiac(), data_dir),
          JpLeaderPollMs());
      jp_probe_->Start();
    }
    {
      auto alive = jp_poller_alive_;
      auto probe = jp_probe_;
      Coroutine::CreateRun([this, alive, probe]() {
        JpRunTermPoller("[ZOOKEEPER-FAILOVER]", "zookeeper", "primary_elected", probe, alive);
      });
    }
    // Rejoin startup state (T_rejoin comes from the probe, in the poller),
    // then the takeover timer (with Jetpack recovery).
    JpLogRejoinState("[ZOOKEEPER-FAILOVER]");
    JpStartTakeoverTimer(jp_poller_alive_);
#endif
  }

  // The leader of the installed fast-path view (static locale 0 without
  // Jetpack recovery); see EtcdServer::IsLeader.
  bool IsLeader() override {
    return JpBackendIsLeader();
  }

  // Returns true iff the command is durable in ZooKeeper; see
  // EtcdServer::Submit.
  bool Submit(const shared_ptr<Marshallable>& cmd) {
    if (JpBackendBounce(cmd, "ZookeeperServer")) {
      app_next_(*cmd);
      return false;
    }
    WAN_WAIT
    verify(cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT);
    shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
    cmd_content->zookeeper_finished = Reactor::CreateSpEvent<ThreadSafeIntEvent>();
    auto depth = zk_->ZookeeperRequest(cmd);
    request_queues_depth_.append(static_cast<double>(depth));
    // Untimed: the pool always signals, 1 = done by ZooKeeper, 2 = failed.
    cmd_content->zookeeper_finished->Wait();
    const bool durable = cmd_content->zookeeper_finished->get() == 1;
    WAN_WAIT
    if (!durable) {
      // Possibly applied (e.g. a dropped connection after the write was sent):
      // keep it in the pool and let the client retry, at-least-once.
      JpMarkWrongLeader(cmd);
      app_next_(*cmd);
      return false;
    }
    RuleCommandPoolGC(cmd);
    app_next_(*cmd);
    return true;
  }

  ~ZookeeperServer() {
#ifdef JETPACK_ZOOKEEPER_RECOVERY
    if (jp_poller_alive_) jp_poller_alive_->store(false);
    if (jp_probe_) jp_probe_->Stop();
#endif
    if (zk_) {
      zk_->Close();
    }
  }
};

}
