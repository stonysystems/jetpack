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
#include "curp/witness.h"
#include "jetpack_rules.h"
#include <chrono>
#include <fstream>
#include <limits>

namespace janus {

class TxLogServer;
class JetpackLeaderProbe;  // jetpack_term_source.h

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
  // SimpleRWCommand just to call IsWrite()). acked records the fast-path
  // verdict given when the entry was inserted, so a redelivered request gets
  // the same answer. shared_ptr + 2 bools (padded to 16 bytes).
  struct Entry {
    shared_ptr<Marshallable> cmd;
    bool is_write;
    bool acked;
  };
 private:
  // <cmd_id, entry>
  unordered_map<uint64_t, Entry> candidates_;
  unordered_map<uint64_t, bool> appeared_;
  int total_write_ = 0;
  // The acked write of this key, i.e. the entry recovery reports. Only an
  // acked write becomes to_recover; total_write_ == 0 => to_recover_id_ == -1.
  uint64_t to_recover_id_ = -1;
 public:
  RevoveryCandidates() {}
  void insert(uint64_t cmd_id, shared_ptr<Marshallable> cmd, bool is_write, bool acked);
  const Entry* find(uint64_t cmd_id) const;
  bool remove(uint64_t cmd_id);
  bool has_appeared(uint64_t cmd_id);
  size_t size() const;
  int total_write() const;
  bool has_cmd_to_recover() const;
  // nullptr if the reported write was already GC'd (it committed).
  shared_ptr<Marshallable> cmd_to_recover() const;
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
  // The fast-path log of the installed view (the log is the pool).
  // Recovery acceptor state lives on TxLogServer (jp_promised_/jp_accepted_),
  // not here, so clearing the pool never wipes it.
  unordered_map<key_t, RevoveryCandidates> candidates_;

  JetpackCommandPool() {};
  ~JetpackCommandPool();
  // Records cmd and returns the fast-path verdict: true iff cmd is acked
  // (allow_ack and no conflicting entry). allow_ack == false records the
  // command as a conflict guard without acking it. A redelivered cmd_id gets
  // its first verdict back and changes nothing. In RECOVERY nothing is
  // inserted and the result is false.
  bool push_back(const shared_ptr<Marshallable>& cmd, bool allow_ack = true);
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
  // Appends (key, body) of every acked, not yet GC'd write (one per key).
  void AckedSnapshot(KeyCmdBatchData& out) const;
  // Whether key's bucket still records an acked write (it may have been
  // fast-committed but not yet applied here). Conservative: also true while a
  // GC'd acked write's bucket still holds a later write. Never creates a bucket.
  bool HasAckedWrite(key_t key) const;
  // Empties the pool. Called only when an applied FinishRecovery advances the
  // installed view (JpApplyFinish).
  void ClearPool();
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
  // All Jetpack replica state lives on the replication server (rep_sched_);
  // handlers running on tx_sched_ must go through rep_sched_.
  enum JetpackStatus {RECOVERY, READY};
  // Written only by JpJoin (-> RECOVERY) and JpApplyFinish (-> READY).
  // Invariant: RECOVERY <=> oepoch_ > jepoch_.
  int jetpack_status_ = JetpackStatus::READY;
  // jepoch_ = view.id, the installed fast-path view (the fast path acks only
  // in it); written only by JpApplyFinish. oepoch_ = vid, the newest recovery
  // view joined or installed; written only by JpJoin and JpApplyFinish.
  // Both are non-decreasing and jepoch_ <= oepoch_.
  epoch_t jepoch_ = 0, oepoch_ = 0;
  // Base (original-path) view for WRONG_LEADER replies and routing. new_view_
  // only moves to a newer view (JpAdoptBaseView); the CURP-only follower
  // writer in RaftServer::OnAppendEntries is the one exception. No
  // Jetpack guard reads these.
  View old_view_, new_view_;
  // Paxos acceptor state of the recovery instances: one promise shared
  // by every instance, and accepted[vn] = (ballot, value). Written only by
  // the Pull/Accept handlers after their guard passed. Entries below the
  // installed view are dropped by JpApplyFinish; nothing else clears them.
  ballot_t jp_promised_ = -1;
  struct JpAccepted {
    ballot_t ballot;
    shared_ptr<KeyCmdBatchData> value;
  };
  std::map<epoch_t, JpAccepted> jp_accepted_;
  // The installed fast-path View (its leader is the fast-path proposer).
  // Set by JpApplyFinish; empty before the first applied FinishRecovery, in
  // which case JpInstalledView() returns the static view led by locale 0.
  View jp_installed_view_;
  // Fast-path requests not acked because of the view gate, split by
  // cause: this replica was in RECOVERY, or READY in a view other than the
  // request's. Printed at shutdown next to the pool statistics.
  uint64_t jp_fp_not_ready_ = 0;
  uint64_t jp_fp_view_mismatch_ = 0;
  // Steady-clock time (us) of this replica's newest recovery progress: a
  // join (a passed Pull/Accept or a local trigger) or an applied
  // FinishRecovery. The takeover timer counts from it.
  int64_t jp_progress_us_ = 0;
  // The ballot of this replica's own recovery coordinator, set when its
  // Accept succeeded (it then aims to lead that view): a lower same-view
  // FinishRecovery is not installed here (JpFinishLevel). -1 = none.
  ballot_t jp_fr_floor_ = -1;
  // Amnesia (rejoin) state: amnesiac from construction when
  // JETPACK_REJOIN=1 and Jetpack recovery is enabled (jp::RejoinState).
  jp::RejoinState jp_rejoin_;
  bool jp_rejoin_error_logged_ = false;
  bool simulated_fail_ = false;
  std::chrono::steady_clock::time_point jetpack_recovery_start_time_{};
  /* Some Jetpack elements end */

