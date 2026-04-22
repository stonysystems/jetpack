#pragma once
#include "__dep__.h"
#include "constants.h"
#include "command.h"
#include "epochs.h"
#include "kvdb.h"
#include "procedure.h"
#include "view.h"
#include "tx.h"
#include "rcc/tx.h"
#include "classic/tpc_command.h"
#include "RW_command.h"
#include "config.h"
#include <chrono>
#include <fstream>
#include <limits>

namespace janus {

class TxLogServer;

struct UniqueCmdID {
  int32_t client_id_;
  int32_t cmd_id_;
};

struct CpuStatSnapshot {
  unsigned long long user{0}, nice{0}, system{0}, idle{0}, iowait{0}, irq{0}, softirq{0}, steal{0};
  uint64_t Total() const {
    return user + nice + system + idle + iowait + irq + softirq + steal;
  }
  uint64_t IdleTime() const {
    return idle + iowait;
  }
};

class Distribution {
  double creation_time_ = SimpleRWCommand::GetCurrentMsTime();
  double recent_100_sum_ = 0;
  // bool pct_lock = false;
 public:
  vector<double> data_;
  void append(double x) {
    // if (pct_lock) return;
    data_.push_back(x);
    recent_100_sum_ += x;
    if (data_.size() > 100)
      recent_100_sum_ -= data_[data_.size() - 101];
  }
  // only append if append_time is in mid 1/3 time (10~20s if duration is 30s)
  void mid_time_append(double x, double append_time) {
    // if (pct_lock) return;
    double duration_3_times = (append_time - creation_time_) * 3;
    if (duration_3_times > Config::GetConfig()->duration_ * 1000 && duration_3_times < Config::GetConfig()->duration_ * 2 * 1000)
      data_.push_back(x);
  }
  // only append if append_time is in mid 1/3 time (10~20s if duration is 30s)
  void mid_time_append(double x) {
    // if (pct_lock) return;
    double append_time = SimpleRWCommand::GetCurrentMsTime();
    double duration_3_times = (append_time - creation_time_) * 3;
    if (duration_3_times > Config::GetConfig()->duration_ * 1000 && duration_3_times < Config::GetConfig()->duration_ * 2 * 1000)
      data_.push_back(x);
  }
  void merge(Distribution &o) {
    for (int i = 0; i < o.count(); i++)
      data_.push_back(o.data_[i]);
  }
  size_t count() {
    return data_.size();
  }
  double recent_100_ave() { // only work when append only
    if (data_.size() == 0)
      return 0;
    if (data_.size() > 100)
      return recent_100_sum_ / 100;
    else
      return recent_100_sum_ / data_.size();
  }
  double pct(double pct) {
    verify(pct >= 0.0 - 1e-6 && pct <= 100.0 + 1e-6);
    // pct_lock = true;
    if (data_.size() == 0)
      return -1;
    sort(data_.begin(), data_.end());
    int pick = floor(data_.size() * pct);
    if (pick == data_.size())
      pick -= 1;
    return data_[pick];
  }
  double pct50() {
    return pct(0.5);
  }
  double pct90() {
    return pct(0.9);
  }
  double pct99() {
    return pct(0.99);
  }
  double ave() {
    if (data_.size() == 0)
      return -1;
    double sum = 0;
    for (int i = 0; i < data_.size(); i++)
      sum += data_[i];
    return sum / data_.size();
  }
  string statistics() {
    std::ostringstream oss;
    oss << std::setw(7) << "count" << std::setw(9) << count();
    oss << std::setw(7) << " 0pct" << std::setw(9) << std::fixed << std::setprecision(2) << pct(0.0);
    oss << std::setw(7) << "50pct" << std::setw(9) << std::fixed << std::setprecision(2) << pct(0.5);
    oss << std::setw(7) << "90pct" << std::setw(9) << std::fixed << std::setprecision(2) << pct(0.9);
    oss << std::setw(7) << "99pct" << std::setw(9) << std::fixed << std::setprecision(2) << pct(0.99);
    oss << std::setw(7) << "  ave" << std::setw(9) << std::fixed << std::setprecision(2) << ave();
    return oss.str();
  }
  string distribution() {
    std::ostringstream oss;
    for (int i = 0; i <= 100; i += 10) {
      // oss << i << "pct ";
      oss << std::setw(9) << std::fixed << std::setprecision(2) << pct(i / 100.0);
    }
    return oss.str();
  }
};

class Frequency {
  vector<int> keys_;
 public:
  void append(double x) {
    keys_.push_back(x);
  }
  void merge(Frequency &o) {
    for (int i = 0; i < o.count(); i++)
      keys_.push_back(o.keys_[i]);
  }
  size_t count() {
    return keys_.size();
  }
  string top_keys_pcts() {
    unordered_map<int, int> count_map;
    for (auto k: keys_) {
      count_map[k]++;
    }
    set<pair<int, int>> frequency;
    for (auto it: count_map) {
      frequency.insert(make_pair(-it.second, it.first));
    }
    std::stringstream ss;
    int i = 0;
    for (set<pair<int, int>>::iterator it = frequency.begin(); it != frequency.end() && i < 10; it++, i++) {
      ss << std::fixed << std::setprecision(6) << -it->first * 100.0 / count() << " (" << it->second << "), ";
    }
    return ss.str();
  }
};

class RevoveryCandidates {
 public:
  // Entry cached per cmd_id. Storing is_write here avoids re-parsing the
  // Marshallable during remove() (the old code constructed a full
  // SimpleRWCommand just to call IsWrite()). 8-byte shared_ptr + 1 bool
  // (padded to 16 bytes) per entry.
  struct Entry {
    shared_ptr<Marshallable> cmd;
    bool is_write;
  };
 private:
  // <cmd_id, entry>
  unordered_map<uint64_t, Entry> candidates_;
  unordered_map<uint64_t, bool> appeared_;
  int total_write_ = 0;
  uint64_t to_recover_id_ = -1;
 public:
  RevoveryCandidates() {}
  void push_back(uint64_t cmd_id, shared_ptr<Marshallable> cmd, bool is_write);
  bool remove(uint64_t cmd_id);
  bool has_appeared(uint64_t cmd_id);
  size_t size() const;
  int total_write();
  bool has_cmd_to_recover() const;
  shared_ptr<Marshallable> cmd_to_recover();
  shared_ptr<Marshallable> get_cmd(uint64_t cmd_id) const;
};

class JetpackCommandPool {
  class CommandPoolLog {
   public:
    double time_;
    int operation_; // 0: push_back; 1: remove
    shared_ptr<Marshallable> cmd_;
    bool success_;
    int size_;
    CommandPoolLog(int operation, shared_ptr<Marshallable> cmd, bool success, int size):
      operation_(operation), cmd_(cmd), success_(success), size_(size) {
      time_ = SimpleRWCommand::GetCurrentMsTime();
    }
    void print(double init_time) {
      pair<int32_t, int32_t> cmd_id = SimpleRWCommand::GetCmdID(cmd_);
      uint64_t cmd_id_combined = SimpleRWCommand::GetCombinedCmdID(cmd_);
      if (operation_ == 0) {
        Log_info("Log %.2f size %d suc %d key %" PRId32 " push_back %" PRId32 " %" PRId32 " %" PRId64, time_ - init_time, size_, success_, SimpleRWCommand::GetKey(cmd_), cmd_id.first, cmd_id.second, cmd_id_combined);
      } else if (operation_ == 1) {
        Log_info("Log %.2f size %d suc %d key %" PRId32 " remove %" PRId32 " %" PRId32 " %" PRId64, time_ - init_time, size_, success_, SimpleRWCommand::GetKey(cmd_), cmd_id.first, cmd_id.second, cmd_id_combined);
      } else {
        verify(0);
      }
    }
  };
  bool belongs_to_leader_{false}; // i.e. This server can propose value // discard
  TxLogServer* owner_{nullptr};
  int pool_size_ = 0; // number of keys tracked in candidates_
  int pool_cmd_count_ = 0; // total number of commands tracked
  Distribution pool_size_distribution_;
#ifdef COMMAND_POOL_ON_DISK
  std::ofstream command_pool_file_;
  locid_t command_pool_loc_id_{std::numeric_limits<locid_t>::max()};
  void OpenCommandPoolFile();
  void CloseCommandPoolFile();
#endif

#ifdef COMMAND_POOL_LOG_DEBUG
  vector<CommandPoolLog> pool_log_;
#endif
 public:
  unordered_map<key_t, RevoveryCandidates> candidates_;
  /* Recover related begin */
  ballot_t max_seen_ballot_ = -1, max_accepted_ballot_ = -1;
  int sid_ = -1;
  bool committed_ = false;
  /* Recover related end */

