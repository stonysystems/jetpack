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
#include "../jetpack_term_source.h"
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

#ifdef JETPACK_ETCD_RECOVERY
  // The co-located etcd member (the endpoint of etcd_uri_), learned once
  // at startup off the reactor; only with Jetpack recovery.
  struct JpEtcdSelf {
    std::atomic<int> state{kJpMemberLearning};  // JpEtcdMemberState
    std::atomic<uint64_t> member_id{0};
    std::atomic<uint64_t> raft_term{0};         // its raft term at startup
    std::atomic<bool> stop{false};
  };
  std::shared_ptr<JpEtcdSelf> jp_etcd_self_;
  std::thread jp_etcd_self_thread_;
  // Cleared by the destructor; the poller coroutine stops at its next tick.
  std::shared_ptr<std::atomic<bool>> jp_poller_alive_;

  // The ResponseHeader of any request names the member that served it
  // (member_id) and its raft term. Maintenance.Status would give the same
  // header, but etcd-cpp-apiv3 does not wrap it and the raw gRPC stubs need
  // C++17, so a one-key Range (head()) on our own endpoint is used. Best
  // effort: 20 attempts, 1 s gRPC deadline each, 0.5 s apart.
  static void LearnEtcdSelf(std::shared_ptr<JpEtcdSelf> self, std::string uri) {
    std::string last_err = "no attempt";
    for (int attempt = 1; attempt <= 20 && !self->stop.load(); attempt++) {
      try {
        etcd::SyncClient client(uri);
        client.set_grpc_timeout(std::chrono::milliseconds(1000));
        etcd::Response r = client.head();
        if (r.is_ok() && r.member_id() != 0) {
          self->member_id.store(r.member_id());
          self->raft_term.store(r.raft_term());
          self->state.store(kJpMemberKnown);
          Log_info("[ETCD-FAILOVER] co-located etcd member id=%llu raft_term=%llu at %s (attempt %d)",
                   (unsigned long long) r.member_id(), (unsigned long long) r.raft_term(), uri.c_str(),
                   attempt);
          return;
        }
        last_err = r.error_message();
      } catch (const std::exception& e) {
        last_err = e.what();
      }
      for (int i = 0; i < 10 && !self->stop.load(); i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
      }
    }
    if (last_err.size() > 200) last_err.resize(200);
    self->state.store(kJpMemberUnknown);
    Log_warn("[ETCD-FAILOVER] could not learn the co-located etcd member id at %s (%s): no member "
             "filter, every newer viewchange line this replica reads starts a recovery here",
             uri.c_str(), last_err.c_str());
  }