  /* Jetpack recovery coordinator: touched only by JetpackRecoveryEntry and the
     driver coroutine, never by the replica handlers. */
  bool jp_driver_started_ = false;
  bool jp_driver_stop_ = false;
  shared_ptr<IntEvent> jp_driver_event_{nullptr};
  // Cleared by ~TxLogServer. ServerWorker::ShutDown deletes the replication
  // server while the reactor keeps running, so the long-lived coroutines that
  // hold `this` (the driver's timed idle wait, the FinishRecovery stragglers)
  // check their copy after every wait and then touch nothing of this object.
  std::shared_ptr<std::atomic<bool>> jp_alive_ = std::make_shared<std::atomic<bool>>(true);
  epoch_t jp_pending_view_ = 0;   // newest joined trigger
  View jp_pending_target_;
  // A target is pending while jp_pending_seq_ > jp_driven_seq_; a same-view
  // takeover publishes the view it already drove once more.
  uint64_t jp_pending_seq_ = 0;
  uint64_t jp_driven_seq_ = 0;
  epoch_t jp_driven_view_ = 0;    // newest view the driver started
  epoch_t jp_running_view_ = 0;   // view the driver runs now; 0 = idle
  uint32_t jp_ballot_counter_ = 0;
  // Coordinator takeover timer (etcd / MongoDB / ZooKeeper only).
  bool jp_takeover_started_ = false;
  jp::TakeoverClock jp_takeover_clock_;
  epoch_t jp_takeover_refused_view_ = 0;  // logged "cannot lead" once per view

  // CPU monitor for RuleSpeculativeExecute responses (lazy-start).
  bool cpu_monitor_started_{false};
  double last_cpu_usage_{-1.0};
  bool cpu_monitor_stop_{false};

  // Lightweight profiling counters for Jetpack hot paths. Gated behind
  // JETPACK_PROF so the production build carries zero overhead (no atomics,
  // no chrono::now() calls on the hot path). Enable with `-DJETPACK_PROF=1`
  // at compile time to turn them back on for investigation.
#ifdef JETPACK_PROF
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
#endif  // JETPACK_PROF

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

  // Per-replica CURP witness, populated on every replica that runs CURP
  // mode (when Config::IsCurpMode()). Tracks fast-path attempts for
  // conflict detection on a per-key basis. In Jetpack modes this is
  // unused.
  CurpWitness curp_witness_;

  // Per-key bucket of in-flight original-path-only commands. Each entry
  // carries just the cmd_id (for erase) and is_write (for the
  // write/write-vs-read conflict rule). No shared_ptr to the cmd is
  // needed because the conflict check only consumes the pre-extracted
  // fields, and avoiding it skips a SimpleRWCommand re-parse on the
  // per-fast-path-attempt hot path.
  struct InflightOriginalEntry {
    uint64_t cmd_id;
    bool is_write;
  };
  // Key-indexed (NOT cmd_id-indexed): the conflict check runs on every
  // fast-path attempt and only needs to look at entries with the same
  // key as the attempt. A cmd_id-indexed map forced an O(n) scan over
  // every in-flight original-path command, which saturated the leader
  // under adaptive mode 101 (10k+ attempts/sec × hundreds of entries).
  // Single-threaded coroutine reactor → no atomics / mutex needed.
  std::unordered_map<int /*key*/, std::vector<InflightOriginalEntry>> inflight_original_path_;