  JetpackCommandPool() {};
  ~JetpackCommandPool();
  // return whether meet conflict, but not whether push_back success
  bool push_back(const shared_ptr<Marshallable>& cmd);
  // return how many cmd have been removed (cmd may be CMD_TPC_BATCH)
  int remove(const shared_ptr<Marshallable>& cmd);
  // return whether all cmds appeared before
  bool has_appeared(const shared_ptr<Marshallable>& cmd);
  void set_owner(TxLogServer* owner);
  void set_belongs_to_leader(bool belongs_to_leader); // discard
  // return 50pct, 90pct, 99pct, ave of the pool_size_distribution_
  std::vector<double> pool_size_distribution();
  int size() const { return pool_size_; }
  int cmd_size() const { return pool_cmd_count_; }
  /* Recover related begin */
  bool has_cmd_to_recover(key_t key) {
    return candidates_[key].has_cmd_to_recover();
  }
  shared_ptr<Marshallable> cmd_to_recover(key_t key) {
    return candidates_[key].cmd_to_recover();
  }
  shared_ptr<VecRecData> id_set();
  void reset();
  /* Recover related end */
#ifdef COMMAND_POOL_LOG_DEBUG
  void print_log();
#endif
#ifdef COMMAND_POOL_ON_DISK
  void WriteCommandToDisk(const SimpleRWCommand& cmd);
#endif
};

class RecentAverage {
  vector<double> data_;
  int size_, pointer_ = 0;
  double sum = 0;
  bool filled_once_ = false;
 public:
  RecentAverage(int size): size_(size) {
    // intentionally left blank
  }
  void append(double x) {
    if (!filled_once_) {
      data_.push_back(x);
      pointer_++;
    } else {
      sum -= data_[pointer_];
      data_[++pointer_] = x;
    }
    sum += x;
    if (pointer_ == size_) {
      pointer_ = 0;
      filled_once_ = true;
    }
  }
  bool filled_once() {
    return filled_once_;
  }
  double ave() {
    // Log_info("RecentAverage ave %d %d", filled_once_, pointer_);
    verify(filled_once_ || pointer_ > 0);
    return filled_once_ ? sum / size_ : sum / pointer_;
  }
};

struct ResponseData {
  // pair<ver_t, ver_t> pos_of_this_pack;
  map<pair<int, int>, vector<shared_ptr<Marshallable> > >responses_;
  shared_ptr<Marshallable> max_cmd_{nullptr};
  int received_count_ = 0, accept_count_ = 0, max_accept_count_ = 0;
  double first_seen_time_ = 0;
  bool done_{false};
  pair<int, int> append_response(const shared_ptr<Marshallable>& cmd) {
    VecPieceData *vecPiece;
    if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT) { // original through tx svr
      shared_ptr<TpcCommitCommand> tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
      vecPiece = (VecPieceData*)(tpc_cmd->cmd_.get());
    } else if (cmd->kind_ == MarshallDeputy::CMD_VEC_PIECE) { // jetpack broadcast
      vecPiece = dynamic_pointer_cast<VecPieceData>(cmd).get();
    } else {
      verify(0);
    }
    shared_ptr<CmdData> md = vecPiece->sp_vec_piece_data_->at(0);
    pair<int, int> cmd_id = {md->client_id_, md->cmd_id_in_client_};
    responses_[cmd_id].push_back(cmd);
    accept_count_++;
    if (responses_[cmd_id].size() > max_accept_count_) {
      max_accept_count_ = responses_[cmd_id].size();
      max_cmd_ = cmd;
    }
    return {accept_count_, max_accept_count_};
  }
  shared_ptr<Marshallable> GetMaxCmd() {
    return max_cmd_;
  }
};

