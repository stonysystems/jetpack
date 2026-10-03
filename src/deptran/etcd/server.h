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
    // Route 2a. The poller runs on EVERY replica, not just loc_id_ != 0: nobody
    // knows in advance whose etcd wins an election, and the old guard meant a
    // failover won by loc0's etcd had no coordinator at all. The signal file is
    // MACHINE-LOCAL, so only the replica co-located with the new etcd leader
    // ever observes a viewchange -> exactly one recovery coordinator.
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
      Log_info("[ETCD-FAILOVER] watching JM_Jetpack_%s for etcd view-change (loc_id=%d)",
               host.c_str(), loc_id_);
      // Establish the baseline ONCE, from what is already on disk at startup --
      // not from the first viewchange that happens to arrive later.
      //
      // Suppressing "the first viewchange I ever see" does not suit a replica
      // whose etcd was not the startup leader: it has no viewchange at all
      // until a failover promotes it, so its first-ever viewchange IS the
      // failover and would be taken as the baseline, and recovery would not
      // run on the only replica that can coordinate it.
      //
      // This assumes deptran starts after the etcd cluster is healthy, which is
      // what every launch path does (scripts/start_etcd_cluster.sh waits for
      // health before deptran comes up).
      epoch_t last_handled_view = 0;
      {
        std::string v0 = jm_signal::read_latest_value("etcd", host, "viewchange");
        if (!v0.empty()) {
          uint64_t t0 = 0, n0 = 0;
          jm_signal::parse_uint_field(v0, "term", t0);
          jm_signal::parse_uint_field(v0, "nonce", n0);
          last_handled_view = (epoch_t) t0;
          // Our co-located etcd led the startup election. Nothing failed, so no
          // recovery -- but still ack, because that etcd may be sitting in its
          // view barrier waiting for us.
          jm_signal::set_key("jetpack",
              "leader_paused term=" + std::to_string(t0) +
              " nonce=" + std::to_string(n0), host);
          Log_info("[ETCD-FAILOVER] baseline term=%lu from startup election (loc_id=%d), acked, no recovery",
                   (unsigned long) t0, loc_id_);
        } else {
          Log_info("[ETCD-FAILOVER] no viewchange at startup (loc_id=%d): co-located etcd is not "
                   "the startup leader, so any viewchange from here is a real failover", loc_id_);
        }
      }
      while (true) {
        // "viewchange term=6 nonce=1723... lead=9 member=9"
        std::string v = jm_signal::read_latest_value("etcd", host, "viewchange");
        if (!v.empty()) {
          uint64_t term = 0, nonce = 0, lead = 0;
          jm_signal::parse_uint_field(v, "term", term);
          jm_signal::parse_uint_field(v, "nonce", nonce);
          jm_signal::parse_uint_field(v, "lead", lead);
          if (term != 0 && (epoch_t) term != last_handled_view) {
            last_handled_view = (epoch_t) term;
            // Real failover: the etcd co-located with this replica is the new
            // leader, so this replica coordinates recovery.
            Log_info("[ETCD-FAILOVER] failover view term=%lu lead=%lu loc_id=%d site_id=%d",
                     (unsigned long) term, (unsigned long) lead, loc_id_, site_id_);
            int n_rep = (int) Config::GetConfig()->GetPartitionSize(partition_id_);
            old_view_ = new_view_;
            // leaders_ holds site ids (OnJetpackBeginRecovery compares
            // GetLeader() against site_id_), and this replica is the one
            // co-located with the new etcd leader. Stamping view_id_ with the
            // real raft term is what makes Communicator::UpdatePartitionView
            // accept the view at all -- it only takes strictly higher ids, so
            // the old always-zero view was silently dropped every time.
            new_view_ = View(n_rep, (int) site_id_, (epoch_t) term);
            if ((epoch_t) term > oepoch_) oepoch_ = (epoch_t) term;
            // The term+nonce ack is emitted inside, right after RECOVERY is set
            // and before the multi-phase protocol runs, so etcd's raft loop
            // unblocks in ~ms and the recovery's own resubmits (which replay
            // through etcd) are never blocked.
            JetpackRecoveryEntry((epoch_t) term, nonce);
            // Deliberately no break: keep watching for subsequent failovers.
          }
        }
        auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(1 * 1000); // 1ms
        sp_e->Wait();
      }
    });
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
