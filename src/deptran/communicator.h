#pragma once

#include "__dep__.h"
#include "constants.h"
#include "msg.h"
#include "config.h"
#include "command_marshaler.h"
#include "procedure.h"
#include "deptran/rcc/dep_graph.h"
#include "rcc_rpc.h"
#include <unordered_map>

namespace janus {

// Runtime-configurable WAN delay (microseconds). Set via WAN_DELAY_MS env var
// or enabled at compile time with -DSIMULATE_WAN (defaults to 20ms).
// 0 means disabled (no delay).
extern std::atomic<uint64_t> wan_delay_us;

// Runtime-configurable core to pin server threads to and sample /proc/stat
// for. Set via SERVER_CORE_ID env var (default 1). Also used to derive which
// core client threads should skip to avoid stomping on the server.
extern std::atomic<int> server_core_id;

static void _wan_wait() {
  uint64_t delay = wan_delay_us.load(std::memory_order_relaxed);
  if (delay > 0) {
    Reactor::CreateSpEvent<NeverEvent>()->Wait(delay);
  }
}

// Colocation-aware variant of _wan_wait. Skips the simulated WAN delay when
// the peer site (by siteid) resolves to the same physical host as this
// process. Use at RPC dispatch / response-handler sites where the
// source->destination pair is known, so that client<->leader hops between
// colocated sites don't pay a fake 20 ms per _wan_wait call.
static void _wan_wait_to_site(siteid_t peer_site_id) {
  uint64_t delay = wan_delay_us.load(std::memory_order_relaxed);
  if (delay == 0) return;
  auto* cfg = Config::GetConfig();
  if (cfg != nullptr && cfg->IsSiteLocal(peer_site_id)) return;
  Reactor::CreateSpEvent<NeverEvent>()->Wait(delay);
}

#define WAN_WAIT _wan_wait();
#define WAN_WAIT_TO(peer_site_id) _wan_wait_to_site(peer_site_id);


class Coordinator;
class ClassicProxy;
class ClientControlProxy;
class TxLogServer;
class TpcBatchCommand;

typedef std::pair<siteid_t, ClassicProxy*> SiteProxyPair;
typedef std::pair<siteid_t, ClientControlProxy*> ClientSiteProxyPair;

class MessageEvent : public IntEvent {
 public:
  shardid_t shard_id_;
  svrid_t svr_id_;
  string msg_;
  MessageEvent(svrid_t svr_id) : IntEvent(), svr_id_(svr_id) {

  }

  MessageEvent(shardid_t shard_id, svrid_t svr_id)
      : IntEvent(), shard_id_(shard_id), svr_id_(svr_id) {

  }
};

class GetLeaderQuorumEvent : public QuorumEvent {
 public:
  using QuorumEvent::QuorumEvent;
  void FeedResponse(bool y, locid_t leader_id) {
    if (y) {
      leader_id_ = leader_id;
      VoteYes();
    } else {
      VoteNo();
    }
  }

  bool No() override { return n_voted_no_ == n_total_; }