class RecoverySet {
  std::unordered_map<int, std::vector<std::pair<key_t, uint64_t>>> rec_set_; // Form locally and distribute
  // std::unordered_map<int, std::vector<key_t>> matched_key_set_;
  std::unordered_map<int, std::vector<std::pair<key_t, shared_ptr<Marshallable>>>> missed_key_cmd_set_;
 public:
  void set_rec_set(int sid, const std::vector<std::pair<key_t, uint64_t>>& rec_set) {
    rec_set_[sid] = rec_set;
  }
  // void set_matched_key_set(int sid, const std::vector<key_t>& matched_key_set) {
  //   matched_key_set_[sid] = matched_key_set;
  // }
  void set_missed_key_cmd_set(int sid, const std::vector<std::pair<key_t, shared_ptr<Marshallable>>>& missed_key_cmd_set) {
    missed_key_cmd_set_[sid] = missed_key_cmd_set;
  }
  void clear(int sid) {
    rec_set_.erase(sid);
    // matched_key_set_.erase(sid);
    missed_key_cmd_set_.erase(sid);
  }
  const std::vector<std::pair<key_t, uint64_t>>* get_rec_set(int sid) const {
    auto it = rec_set_.find(sid);
    if (it == rec_set_.end()) return nullptr;
    return &it->second;
  }
  // const std::vector<key_t>* get_matched_key_set(int sid) const {
  //   auto it = matched_key_set_.find(sid);
  //   if (it == matched_key_set_.end()) return nullptr;
  //   return &it->second;
  // }
  const std::vector<std::pair<key_t, shared_ptr<Marshallable>>>* get_missed_key_cmd_set(int sid) const {
    auto it = missed_key_cmd_set_.find(sid);
    if (it == missed_key_cmd_set_.end()) return nullptr;
    return &it->second;
  }
};