  // For Rule usage. Fast-path vote of the command in the client's view
  // req_view: acks only if this replica is READY in view req_view.
  // *reply_view is always set to the installed view (jepoch_).
  void OnRuleSpeculativeExecute(const shared_ptr<Marshallable>& cmd,
                                epoch_t req_view,
                                bool_t* accepted,
                                value_t* result,
                                bool_t* is_leader,
                                double* cpu_usage,
                                double* queue_depth,
                                epoch_t* reply_view);

  void OriginalPathUnexecutedCmdConflictPlaceHolder(const shared_ptr<Marshallable>& cmd);

  void RuleCommandPoolGC(const shared_ptr<Marshallable>& cmd);

  // Per-protocol leader-side conflict check against the local
  // uncommitted-and-unapplied log range. Used by OnRuleSpeculativeExecute
  // when jetpack_skip_pool_for_original_path is enabled, to detect
  // conflicts between an arriving fast-path attempt and an original-path
  // command that sits in this leader's protocol log but has not yet
  // applied to the state machine. Default impl returns false (no
  // conflict known) — the Raft leader override is the first to provide
  // a real implementation; Copilot / Mencius can be added later.
  virtual bool ConflictWithOriginalUnexecutedLog(const shared_ptr<Marshallable>& cmd) {
    (void)cmd;
    return false;
  }

  /* Jetpack recovery begin */

  // The single "Jetpack recovery enabled" predicate. True only for
  // cc:rule outside CURP mode on a replication protocol whose recovery path
  // exists (Raft, etcd, MongoDB, ZooKeeper). Every Jetpack-recovery gate uses
  // it, so other modes (CURP, Copilot, Mencius, SwiftPaxos, EPaxos, FPGA-Raft,
  // cc:none) never take a Jetpack-recovery path.
  static bool JetpackRecoveryEnabled();

  // ---- replica rules (as rs-> in the handlers, as this-> in the coordinator)
  bool JpRecoveryMsgAllowed(epoch_t v, ballot_t b, jp::BallotRule r) const {
    return jp::RecoveryMsgAllowed(jepoch_, oepoch_, jp_promised_, v, b, r);
  }
  // vid := v and RECOVERY, in one step. Caller checked v > jepoch_ && v >= oepoch_.
  void JpJoin(epoch_t v);
  // FinishRecovery(u) at ballot b with the coordinator's target view w (may
  // be null). Applies only if u >= vid && u > view.id and b reaches this
  // replica's FinishRecovery level for u (jp::FinishBallotOk; kChosenBallot
  // always does); the only place that clears the pool and the only writer of
  // jepoch_. Non-yielding.
  bool JpApplyFinish(epoch_t u, ballot_t b, const View* w);
  // The ballot a FinishRecovery(u) must reach here: the highest ballot of
  // view u this replica accepted, and the ballot of this replica's own
  // coordinator of u once its Accept succeeded (jp_fr_floor_).
  ballot_t JpFinishLevel(epoch_t u) const;
  // Monotone base-view adoption. allow_same_id lets an applied FR replace a
  // base view of the same id (a takeover coordinator's leader).
  void JpAdoptBaseView(const View& w, bool allow_same_id = false);
  const View& JpInstalledView();
  // Whether this replica supplies the proposer (leader) vote of fast-path
  // view `view` (the is_leader of a fast-path reply).
  virtual bool JetpackIsProposerOf(epoch_t view);
  // Whether a Raft lease read of `key` may be served from local state.
  // With Jetpack recovery enabled: only in READY and only while the key's pool
  // bucket holds no acked write. Always true otherwise.
  bool JetpackLeaseReadAllowed(key_t key) const;
  // Whether this server may still coordinate the recovery for view v.
  // RaftServer: still leader of the term in which it was elected (== v).
  virtual bool JetpackStillCoordinator(epoch_t v) { return true; }