#endif

 public:

  void Setup() override {
    SimpleRWCommand::SetZeroTime();
#ifdef JETPACK_ETCD_RECOVERY
    // Every replica writes through its CO-LOCATED etcd member (a follower
    // member forwards proposals to the etcd leader). A replica that leads a
    // Jetpack view after a failover then has a live endpoint, and killing one
    // etcd member cuts off only the replica next to it, not every replica.
    // Same host rule as Config::GetReplicaHosts, for this replica's own site.
    std::string own_host;
    if (frame_ && frame_->site_info_) {
      auto* si = frame_->site_info_;
      own_host = !si->host.empty() ? si->host : si->name;
    }
    if (own_host.empty()) {
      // GetReplicaHosts lists the replicas in locale order.
      auto hosts = Config::GetConfig()->GetReplicaHosts(partition_id_);
      if (!hosts.empty()) {
        const std::string& h = hosts[loc_id_ < hosts.size() ? loc_id_ : 0];
        own_host = h.substr(0, h.find(':'));
      }
    }
    if (!own_host.empty()) {
      etcd_uri_ = "http://" + own_host + ":2379";
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
    // failover won by loc0's etcd had no coordinator at all. With a
    // machine-local signal file only the replica co-located with the new etcd
    // leader observes its viewchange. Where several replicas read one file
    // (shared /tmp: the docker harnesses, run_local_etcd_3r.sh), a member filter
    // keeps one coordinator per term: with Jetpack recovery, a replica
    // coordinates (and acks) only a viewchange whose member= is its own
    // co-located etcd member.
    jp_poller_alive_ = std::make_shared<std::atomic<bool>>(true);
    if (JetpackRecoveryEnabled()) {
      jp_etcd_self_ = std::make_shared<JpEtcdSelf>();
      jp_etcd_self_thread_ = std::thread(LearnEtcdSelf, jp_etcd_self_, etcd_uri_);
    }
    auto alive = jp_poller_alive_;
    auto self = jp_etcd_self_;
    Coroutine::CreateRun([this, alive, self]() {
      const std::string host = JpSignalHost();
      Log_info("[ETCD-FAILOVER] watching JM_Jetpack_%s for etcd view-change (loc_id=%d, member filter %s)",
               host.c_str(), loc_id_, self ? "on" : "off");
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
      uint64_t last_handled_view = 0;
      {
        uint64_t t0 = 0, n0 = 0;
        if (jm_signal::read_latest_term("etcd", host, "viewchange", &t0, &n0) &&
            t0 < jp::kBallotViewLimit) {
          last_handled_view = t0;
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
      const uint64_t startup_line_term = last_handled_view;
      // A newer line waits at most 1 s for the member id (member filter).
      uint64_t waiting_term = 0;
      auto waiting_since = std::chrono::steady_clock::now();
      uint64_t unusable_logged = 0;
      bool legacy_seen = false;
      uint64_t ticks = 0;
      while (alive->load()) {
        // T_rejoin of a restarted replica = the co-located member's raft
        // term learned at startup, raised to the startup viewchange line.
        if (jp_rejoin_.amnesiac() && !jp_rejoin_.term_known()) {
          const int st = self ? self->state.load() : (int) kJpMemberUnknown;
          if (st == kJpMemberKnown) {
            JpLearnRejoinTerm(std::max<uint64_t>(self->raft_term.load(), startup_line_term),
                              "the co-located etcd member's raft term");
          } else if (st == kJpMemberUnknown) {
            JpRejoinTermUnavailable("[ETCD-FAILOVER]", "the co-located etcd member could not be queried");
          }
        }
        // "viewchange term=6 nonce=1723... lead=9 member=9"
        uint64_t term = 0, nonce = 0;
        std::string v;
        // Strictly newer terms only: an older or repeated viewchange line
        // (the signal file is append-only) never starts a recovery.
        const bool newer = jm_signal::read_latest_term("etcd", host, "viewchange", &term, &nonce, &v) &&
                           term != 0 && term > last_handled_view;
        if (newer && term >= jp::kBallotViewLimit) {
          // No usable view id (the ballot encoding needs v < 2^31). Not
          // consumed, so it cannot block the later, real terms.
          if (term != unusable_logged) {
            unusable_logged = term;
            Log_error("[ETCD-FAILOVER] viewchange term=%lu is not a usable view id (need < 2^31): ignored",
                      (unsigned long) term);
          }
        } else if (newer) {
          const auto now = std::chrono::steady_clock::now();
          if (term != waiting_term) {
            waiting_term = term;
            waiting_since = now;
          }
          const int member_state = self ? self->state.load() : (int) kJpMemberUnknown;
          const uint64_t my_member = self ? self->member_id.load() : 0;
          const JpEtcdAction act = JpEtcdViewchangeAction(
              self != nullptr, member_state, my_member, v, (uint64_t) loc_id_,
              now - waiting_since >= std::chrono::seconds(1));
          if (act != JpEtcdAction::kWait) {
            last_handled_view = term;
            uint64_t lead = 0, member = 0;
            jm_signal::parse_uint_field(v, "lead", lead);
            const bool has_member = jm_signal::parse_uint_field(v, "member", member);
            if (act == JpEtcdAction::kNotOurs) {
              // Another replica's etcd member leads term T: that replica
              // coordinates and acks; this one neither joins nor acks.
              Log_info("[ETCD-FAILOVER] '%s' names another replica (own member=%lu loc_id=%d): "
                       "not coordinating term=%lu (member filter)",
                       v.substr(0, 160).c_str(), (unsigned long) my_member, loc_id_, (unsigned long) term);
            } else {
              if (self && has_member && member_state == kJpMemberLearning) {
                Log_warn("[ETCD-FAILOVER] co-located etcd member id still unknown after 1s: coordinating "
                         "viewchange term=%lu without the member filter", (unsigned long) term);
              }
              // Real failover: the etcd co-located with this replica is the new
              // leader, so this replica coordinates recovery for view id = the
              // etcd raft term. leaders_ holds site ids.
              Log_info("[ETCD-FAILOVER] failover view term=%lu lead=%lu loc_id=%d site_id=%d",
                       (unsigned long) term, (unsigned long) lead, loc_id_, site_id_);
              int n_rep = (int) Config::GetConfig()->GetPartitionSize(partition_id_);
              // Non-yielding: it joins the view locally (the freeze), emits the
              // term+nonce ack right after the freeze and hands the recovery to
              // the driver coroutine, so etcd's raft loop unblocks in ~ms and
              // this poller keeps acking newer terms promptly. Views and epochs
              // are written only by the recovery rules, never here.
              JetpackRecoveryEntry(View(n_rep, (int) site_id_, (epoch_t) term),
                                   /*emit_ack=*/true, nonce, /*ack_has_nonce=*/true);
            }
            // Deliberately no break: keep watching for subsequent failovers.
          }
        }
        // A legacy term-less etcd:primary_elected line (etcd_leader_watcher.h)
        // never starts a recovery; checked about once a second, warned once
        // per process.
        if (!legacy_seen && ++ticks % 1000 == 0) {
          uint64_t lt = 0;
          std::string lv;
          if (!jm_signal::read_latest_term("etcd", host, "primary_elected", &lt, nullptr, &lv) &&
              !lv.empty()) {
            legacy_seen = true;
            if (JpFirstLegacyWarning("etcd")) {
              Log_warn("[ETCD-FAILOVER] ignoring legacy term-less etcd:primary_elected on JM_Jetpack_%s: "
                       "only the patched etcd's viewchange term=T lines start a recovery", host.c_str());
            }
          }
        }
        auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(1 * 1000); // 1ms
        sp_e->Wait();
      }
    });
    // Rejoin startup state, then the takeover timer (with Jetpack recovery):
    // a recovery frozen here without progress is re-run with this replica as
    // coordinator.
    JpLogRejoinState("[ETCD-FAILOVER]");
    JpStartTakeoverTimer(jp_poller_alive_);
#endif
  }
  // The leader of the installed fast-path view (static locale 0 without
  // Jetpack recovery). It is the fast-path proposer and the only replica that
  // accepts original-path-only commands, so their placeholders land at the
  // proposer (JpBackendBounce).
  bool IsLeader() override {
    return JpBackendIsLeader();
  }
  // Returns true iff the command is durable in etcd. Only then may the
  // caller broadcast Commit (the pool GC). A bounce (RECOVERY, or an
  // original-path-only command at a non-leader) and a failed or unknown
  // backend outcome answer WRONG_LEADER with this replica's base view and
  // skip the GC.
  bool Submit(const shared_ptr<Marshallable>& cmd) {
    if (JpBackendBounce(cmd, "EtcdServer")) {
      app_next_(*cmd);
      return false;
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
    // Untimed: the pool always signals, 1 = acked by etcd, 2 = failed.
    cmd_content->etcd_finished->Wait();
#ifdef ETCD_DEBUG
    Log_info("%.2f After cmd_content->etcd_finished->Wait() <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(cmd).first, SimpleRWCommand::GetCmdID(cmd).second);
#endif
    const bool durable = cmd_content->etcd_finished->get() == 1;
    if (!_lease_read_skip) { WAN_WAIT }
    if (!durable) {
      // The write may or may not have taken effect (a deadline is ambiguous),
      // so the command stays in the pool and the client retries:
      // at-least-once on this backend.
      JpMarkWrongLeader(cmd);
      app_next_(*cmd);
      return false;
    }
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
    return true;
  }
  ~EtcdServer() {
#ifdef JETPACK_ETCD_RECOVERY
    if (jp_poller_alive_) jp_poller_alive_->store(false);
    if (jp_etcd_self_) jp_etcd_self_->stop.store(true);
    if (jp_etcd_self_thread_.joinable()) jp_etcd_self_thread_.join();
#endif
    if (etcd_) {
      etcd_->Close();
    }
  }
};
}