  bool IsReady() override {
    if (Yes()) {
      return true;
    } else if (No()) {
      return true;
    }

    return false;
  }
};

/************************RULE begin*********************************/

class RuleSpeculativeExecuteQuorumEvent: public QuorumEvent {
  bool has_result_ = false;
  value_t result_;
  int num_leader_{0};
  int n_leader_yes_{0};
  int n_leader_no_{0};
  double total_cpu_usage_{0.0};
  double leader_cpu_usage_{0.0};
  int cpu_samples_{0};
  int leader_cpu_samples_{0};
  double leader_queue_depth_sum_{0.0};
  int leader_queue_samples_{0};
 public:
  RuleSpeculativeExecuteQuorumEvent(int n_total, int quorum, int num_leader)
    : QuorumEvent(n_total, quorum) {
      num_leader_ = num_leader;
  }
  void FeedResponse(bool y, value_t result, bool is_leader, double cpu_usage, double queue_depth);
  // Stats-only variant used by the fused-RPC (merge_leader_rpc) path: the
  // leader's fused reply carries cpu_usage / queue_depth / is_leader like
  // any spec response, but the leader is NOT a voter in this event
  // (see BroadcastRuleSpeculativeExecuteSkipLeader). This routes the
  // sample into the same totals as FeedResponse without calling VoteYes
  // or touching the quorum counter, so the adaptive controller gets a
  // live signal on the leader's CPU in merge mode.
  void FeedStatsOnly(bool is_leader, double cpu_usage, double queue_depth) {
    if (cpu_usage >= 0.0) {
      total_cpu_usage_ += cpu_usage;
      cpu_samples_++;
      if (is_leader) {
        leader_cpu_usage_ += cpu_usage;
        leader_cpu_samples_++;
      }
    }
    if (queue_depth >= 0.0 && is_leader) {
      leader_queue_depth_sum_ += queue_depth;
      leader_queue_samples_++;
    }
  }
  bool Yes() override;
  bool No() override;
  value_t GetResult();
  double AvgCpuAll() const { return cpu_samples_ > 0 ? total_cpu_usage_ / cpu_samples_ : 0.0; }
  double AvgCpuLeaders() const { return leader_cpu_samples_ > 0 ? leader_cpu_usage_ / leader_cpu_samples_ : 0.0; }
  double LeaderQueueDepth() const {
    return leader_queue_samples_ > 0 ? leader_queue_depth_sum_ / leader_queue_samples_ : -1.0;
  }
};

// Jetpack recovery quorum events. Each recovery round creates
// fresh events and the RPC callbacks capture only that round's event, so a
// late reply from an earlier round can never count in a later one. Every
// reply is kept: the recovery value is computed after the quorum, not on the
// fly. An RPC error votes No.
class JetpackPullRecoveryQuorumEvent: public QuorumEvent {
 public:
  struct Reply {
    siteid_t site = 0;
    bool ok = false;
    epoch_t view_id = 0;   // replier's installed fast-path view
    epoch_t vid = 0;       // newest view the replier joined or installed
    ballot_t promised = -1;
    shared_ptr<KeyCmdBatchData> acked;               // acked pool entries (ok only)
    shared_ptr<JetpackAcceptedMapData> accepted;     // acceptor state (ok only)
  };
  using QuorumEvent::QuorumEvent;
  std::vector<Reply> replies_;
  int n_errors_ = 0;

  void Feed(Reply r) {
    bool y = r.ok;
    replies_.push_back(std::move(r));
    if (y) {
      VoteYes();
    } else {
      VoteNo();
    }
  }
  void FeedError() {
    n_errors_++;
    VoteNo();
  }
};

class JetpackAcceptQuorumEvent: public QuorumEvent {
 public:
  struct Reply {
    siteid_t site = 0;
    bool ok = false;
    epoch_t view_id = 0;
    epoch_t vid = 0;
    ballot_t promised = -1;
  };
  using QuorumEvent::QuorumEvent;
  std::vector<Reply> replies_;
  int n_errors_ = 0;

  void Feed(const Reply& r) {
    replies_.push_back(r);
    if (r.ok) {
      VoteYes();
    } else {
      VoteNo();
    }
  }
  void FeedError() {
    n_errors_++;
    VoteNo();
  }
};

// FinishRecovery(v): a reply is a yes iff the replica applied FR(v) or is
// already in a view >= v. Sites done in an earlier send are pre-credited
// (and not re-sent), so Yes() keeps meaning "a majority of all n replicas
// applied or are past v" across resends. With wait_all the event is ready
// once every sent RPC returned (straggler rounds). applied in a reply means
// "in view v with this FinishRecovery's leader" (also from an earlier copy);
// with ours_needed > 0 (the coordinator installs v at its own replica
// last and is not sent the FR) the event is also ready once that many
// replies said so.
class JetpackFinishRecoveryQuorumEvent: public QuorumEvent {
 public:
  struct Reply {
    siteid_t site = 0;
    bool applied = false;
    epoch_t view_id = 0;
    epoch_t vid = 0;
  };
  JetpackFinishRecoveryQuorumEvent(int n_total, int quorum, epoch_t v, bool wait_all,
                                   int ours_needed = 0)
      : QuorumEvent(n_total, quorum), v_(v), wait_all_(wait_all), ours_needed_(ours_needed) {}
  epoch_t v_;
  bool wait_all_;
  int ours_needed_;
  int n_sent_ = 0;
  int n_replied_ = 0;
  int n_errors_ = 0;
  int n_applied_ = 0;
  epoch_t max_view_id_ = 0;
  epoch_t max_vid_ = 0;
  std::set<siteid_t> done_;
  std::vector<Reply> replies_;