  // ---- etcd / MongoDB / ZooKeeper backends
  // IsLeader() of a backend server. With Jetpack recovery: this replica
  // leads its installed fast-path view (initially the static view led by
  // locale 0). Without: the static locale 0.
  bool JpBackendIsLeader();
  // The base view a WRONG_LEADER reply carries: new_view_, or the installed
  // view while no base view was ever adopted.
  View JpReplyBaseView();
  // Marks a TpcCommitCommand WRONG_LEADER and attaches JpReplyBaseView().
  void JpMarkWrongLeader(const shared_ptr<Marshallable>& cmd);
  // Backend Submit gate: a client command (not a recovered one) is bounced
  // while this replica is in RECOVERY or, with Jetpack recovery, when it is
  // an original-path-only command and this replica does not lead its
  // installed view (fast-path-attempted commands are written by any READY
  // replica). Returns true if cmd was bounced (marked WRONG_LEADER with the
  // base view; the caller still hands it to app_next_). Nothing was sent to
  // the backend, so the bounced command's own original-path placeholder is
  // dropped here (JpDropBouncedPlaceholder).
  bool JpBackendBounce(const shared_ptr<Marshallable>& cmd, const char* who);
  // A command bounced before it was submitted (never logged or written) never
  // commits, so the original-path placeholder its Dispatch just recorded at
  // this replica would block fast-path acks on its key until the next
  // FinishRecovery. Drops it; only original-path-only commands (no fast-path
  // ack of them exists anywhere) and only with Jetpack recovery.
  void JpDropBouncedPlaceholder(const shared_ptr<Marshallable>& cmd);