// View class is defined in view.h



struct CommitNotification {
  // client side
  bool client_stored_ = false;
  bool_t* committed_;
  value_t* commit_result_;
  function<void()> commit_callback_;
  // coordinator side
  bool coordinator_stored_ = false;
  value_t coordinator_commit_result_;
  bool coordinator_replied_ = false;
  // timestamp (ms)
  double receive_time_ = -1;
};

class TxnRegistry;
class Executor;
class Coordinator;
class Frame;
class Communicator;
class TxLogServer {
 public:

  /* Some Jetpack elements begin */
  enum JetpackStatus {RECOVERY, READY};
  int jetpack_status_ = JetpackStatus::READY;
  epoch_t jepoch_, oepoch_;
  View old_view_, new_view_;
  int sid, rid, sid_cnt_ = 0;
  RecoverySet rec_set_;
  bool simulated_fail_ = false;
  std::chrono::steady_clock::time_point jetpack_recovery_start_time_{};
  /* Some Jetpack elements end */

  // CPU monitor for RuleSpeculativeExecute responses (lazy-start).
  bool cpu_monitor_started_{false};
  double last_cpu_usage_{-1.0};
  bool cpu_monitor_stop_{false};

  // Lightweight profiling counters for Jetpack hot paths. Sampled on every
  // spec RPC handler / dispatch RPC handler / Raft OnAppendEntries invocation
  // and printed at shutdown. Atomic so coroutines on the same thread and any
  // worker threads both contribute safely.
  std::atomic<uint64_t> prof_spec_calls_{0};
  std::atomic<uint64_t> prof_spec_ns_{0};
  std::atomic<uint64_t> prof_dispatch_calls_{0};
  std::atomic<uint64_t> prof_dispatch_ns_{0};
  std::atomic<uint64_t> prof_pool_push_calls_{0};
  std::atomic<uint64_t> prof_pool_push_ns_{0};
  // Sub-phases of push_back: outer map lookup, inner bucket insert/vote,
  // conflict-detection path. Helps answer "is unordered_map the bottleneck?"
  std::atomic<uint64_t> prof_pool_extract_ns_{0};
  std::atomic<uint64_t> prof_pool_outer_lookup_ns_{0};
  std::atomic<uint64_t> prof_pool_inner_insert_ns_{0};
  // Pool remove / has_appeared
  std::atomic<uint64_t> prof_pool_remove_calls_{0};
  std::atomic<uint64_t> prof_pool_remove_ns_{0};
  std::atomic<uint64_t> prof_pool_has_appeared_calls_{0};
  std::atomic<uint64_t> prof_pool_has_appeared_ns_{0};
  // Peak pool sizes (outer distinct keys; inner cmd count)
  std::atomic<uint64_t> prof_pool_peak_keys_{0};
  std::atomic<uint64_t> prof_pool_peak_cmds_{0};
  std::atomic<uint64_t> prof_append_entries_calls_{0};
  std::atomic<uint64_t> prof_append_entries_ns_{0};