  void PreCredit(siteid_t site) {
    done_.insert(site);
    VoteYes();
  }
  void Feed(const Reply& r) {
    n_replied_++;
    replies_.push_back(r);
    if (r.view_id > max_view_id_) max_view_id_ = r.view_id;
    if (r.vid > max_vid_) max_vid_ = r.vid;
    if (r.applied) n_applied_++;
    if (r.applied || r.view_id >= v_) {
      done_.insert(r.site);
      VoteYes();
    } else {
      VoteNo();
    }
  }
  void FeedError() {
    n_replied_++;
    n_errors_++;
    VoteNo();
  }
  bool AllReplied() const { return n_replied_ >= n_sent_; }
  // Some replica joined or installed a view newer than v.
  bool NewerViewSeen() const { return max_view_id_ > v_ || max_vid_ > v_; }
  bool IsReady() override {
    if (wait_all_) {
      return AllReplied();
    }
    return QuorumEvent::IsReady() || NewerViewSeen() ||
           (ours_needed_ > 0 && n_applied_ >= ours_needed_);
  }
};

/************************RULE end*********************************/

class Communicator {
 public:
  static uint64_t global_id;
  const int CONNECT_TIMEOUT_MS = 120*1000;
  const int CONNECT_SLEEP_MS = 1000;
  rrr::PollMgr *rpc_poll_ = nullptr;
  TxLogServer *rep_sched_ = nullptr;
  locid_t loc_id_ = -1;
  std::string local_host_{};
  map<siteid_t, shared_ptr<rrr::Client>> rpc_clients_{};
  map<siteid_t, ClassicProxy *> rpc_proxies_{};
  map<parid_t, vector<SiteProxyPair>> rpc_par_proxies_{};
  map<parid_t, SiteProxyPair> leader_cache_ = {};
  unordered_map<uint64_t, pair<rrr::i64, rrr::i64>> outbound_{};
	map<uint64_t, double> lat_util_{};
  locid_t leader_ = 0;
  
  // Global view tracking for all partitions (shared across all communicators)
  static std::map<parid_t, View> partition_views_;
  static std::mutex partition_views_mutex_;
	int outbound = 0;
	int outbounds[100];
	int ob_index = 0;
	int begin_index = 0;
	bool paused = false;
	bool slow = false;
	int index;
	int cpu_index;
	int low_util;
  int total;
	int total_;
	shared_ptr<QuorumEvent> qe;
  rrr::i64 window[200];
  rrr::i64 window_time;
  rrr::i64 total_time;
	rrr::i64 window_avg;
	rrr::i64 total_avg;
	double cpu_stor[10];
	double cpu_total;
	double cpu = 1.0;
	double last_cpu = 1.0;
	double tx;
  vector<ClientSiteProxyPair> client_leaders_;
  std::atomic_bool client_leaders_connected_;
  std::vector<std::thread> threads;
  bool broadcasting_to_leaders_only_{true};
  bool follower_forwarding{false};
	std::mutex lock_;
	std::mutex count_lock_;
	std::condition_variable cv_;
	bool waiting = false;
  
  // Callback function type for getting dynamic leader
  using LeaderCallback = std::function<locid_t(parid_t)>;
  LeaderCallback leader_callback_ = nullptr;

  Communicator(PollMgr* poll_mgr = nullptr);
  virtual ~Communicator();
  
  void SetLeaderCallback(LeaderCallback callback) {
    leader_callback_ = callback;
  }

  SiteProxyPair RandomProxyForPartition(parid_t partition_id) const;
  SiteProxyPair LeaderProxyForPartition(parid_t, int idx=-1) const;

  SiteProxyPair NearestProxyForPartition(parid_t) const;
  // Safe variants returning int64_t so the "no entry" sentinel (-1) is
  // always a proper negative regardless of how siteid_t / parid_t are
  // typedef'd (both are unsigned in this codebase, so returning -1 as
  // siteid_t silently becomes UINT16_MAX and breaks a `result < 0`
  // check). Return -1 if the partition has not been cached or if no
  // proxies have been registered, instead of abort()'ing inside a
  // verify. Used by WAN_WAIT_TO gating in coordinator ack handlers
  // where the coordinator may be asked about a partition it never
  // issued a Dispatch to.
  int64_t CachedLeaderSiteForPartition(parid_t par_id) const {
    auto it = leader_cache_.find(par_id);
    if (it != leader_cache_.end()) return static_cast<int64_t>(it->second.first);
    return -1;
  }