  // ---- coordinator
  // Single non-yielding trigger for every backend (Raft setIsLeader, etcd /
  // Mongo / ZK pollers, the takeover timer). target = View(n, this site,
  // backend term). Joins the target locally (freezes the fast path) and hands
  // it to the driver coroutine. emit_ack writes the leader_paused (and legacy
  // fastpath_stopped) signal after the freeze, with the etcd nonce if any.
  // takeover: target is the view this replica is frozen in; the driver
  // runs it again even if this node already drove it.
  void JetpackRecoveryEntry(const View& target, bool emit_ack,
                            uint64_t ack_nonce = 0, bool ack_has_nonce = false,
                            bool takeover = false);
  // Coordinator takeover and the Accept keepalive run only on etcd,
  // MongoDB and ZooKeeper with Jetpack recovery. Raft relies on its own
  // elections (term-v resubmissions need the term-v leader).
  static bool JpTakeoverEnabled();
  bool JpDriverBusy() const {
    return jp_running_view_ != 0 || jp_pending_seq_ > jp_driven_seq_;
  }
  // Starts the takeover timer coroutine of this replica (once; a no-op
  // unless JpTakeoverEnabled()). It stops once *alive is false.
  void JpStartTakeoverTimer(const std::shared_ptr<std::atomic<bool>>& alive);
  // One timer tick: if this replica is frozen (vid > view.id) without
  // recovery progress for its takeover delay (jp::TakeoverClock, rank =
  // loc_id_), the driver is idle and JpTakeoverAllowedHere(vid), re-runs the
  // recovery of view vid with this replica as coordinator. Returns the view
  // taken over, or 0.
  epoch_t JpTakeoverTick(int64_t now_us);
  // Whether this replica can lead view v if it takes v over (else *why).
  // MongodbServer: only next to the primary of term v (directConnection).
  virtual bool JpTakeoverAllowedHere(epoch_t v, std::string* why) { return true; }
  // JETPACK_REJOIN=1 (a restarted replica) and Jetpack recovery enabled.
  static bool JpRejoinRequested();
  // T_rejoin = the backend term learned after the restart (the first
  // one counts); logs. No-op unless amnesiac.
  void JpLearnRejoinTerm(uint64_t term, const char* source);
  // T_rejoin cannot be learned: stays amnesiac, Log_error once.
  void JpRejoinTermUnavailable(const char* tag, const char* why);
  // The rejoin startup line of a replication server (from its Setup).
  void JpLogRejoinState(const char* tag);
  // Installs FinishRecovery(v) of this coordinator's own recovery at its own
  // replica (only after n/2 other replicas installed it); logs and
  // writes the replica-side finish signals like the RPC handler.
  bool JpFinishLocally(epoch_t v, const View& target);
  // The MongoDB / ZooKeeper term poller, one coroutine per replica (all
  // locales), every JpLeaderPollMs(). Sources: the term-bearing signal line
  // "<role>:<prefix> term=T [loc=L]" (acted on only without loc= or with
  // loc= this locale) and, if probe is set, self-detection of the co-located
  // backend node leading term T. Each term above everything handled or
  // baselined (JpTermTrigger) calls JetpackRecoveryEntry(View(n, site_id_, T),
  // emit_ack=true) once. Legacy term-less lines are ignored with one warning
  // per process. Returns once *alive is false (server destroyed).
  void JpRunTermPoller(const char* tag, const std::string& role, const std::string& prefix,
                       const std::shared_ptr<JetpackLeaderProbe>& probe,
                       const std::shared_ptr<std::atomic<bool>>& alive);
  enum JpValidity {
    kJpValid = 0,
    kJpSuperseded,          // joined a newer recovery
    kJpFinishedElsewhere,   // v (or newer) is already installed here
    kJpNotCoordinator,      // demoted (Raft) or shut down
    kJpTakenOver,           // another coordinator of v promised a higher ballot
  };
  static const char* JpValidityName(JpValidity r);
  JpValidity JpCheckValid(epoch_t v);
  void JpStartDriverIfNeeded();
  // Returns once *alive is false (the server was deleted).
  void JpDriverLoop(const std::shared_ptr<std::atomic<bool>>& alive);
  // One recovery for target.view_id_ with round-local state only.
  void JetpackRunRecovery(const View& target);
  // Right after this coordinator's Accept(v, vn, b) succeeded: its own
  // replica takes part at ballot b too (its own Accept may still be in
  // flight), so no lower same-view FinishRecovery installs another leader
  // here (jp_fr_floor_). An amnesiac replica only raises the floor. Not
  // valid (and nothing changed) if the own replica is past v or promised a
  // higher ballot of v (taken over).
  JpValidity JpOwnAccept(const View& target, epoch_t vn, ballot_t b,
                         const shared_ptr<KeyCmdBatchData>& value);
  // Waits for e in slices, re-validating after every slice. Returns kJpValid
  // when e is ready or the deadline passed.
  JpValidity JpWaitValid(const shared_ptr<Event>& e, epoch_t v, int64_t deadline_us);
  JpValidity JpSleepValid(epoch_t v, int64_t sleep_us);
  // Resubmits every member of the chosen value (plus, for Raft, the term-v
  // stability marker) through this server's own replication coordinator.
  // Returns kJpValid once every member returned SUCCESS. (vn, b) is the
  // instance and ballot at which the value was chosen: with takeover
  // enabled (JpTakeoverEnabled) the Accept is re-sent every
  // jp::kKeepaliveEveryUs while resubmitting, and its replies
  // stop the resubmission when the recovery was superseded, finished
  // elsewhere or taken over.
  JpValidity JpResubmitAll(const View& target, const shared_ptr<KeyCmdBatchData>& value,
                           bool with_marker, epoch_t vn, ballot_t b);
  // Resends FinishRecovery(v) to the replicas not yet done until all
  // are done or a newer view shows up. Runs as its own coroutine; returns
  // once *alive is false (the server was deleted).
  void JpFinishStragglers(epoch_t v, View target, std::set<siteid_t> done,
                          std::shared_ptr<std::atomic<bool>> alive);
  // True if the driver/coordinator must stop resending FR(v).
  bool JpNewerViewSeen(epoch_t v) const {
    return jp_pending_view_ > v || oepoch_ > v || jepoch_ > v;
  }
  bool JpUsesStabilityMarker() const;
  std::string JpSignalHost();
  void JpWriteFinishSignals();

  // ---- replica handlers (non-yielding; all state through rep_sched_)
  void OnJetpackPullRecovery(const epoch_t& v,
                             const ballot_t& b,
                             const MarshallDeputy& new_view,
                             bool_t* ok,
                             epoch_t* reply_view_id,
                             epoch_t* reply_vid,
                             ballot_t* reply_promised,
                             const shared_ptr<KeyCmdBatchData>& acked,
                             const shared_ptr<JetpackAcceptedMapData>& accepted);

  void OnJetpackAccept(const epoch_t& v,
                       const epoch_t& vn,
                       const ballot_t& b,
                       const MarshallDeputy& value,
                       bool_t* ok,
                       epoch_t* reply_view_id,
                       epoch_t* reply_vid,
                       ballot_t* reply_promised);

  void OnJetpackFinishRecovery(const epoch_t& u,
                               const ballot_t& b,
                               const MarshallDeputy& new_view,
                               bool_t* applied,
                               epoch_t* reply_view_id,
                               epoch_t* reply_vid);
  /* Jetpack recovery end */
};

} // namespace janus
