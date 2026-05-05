#pragma once

#include "__dep__.h"
#include "config.h"
#include "communicator.h"
#include "procedure.h"
#include "mongodb_kv_table_handler.h"

namespace janus {

class ClientControlServiceImpl;
class Workload;
class CoordinatorBase;
class Frame;
class Coordinator;
class TxnRegistry;
class TxReply;

class ClientWorker {
 public:
  PollMgr* poll_mgr_{nullptr};
  Frame* frame_{nullptr};
  Communicator* commo_{nullptr};
  cliid_t cli_id_;
  int32_t benchmark;
  int32_t mode;
  bool batch_start;
  uint32_t id;
  uint32_t duration;
  double creation_time_{0};
	int outbound;
  ClientControlServiceImpl *ccsi{nullptr};
  int32_t n_concurrent_;
  map<cooid_t, bool> n_pause_concurrent_{};
  rrr::Mutex finish_mutex{};
  rrr::CondVar finish_cond{};
  bool forward_requests_to_leader_ = false;

  // coordinators_{mutex, cond} synchronization currently only used for open clients
  std::mutex request_gen_mutex{};
  std::mutex coordinator_mutex{};
  vector<Coordinator*> free_coordinators_{};
  vector<Coordinator*> created_coordinators_{};
  Coordinator* fail_ctrl_coo_{nullptr};
  //  rrr::ThreadPool* dispatch_pool_ = new rrr::ThreadPool();
  std::shared_ptr<TimeoutEvent> timeout_event;
  std::shared_ptr<NEvent> n_event;
  std::shared_ptr<AndEvent> and_event;

  std::atomic<uint32_t> num_txn, success, num_try;
  int all_done_{0};
  int64_t n_tx_issued_{0};
  SharedIntEvent n_ceased_client_{};
  SharedIntEvent sp_n_tx_done_{}; // TODO refactor: remove sp_
  Workload * tx_generator_{nullptr};
  Timer *timer_{nullptr};
  shared_ptr<TxnRegistry> txn_reg_{nullptr};
  Config* config_{nullptr};
  Config::SiteInfo& my_site_;
  bool failure_triggered_seen_{false};
  bool recovery_finish_seen_{false};
  vector<string> servers_;
  bool* volatile failover_trigger_;
  volatile bool* failover_server_quit_;
  volatile locid_t* failover_server_idx_;
  volatile double* total_throughput_;

  // For latency test
  // All the following statistics only count mid 1/3 duration
  // 2 \subseteq 1 \subseteq 0, 4 \subseteq 3, 5 = 2 \cup 4, 2 \cap 4 = \emptyset
  // 0: all fast path attempts (even fail or slower than original path), 1 RTT
  // 1: success fast path attempts (success only, may slower than original path), 1 RTT
  // 2: efficient fast path attempts (only success and faster than original path), 1 RTT
  // 3: all original path attempts (even slower than fast path), 2 RTTs
  // 4: efficient original path attempts (only faster than fast path, or fast path failed), 2 RTTs
  // 5: all efficient attempts (count all faster one) (should equals to category 1 merge category 3)

  // All the following statistics count all duration
  // 6: all success fast path read attempts
  // 7: all success fast path write attempts
  // 8: all original path read attempts
  // 9: all original path write attempts

  // Mid-10s read/write split (set 2026-05-05). Same gating as slot 5 —
  // appended next to every existing cli2cli_[5].append, partitioned by
  // cmd_is_write_. Invariant: count(10) + count(11) == count(5).
  // 10: mid-10s read latency
  // 11: mid-10s write latency
  Distribution cli2cli_[12];
  Distribution dispatch_time_distribution_;
  Distribution cpu_usage_all_;
  Distribution cpu_usage_leaders_;
  Distribution queue_depth_;
  int go_to_jetpack_fastpath_cnt_ = 0;
  vector<std::pair<double, double>> commit_time_; // <dispatch_time, duration>
  Frequency frequency_;
#ifdef LATENCY_DEBUG
  Distribution client2leader_, client2test_point_, client2leader_send_;
#endif
  locid_t cur_leader_{0}; // init leader is 0
  bool failover_wait_leader_{false};
  bool failover_trigger_loc{false};
  bool failover_pause_start{false};

  OneArmedBandit one_armed_bandit_; // For fast path attempt prediction
  

 public:
  ClientWorker(uint32_t id, Config::SiteInfo& site_info, Config* config,
      ClientControlServiceImpl* ccsi, PollMgr* mgr, bool* volatile failover,
      volatile bool* failover_server_quit, volatile locid_t* failover_server_idxm,
      volatile double* total_throughput);
  ClientWorker() = delete;
  ~ClientWorker();
  void retrive_statistic();
  // This is called from a different thread.
  void Work();
  Coordinator* FindOrCreateCoordinator();
  void FailoverPreprocess(Coordinator* coo);
  void DispatchRequest(Coordinator *coo, bool void_request=false);
  void SearchLeader(Coordinator* coo);
  void Pause(locid_t locid);
  void Resume(locid_t locid);
  Coordinator* CreateFailCtrlCoordinator();
  void AcceptForwardedRequest(TxRequest &request, TxReply* txn_reply, rrr::DeferredReply* defer);

 protected:
  Coordinator* CreateCoordinator(uint16_t offset_id);
  void RequestDone(Coordinator* coo, TxReply &txn_reply);
  void ForwardRequestDone(Coordinator* coo, TxReply* output, rrr::DeferredReply* defer, TxReply &txn_reply);
};
} // namespace janus