  void *svr_workers_g{nullptr};

  locid_t loc_id_ = std::numeric_limits<locid_t>::max();
  siteid_t site_id_ = -1;
  unordered_map<txid_t, shared_ptr<Tx>> dtxns_{};
  unordered_map<txid_t, mdb::Txn *> mdb_txns_{};
  unordered_map<txid_t, Executor *> executors_{};

  function<void(Marshallable &)> app_next_{};
  function<shared_ptr<vector<MultiValue>>(Marshallable&)> key_deps_{};

  shared_ptr<mdb::TxnMgr> mdb_txn_mgr_{};
  int mode_;
  Recorder *recorder_ = nullptr;
  Frame *frame_ = nullptr;
  Frame *rep_frame_ = nullptr;
  TxLogServer *tx_sched_ = nullptr;
  TxLogServer *rep_sched_ = nullptr;
  Communicator *commo_{nullptr};
  //  Coordinator* rep_coord_ = nullptr;
  shared_ptr<TxnRegistry> txn_reg_{nullptr};
  parid_t partition_id_{};
  std::recursive_mutex mtx_{};

  bool epoch_enabled_{false};
  EpochMgr epoch_mgr_{};
  std::time_t last_upgrade_time_{0};
  map<parid_t, map<siteid_t, epoch_t>> epoch_replies_{};
  bool in_upgrade_epoch_{false};
  const int EPOCH_DURATION = 5;

  bool paused_ = false; // [Jetpack] For failure recovery additional helper
  Distribution request_queues_depth_; // [Jetpack] For inflight control: avoid original protocol have too many onging commands
  int ongoing_cmds_{0}; // [Jetpack] For inflight control: avoid original protocol have too many onging commands

#ifdef CHECK_ISO
  typedef map<Row*, map<colid_t, int>> deltas_t;
  deltas_t deltas_{};

  void MergeDeltas(deltas_t deltas) {
    verify(deltas.size() > 0);
    for (auto& pair1: deltas) {
      Row* r = pair1.first;
      for (auto& pair2: pair1.second) {
        colid_t c = pair2.first;
        int delta = pair2.second;
        deltas_[r][c] += delta;
        int v = r->get_column(c).get_i32();
        int x = deltas_[r][c];
      }
    }
    deltas.clear();
  }

  void CheckDeltas() {
    for (auto& pair1: deltas_) {
      Row* r = pair1.first;
      for (auto& pair2: pair1.second) {
        colid_t c = pair2.first;
        int delta = pair2.second;
        int v = r->get_column(c).get_i32();
        verify(delta == v);
      }
    }
  }
#endif

  Communicator *commo() {
    verify(commo_ != nullptr);
    return commo_;
  }

  void StartCpuMonitorIfNeeded();
  bool ReadCpuStats(int core, CpuStatSnapshot* out);
  double ComputeCpuUsage(const CpuStatSnapshot& old_stats, const CpuStatSnapshot& new_stats);
  double SampleCpuUsage();

  TxLogServer();
  TxLogServer(int mode);
  virtual ~TxLogServer();


  virtual void SetPartitionId(parid_t par_id) {
    partition_id_ = par_id;
  }

  // runs in a coroutine.

  virtual bool HandleConflicts(Tx &dtxn,
                               innid_t inn_id,
                               vector<string> &conflicts) {
    return false;
  };
  virtual bool HandleConflicts(Tx &dtxn,
                               innid_t inn_id,
                               vector<conf_id_t> &conflicts) {
    Log_fatal("unimplemnted feature: handle conflicts!");
    return false;
  };
  virtual void Execute(Tx &txn_box,
                       innid_t inn_id);