  // Return any cached leader site for the communicator's known partitions,
  // or -1 if nothing has been cached yet. Used as a fallback for
  // coordinators whose par_id_ was never set (Coordinator::par_id_
  // defaults to -1 and classic/CC coordinators don't write it). Correct
  // for single-partition experiments — in a multi-partition setup the
  // caller should use CachedLeaderSiteForPartition with a known par_id.
  int64_t AnyCachedLeaderSite() const {
    if (leader_cache_.empty()) return -1;
    return static_cast<int64_t>(leader_cache_.begin()->second.first);
  }

  size_t LeaderCacheSize() const { return leader_cache_.size(); }  // TEMP DEBUG

  void SetLeaderCache(parid_t par_id, SiteProxyPair& proxy) {
    leader_cache_[par_id] = proxy;
  }
  virtual SiteProxyPair DispatchProxyForPartition(parid_t par_id) const {
    return LeaderProxyForPartition(par_id);
  };
  locid_t GenerateNewLeaderId(parid_t par_id) {
    return leader_cache_[par_id].first = leader_cache_[par_id].first + 1;
  };
  
  // View management methods (static for global access)
  // Takes a strictly newer view id, or the same id naming a leader where the
  // known view had none (Raft's WRONG_LEADER placeholder has leader -1).
  static void UpdatePartitionView(parid_t partition_id, const std::shared_ptr<ViewData>& view_data);
  // WRONG_LEADER replies. Where Dispatch routing follows the view
  // (RoutesByView), a same-id view naming another known leader also replaces
  // the known one: the bounced replica redirects (e.g. replicas of an
  // etcd/Mongo/ZK view led by a takeover coordinator). Elsewhere it is
  // UpdatePartitionView.
  static void AdoptRedirectView(parid_t partition_id, const std::shared_ptr<ViewData>& view_data);
  static View GetPartitionView(parid_t partition_id);
  // Whether client Dispatch routing follows the leader of the newest
  // known view. True exactly where Jetpack recovery runs
  // (TxLogServer::JetpackRecoveryEnabled: Raft, etcd, MongoDB, ZooKeeper
  // under cc:rule outside CURP); CURP, Copilot, Mencius, SwiftPaxos, EPaxos,
  // FPGA-Raft and cc:none keep their routing.
  static bool RoutesByView();
  // Locale of the leader of the newest known view of the partition, or -1 if
  // no view names a leader of this partition (locid_t is unsigned, hence
  // int). Views name leaders by site id.
  static int ViewLeaderLocale(parid_t partition_id);
  // Non-static (and const) so that client-side callers can return
  // this->loc_id_ when the protocol wants clients to hit their co-located
  // server (e.g. MODE_NAIVE_EPAXOS — every server is a leader for its
  // local clients).
  locid_t GetLeaderForPartition(parid_t partition_id) const;
  std::pair<int, ClassicProxy*> ConnectToSite(Config::SiteInfo &site,
                                              std::chrono::milliseconds timeout_ms);
  ClientSiteProxyPair ConnectToClientSite(Config::SiteInfo &site,
                                          std::chrono::milliseconds timeout);
  void Pause();
  void Resume();
  void ConnectClientLeaders();
  void WaitConnectClientLeaders();

  vector<function<bool(const string& arg, string& ret)> >
      msg_string_handlers_{};
  vector<function<bool(const MarshallDeputy& arg,
                       MarshallDeputy& ret)> > msg_marshall_handlers_{};

	void ResetProfiles();
  void SendStart(SimpleCommand& cmd,
                 int32_t output_size,
                 std::function<void(Future *fu)> &callback);
  virtual void BroadcastDispatch(shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data,
                         Coordinator *coo,
                         const std::function<void(int res, TxnOutput &)> &,
                         std::shared_ptr<TpcBatchCommand> batch_cmd = nullptr) ;
  virtual void SyncBroadcastDispatch(shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data,
                         Coordinator *coo,
                         const std::function<void(int res, TxnOutput &)> &) ;

	shared_ptr<QuorumEvent> SendReelect();