  Coordinator *CreateRepCoord(const i64& dep_id=0);
  virtual shared_ptr<Tx> GetTx(txnid_t tx_id);
  virtual shared_ptr<Tx> CreateTx(txnid_t tx_id,
                                  bool ro = false);
  virtual shared_ptr<Tx> CreateTx(epoch_t epoch,
                                  txnid_t txn_id,
                                  bool read_only = false);
  virtual shared_ptr<Tx> GetOrCreateTx(txnid_t tid, bool ro = false);
  void DestroyTx(i64 tid);

  virtual void DestroyExecutor(txnid_t txn_id);

  inline int get_mode() { return mode_; }

  // Below are function calls that go deeper into the mdb.
  // They are merged from the called TxnRunner.

  inline mdb::Table
  *get_table(const string &name) {
    return mdb_txn_mgr_->get_table(name);
  }

  virtual mdb::Txn *GetMTxn(const i64 tid);
  virtual mdb::Txn *GetOrCreateMTxn(const i64 tid);
  virtual mdb::Txn *RemoveMTxn(const i64 tid);

  void get_prepare_log(i64 txn_id,
                       const std::vector<i32> &sids,
                       std::string *str
  );

  // TODO: (Shuai: I am not sure this is supposed to be here.)
  // I think it used to initialized the database?
  // So it should be somewhere else?
  void reg_table(const string &name,
                 mdb::Table *tbl
  );

  virtual int32_t Dispatch(cmdid_t cmd_id,
                        shared_ptr<Marshallable> cmd,
                        TxnOutput& ret_output,
                        std::shared_ptr<ViewData>& view_data) {
    verify(0);
    return REJECT;
  }

  void RegLearnerAction(function<void(Marshallable &)> learner_action) {
    app_next_ = learner_action;
  }

  /**
   * Check if the command is already committed
   * @param commit_cmd command to be checked
   * @return true if it's already committed, false otherwise
   */
  virtual bool CheckCommitted(Marshallable& commit_cmd) { verify(0); }

  virtual void Next(Marshallable& cmd) { verify(0); };

	virtual void Setup() { verify(0); } ;
  virtual bool IsLeader() { verify(0); } ;
  virtual bool IsFPGALeader() { verify(0); } ;
	
	virtual bool RequestVote() { verify(0); return false;};
  virtual void Pause();
  virtual void Resume();

  // epoch related functions
  void TriggerUpgradeEpoch();
  void UpgradeEpochAck(parid_t par_id, siteid_t site_id, int res);
  virtual int32_t OnUpgradeEpoch(uint32_t old_epoch);
  
  // application k-v table for rw workload
  unordered_map<key_t, value_t> kv_table_;


  // For checksum
  unordered_map<key_t, value_t> database_;
  int database_operation_count_ = 0;

  void ApplyToDatabase(shared_ptr<Marshallable> cmd) {
    SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
    // Log_info("Apply Write %d key %d value %d", parsed_cmd.IsWrite(), parsed_cmd.key_, parsed_cmd.value_);
    if (parsed_cmd.IsWrite()) {
      database_[parsed_cmd.key_] = parsed_cmd.value_;
      database_operation_count_++;
    }
  }

  uint32_t ChecksumXor() {
    Log_info("database_operation_count_ %d", database_operation_count_);
    uint32_t checksum = 0;
    for (const auto& kv : database_) {
        checksum ^= static_cast<uint32_t>(kv.first);
        checksum ^= static_cast<uint32_t>(kv.second);
    }
    return checksum;
  }

  UniqueCmdID GetUniqueCmdID(shared_ptr<Marshallable> cmd);

  value_t DBGet(const shared_ptr<Marshallable>& cmd);

  value_t DBPut(const shared_ptr<Marshallable>& cmd);

  // This used for garbage collection / evaluation data structure grows over time
  void PrintStructureSize();

  // below are about rule

  double GetQueueDepthForRule();
  JetpackCommandPool command_pool_;

  // For Rule usage
  void OnRuleSpeculativeExecute(const shared_ptr<Marshallable>& cmd,
                                bool_t* accepted,
                                value_t* result,
                                bool_t* is_leader,
                                double* cpu_usage,
                                double* queue_depth);

  void OriginalPathUnexecutedCmdConflictPlaceHolder(const shared_ptr<Marshallable>& cmd);

  void RuleCommandPoolGC(const shared_ptr<Marshallable>& cmd);

  // CURP: check if cmd conflicts with any uncommitted Raft log entry (leader only)
  bool ConflictWithUncommittedRaftLog(const shared_ptr<Marshallable>& cmd);

#ifdef ZERO_OVERHEAD
  virtual bool ConflictWithOriginalUnexecutedLog(const shared_ptr<Marshallable>& cmd) {
    // This function should be overrided by the deriviated class (replica server)
    assert(0);
    return false;
  }
#endif

  void JetpackRecoveryEntry();

  void JetpackRecovery();

  void JetpackCommit(int sid);

  void JetpackResubmit(int sid);
  void DispatchRecoveredBatch(const std::vector<std::shared_ptr<TpcCommitCommand>>& batch,
                              std::shared_ptr<IntEvent> recovery_event = nullptr);
  void DispatchRecoveredCommand(shared_ptr<Marshallable> cmd, shared_ptr<IntEvent> recovery_event = nullptr);
  
  virtual void OnJetpackPullRecovery(const MarshallDeputy& old_view,
                                     const MarshallDeputy& new_view,
                                     const epoch_t& jepoch,
                                     const epoch_t& oepoch,
                                     bool_t* ok,
                                     epoch_t* reply_jepoch,
                                     epoch_t* reply_oepoch,
                                     MarshallDeputy* reply_old_view,
                                     MarshallDeputy* reply_new_view,
                                     shared_ptr<KeyCmdIdBatchData>& id_batch);
  void OnJetpackBeginRecovery(const MarshallDeputy& old_view,
                                      const MarshallDeputy& new_view, 
                                      const epoch_t& new_view_id);
  
  void OnJetpackPullIdSet(const epoch_t& jepoch,
                          const epoch_t& oepoch,
                          bool_t* ok,
                          epoch_t* reply_jepoch,
                          epoch_t* reply_oepoch,
                          MarshallDeputy* reply_old_view,
                          MarshallDeputy* reply_new_view,
                          shared_ptr<VecRecData> id_set);
  
  virtual void OnJetpackPullCmd(const epoch_t& jepoch,
                        const epoch_t& oepoch,
                        const std::vector<key_t>& keys,
                        bool_t* ok, 
                        epoch_t* reply_jepoch, 
                        epoch_t* reply_oepoch,
                        MarshallDeputy* reply_old_view,
                        MarshallDeputy* reply_new_view,
                        shared_ptr<KeyCmdBatchData>& batch);
  
  void OnJetpackRecordCmd(const epoch_t& jepoch, 
                          const epoch_t& oepoch, 
                          const int32_t& sid, 
                          shared_ptr<KeyCmdIdBatchData>& id_batch,
                          shared_ptr<KeyCmdIdBatchData>& missing_batch,
                          shared_ptr<KeyCmdBatchData>& cmd_batch);
  
  virtual void OnJetpackPrepare(const epoch_t& jepoch, 
                                const epoch_t& oepoch, 
                                const ballot_t& max_seen_ballot, 
                                bool_t* ok, 
                                epoch_t* reply_jepoch,
                                epoch_t* reply_oepoch,
                                MarshallDeputy* reply_old_view,
                                MarshallDeputy* reply_new_view,
                                ballot_t* reply_max_seen_ballot,
                                ballot_t* accepted_ballot, 
                                int32_t* replied_sid);
  
  virtual void OnJetpackAccept(const epoch_t& jepoch, 
                               const epoch_t& oepoch, 
                               const ballot_t& max_seen_ballot, 
                               const int32_t& sid, 
                               bool_t* ok,
                               epoch_t* reply_jepoch,
                               epoch_t* reply_oepoch,
                               MarshallDeputy* reply_old_view,
                               MarshallDeputy* reply_new_view,
                               ballot_t* reply_max_seen_ballot);
  
  virtual void OnJetpackCommit(const epoch_t& jepoch, 
                               const epoch_t& oepoch, 
                               const int32_t& sid);
  
  void OnJetpackFinishRecovery(const epoch_t& oepoch);


};

} // namespace janus