  shared_ptr<IntEvent> BroadcastDispatch(ReadyPiecesData cmds_by_par,
                        Coordinator* coo,
                        TxData* txn);

  shared_ptr<AndEvent> SendPrepare(Coordinator* coo,
                                         txnid_t tid,
                                         std::vector<int32_t>& sids);
  shared_ptr<AndEvent> SendCommit(Coordinator* coo,
                                     txnid_t tid);
  shared_ptr<AndEvent> SendAbort(Coordinator* coo,
                                    txnid_t tid);
  /*void SendPrepare(parid_t gid,
                   txnid_t tid,
                   std::vector<int32_t> &sids,
                   const std::function<void(int)> &callback) ;*/
  /*void SendCommit(parid_t pid,
                  txnid_t tid,
                  const std::function<void()> &callback) ;
  void SendAbort(parid_t pid,
                 txnid_t tid,
                 const std::function<void()> &callback) ;*/
  void SendEarlyAbort(parid_t pid,
                      txnid_t tid) ;

  // for debug
  std::set<std::pair<parid_t, txnid_t>> phase_three_sent_;

  void ___LogSent(parid_t pid, txnid_t tid);

  void SendUpgradeEpoch(epoch_t curr_epoch,
                        const function<void(parid_t,
                                            siteid_t,
                                            int32_t& graph)>& callback);

  void SendTruncateEpoch(epoch_t old_epoch);
  void SendForwardTxnRequest(TxRequest& req, Coordinator* coo, std::function<void(const TxReply&)> callback);

  /**
   *
   * @param shard_id 0 means broadcast to all shards.
   * @param svr_id 0 means broadcast to all replicas in that shard.
   * @param msg
   */
  vector<shared_ptr<MessageEvent>> BroadcastMessage(shardid_t shard_id,
                                                    svrid_t svr_id,
                                                    string& msg);
  std::shared_ptr<MessageEvent> SendMessage(svrid_t svr_id, string& msg);

  void AddMessageHandler(std::function<bool(const string&, string&)>);
  void AddMessageHandler(std::function<bool(const MarshallDeputy&,
                                            MarshallDeputy&)>);
  shared_ptr<GetLeaderQuorumEvent> BroadcastGetLeader(parid_t par_id, locid_t cur_pause);
  shared_ptr<QuorumEvent> FailoverPauseSocketOut(parid_t par_id, locid_t loc_id);
  shared_ptr<QuorumEvent> FailoverResumeSocketOut(parid_t par_id, locid_t loc_id);
  void SetNewLeaderProxy(parid_t par_id, locid_t loc_id);
  void SendSimpleCmd(groupid_t gid, SimpleCommand& cmd, std::vector<int32_t>& sids,
      const function<void(int)>& callback);
  
  /* Jetpack recovery begin */
  // All message contents come from the caller's round-local values; nothing
  // is read from replica state. Each broadcaster yields once (WAN_WAIT)
  // before sending to every replica of the partition, this one included.
  shared_ptr<JetpackPullRecoveryQuorumEvent> JetpackBroadcastPullRecovery(parid_t par_id,
                                                                          epoch_t v,
                                                                          ballot_t ballot,
                                                                          const View& target);
  shared_ptr<JetpackAcceptQuorumEvent> JetpackBroadcastAccept(parid_t par_id,
                                                              epoch_t v,
                                                              epoch_t vn,
                                                              ballot_t ballot,
                                                              const shared_ptr<KeyCmdBatchData>& value);
  // Sends FinishRecovery(v) at `ballot` (the ballot that chose the value, or
  // jp::kChosenBallot once the leader of v is decided) to every replica not in
  // already_done; those are pre-credited as yes. exclude_site (>= 0) is
  // neither sent nor credited (the coordinator itself until it installs
  // v); ours_needed, see JetpackFinishRecoveryQuorumEvent.
  shared_ptr<JetpackFinishRecoveryQuorumEvent> JetpackBroadcastFinishRecovery(parid_t par_id,
                                                                              epoch_t v,
                                                                              ballot_t ballot,
                                                                              const View& target,
                                                                              const std::set<siteid_t>& already_done,
                                                                              bool wait_all = false,
                                                                              int exclude_site = -1,
                                                                              int ours_needed = 0);
  /* Jetpack recovery end */
};

} // namespace janus
