#include "__dep__.h"
#include "constants.h"
#include "tx.h"
#include "scheduler.h"
#include "rcc/graph.h"
#include "rcc/graph_marshaler.h"
#include "marshal-value.h"
#include "procedure.h"
#include "rcc_rpc.h"
#include "frame.h"
#include "bench/tpcc/workload.h"
#include "executor.h"
#include "coordinator.h"
#include "classic/coordinator.h"
#include "../bench/rw/workload.h"
#include "raft/server.h"
#include "config.h"
#include "communicator.h"

#include <algorithm>
#include <gperftools/profiler.h>
#include <cstdlib>
#include <exception>
#include <fstream>
#include <sstream>

#include "../../jm_file_signal.h"
#include "jetpack_term_source.h"

namespace janus {

static bool ReadCpuStatsInternal(int core, CpuStatSnapshot* out) {
  std::ifstream file("/proc/stat");
  if (!file.is_open()) {
    return false;
  }
  std::string line;
  // Skip aggregate and prior cores.
  for (int i = 0; i <= core + 1; ++i) {
    if (!std::getline(file, line)) {
      return false;
    }
  }
  std::istringstream iss(line);
  std::string label;
  iss >> label >> out->user >> out->nice >> out->system >> out->idle
      >> out->iowait >> out->irq >> out->softirq >> out->steal;
  return true;
}

double TxLogServer::ComputeCpuUsage(const CpuStatSnapshot& old_stats, const CpuStatSnapshot& new_stats) {
  auto total_diff = new_stats.Total() - old_stats.Total();
  auto idle_diff = new_stats.IdleTime() - old_stats.IdleTime();
  if (total_diff == 0) {
    return -1.0;
  }
  return 100.0 * (1.0 - static_cast<double>(idle_diff) / static_cast<double>(total_diff));
}

bool TxLogServer::ReadCpuStats(int core, CpuStatSnapshot* out) {
  return ReadCpuStatsInternal(core, out);
}

void TxLogServer::StartCpuMonitorIfNeeded() {
  if (cpu_monitor_started_) {
    return;
  }
  cpu_monitor_started_ = true;
  cpu_monitor_stop_ = false;
  Coroutine::CreateRun([this]() {
    // Read configured server core (default 1). Matches SERVER_CORE_ID env
    // var used for thread pinning and for the mid-10s sampling in s_main.
    const int core_id = server_core_id.load(std::memory_order_relaxed);
    CpuStatSnapshot prev{};
    bool has_prev = false;
    while (!cpu_monitor_stop_) {
      CpuStatSnapshot curr{};
      if (ReadCpuStats(core_id, &curr)) {
        if (has_prev) {
          double usage = ComputeCpuUsage(prev, curr);
          last_cpu_usage_ = usage;
        }
        prev = curr;
        has_prev = true;
      }
      Reactor::CreateSpEvent<TimeoutEvent>(200 * 1000)->Wait();
    }
  });
}

double TxLogServer::SampleCpuUsage() {
  // Synchronous cached read — cheaper + more reliable than the
  // Coroutine::CreateRun sampler which never published a sample on
  // some builds (the adaptive throttle was observing -1.0 consistently).
  // Rate-limited to ~1 /proc/stat read per 200 ms per thread (matches the
  // old cadence), so the per-request cost is a handful of nanoseconds
  // plus one syscall every 200 ms.
  thread_local CpuStatSnapshot prev{};
  thread_local bool has_prev = false;
  thread_local std::chrono::steady_clock::time_point last_read{};
  thread_local double cached_usage = -1.0;

  auto now = std::chrono::steady_clock::now();
  bool first = !has_prev;
  bool due = has_prev &&
             std::chrono::duration_cast<std::chrono::milliseconds>(now - last_read).count() >= 200;
  if (first || due) {
    CpuStatSnapshot curr{};
    if (ReadCpuStats(server_core_id.load(std::memory_order_relaxed), &curr)) {
      if (has_prev) {
        double usage = ComputeCpuUsage(prev, curr);
        if (usage >= 0.0) {
          cached_usage = usage;
          last_cpu_usage_ = usage;
        }
      }
      prev = curr;
      has_prev = true;
      last_read = now;
    }
  }
  return cached_usage;
}

shared_ptr<Tx> TxLogServer::CreateTx(epoch_t epoch, txnid_t tid, bool
read_only) {
  Log_debug("create tid %ld", tid);
  verify(dtxns_.find(tid) == dtxns_.end());
  if (epoch == 0) {
    epoch = epoch_mgr_.curr_epoch_;
  }
  verify(epoch_mgr_.IsActive(epoch));
  auto dtxn = frame_->CreateTx(epoch, tid, read_only, this);
  if (dtxn != nullptr) {
    dtxns_[tid] = dtxn;
    dtxn->recorder_ = this->recorder_;
    dtxn->txn_reg_ = txn_reg_;
    verify(txn_reg_ != nullptr);
    verify(dtxn->tid_ == tid);
  } else {
    verify(0);
  }
  if (epoch_enabled_) {
    epoch_mgr_.AddToEpoch(epoch, tid);
    TriggerUpgradeEpoch();
  }
  dtxn->sched_ = this;
  return dtxn;
}

shared_ptr<Tx> TxLogServer::CreateTx(txnid_t tx_id, bool ro) {
  Log_debug("create tid %" PRIx64, tx_id);
  verify(dtxns_.find(tx_id) == dtxns_.end());
  auto dtxn = frame_->CreateTx(epoch_mgr_.curr_epoch_, tx_id, ro, this);
  if (dtxn != nullptr) {
    dtxns_[tx_id] = dtxn;
    dtxn->recorder_ = this->recorder_;
    verify(txn_reg_);
    dtxn->txn_reg_ = txn_reg_;
    verify(dtxn->tid_ == tx_id);
    if (epoch_enabled_) {
      epoch_mgr_.AddToCurrent(tx_id);
      TriggerUpgradeEpoch();
    }
    dtxn->sched_ = this;
  } else {
    // for multi-paxos this would happen.
    // verify(0);
  }
  return dtxn;
}

shared_ptr<Tx> TxLogServer::GetOrCreateTx(txnid_t tid, bool ro) {
  //Log_info("The current server is %d", site_id_);
  shared_ptr<Tx> ret = nullptr;
  auto it = dtxns_.find(tid);
  if (it == dtxns_.end()) {
    ret = CreateTx(tid, ro);
  } else {
    ret = it->second;
  }
  //Log_info("Tx is %ld", tid);
  verify(ret != nullptr);
  verify(ret->tid_ == tid);
  return ret;
}
void TxLogServer::DestroyTx(i64 tid) {
  Log_debug("destroy tid %lx", tid);
  auto it = dtxns_.find(tid);
  // verify(it != dtxns_.end());
  if (it != dtxns_.end()) {
    dtxns_.erase(it);
  }
}

shared_ptr<Tx> TxLogServer::GetTx(txnid_t tid) {
  // Log_debug("DTxnMgr::get(%ld)\n", tid);
  auto it = dtxns_.find(tid);
  // verify(it != dtxns_.end());
  if (it != dtxns_.end()) {
    return it->second;
  } else {
    return nullptr;
  }
}

mdb::Txn *TxLogServer::GetMTxn(const i64 tid) {
  mdb::Txn *txn = nullptr;
  auto it = mdb_txns_.find(tid);
  if (it == mdb_txns_.end()) {
    verify(0);
  } else {
    txn = it->second;
  }
  return txn;
}

mdb::Txn *TxLogServer::RemoveMTxn(const i64 tid) {
  mdb::Txn *txn = nullptr;
  auto it = mdb_txns_.find(tid);
  verify(it != mdb_txns_.end());
  txn = it->second;
  mdb_txns_.erase(it);
  return txn;
}

mdb::Txn *TxLogServer::GetOrCreateMTxn(const i64 tid) {
  mdb::Txn *txn = nullptr;
  auto it = mdb_txns_.find(tid);
  if (it == mdb_txns_.end()) {
    txn = mdb_txn_mgr_->start(tid);
    // using occ lazy mode: increment version at commit time
    auto mode = Config::GetConfig()->tx_proto_;
    if (mode == MODE_OCC || mode == MODE_MDCC) {
      ((mdb::TxnOCC *) txn)->set_policy(mdb::OCC_LAZY);
    }
    auto ret = mdb_txns_.insert(std::pair<i64, mdb::Txn *>(tid, txn));
    verify(ret.second);
  } else {
    txn = it->second;
  }

  if (IS_MODE_2PL) {
    verify(mdb_txn_mgr_->rtti() == mdb::symbol_t::TXN_2PL);
    verify(txn->rtti() == mdb::symbol_t::TXN_2PL);
  } else {

  }
  verify(txn != nullptr);
  return txn;
}

// TODO move this to the dtxn class
void TxLogServer::get_prepare_log(i64 txn_id,
                                  const std::vector<i32> &sids,
                                  std::string *str) {
  auto it = mdb_txns_.find(txn_id);
  verify(it != mdb_txns_.end() && it->second != NULL);

  // marshal txn_id
  uint64_t len = str->size();
  str->resize(len + sizeof(txn_id));
  memcpy((void *) (str->data()), (void *) (&txn_id), sizeof(txn_id));
  len += sizeof(txn_id);
  verify(len == str->size());

  // p denotes prepare log
  const char prepare_tag = 'p';
  str->resize(len + sizeof(prepare_tag));
  memcpy((void *) (str->data() + len),
         (void *) &prepare_tag,
         sizeof(prepare_tag));
  len += sizeof(prepare_tag);
  verify(len == str->size());

  // marshal related servers
  uint32_t num_servers = sids.size();
  str->resize(len + sizeof(num_servers) + sizeof(i32) * num_servers);
  memcpy((void *) (str->data() + len),
         (void *) &num_servers,
         sizeof(num_servers));
  len += sizeof(num_servers);
  for (uint32_t i = 0; i < num_servers; i++) {
    memcpy((void *) (str->data() + len), (void *) (&(sids[i])), sizeof(i32));
    len += sizeof(i32);
  }
  verify(len == str->size());

  switch (mode_) {
    case MODE_2PL:
    case MODE_OCC:((mdb::Txn2PL *) it->second)->marshal_stage(*str);
      break;
    default:verify(0);
  }
}

TxLogServer::TxLogServer() : mtx_() {
  command_pool_.set_owner(this);
  mdb_txn_mgr_ = make_shared<mdb::TxnMgrUnsafe>();
  // A restarted replica is amnesiac before it serves its first RPC.
  if (JpRejoinRequested()) {
    jp_rejoin_ = jp::RejoinState(true);
  }
  if (Config::GetConfig()->do_logging()) {
    auto path = Config::GetConfig()->log_path();
    // TODO free this
//    recorder_ = new Recorder(path);
  }
}

Coordinator *TxLogServer::CreateRepCoord(const i64& dep_id) {
  Coordinator *coord;
  static cooid_t cid = 0;
  int32_t benchmark = 0;
  static id_t id = 0;
  verify(rep_frame_ != nullptr);
  coord = rep_frame_->CreateCoordinator(cid++,
                                        Config::GetConfig(),
                                        benchmark,
                                        nullptr,
                                        id++,
                                        txn_reg_);
  coord->frame_ = rep_frame_;
  coord->dep_id_ = dep_id;
  coord->par_id_ = partition_id_;
  //Log_info("Partition id set: %d", partition_id_);
  coord->loc_id_ = this->loc_id_;
  coord->dep_id_ = dep_id;
  return coord;
}


TxLogServer::TxLogServer(int mode) : TxLogServer() {
  mode_ = mode;
  switch (mode) {
    case MODE_MDCC:
    case MODE_OCC:
      mdb_txn_mgr_ = make_shared<mdb::TxnMgrOCC>();
      break;
    case MODE_NONE:
    case MODE_RPC_NULL:
    case MODE_RCC:
    case MODE_RO6:
      mdb_txn_mgr_ = make_shared<mdb::TxnMgrUnsafe>();
      break;
    default:verify(0);
  }
}

TxLogServer::~TxLogServer() {
  // The recovery driver and FinishRecovery stragglers stop at their next
  // wake-up (the reactor keeps running after ServerWorker::ShutDown).
  jp_alive_->store(false);
  auto it = mdb_txns_.begin();
  for (; it != mdb_txns_.end(); it++)
    Log::info("tid: %ld still running", it->first);
  if (it != mdb_txns_.end() && it->second) {
    delete it->second;
    it->second = NULL;
  }
  mdb_txns_.clear();
  cpu_monitor_stop_ = true;
#ifdef CPU_PROFILE_SEVER
  if (site_id_ == 0) {
    ProfilerStop();
  }
#endif
  cpu_monitor_stop_ = true;
  std::vector<double> pool_size_distribution = command_pool_.pool_size_distribution();
  Log_info("loc_id=%d command pool size distribution 50pct %.2f 90pct %.2f 99pct %.2f ave %.2f",
    loc_id_, pool_size_distribution[0], pool_size_distribution[1], pool_size_distribution[2], pool_size_distribution[3]);
  if (rep_sched_ == nullptr) {
    // The fast-path gate counts on the replication server; the tx
    // scheduler in front of it would only print zeros.
    Log_info("loc_id=%d jetpack fast-path rejects not_ready %" PRIu64 " view_mismatch %" PRIu64
             " view=%u vid=%u",
             loc_id_, jp_fp_not_ready_, jp_fp_view_mismatch_, jepoch_, oepoch_);
  }
#ifdef COMMAND_POOL_LOG_DEBUG
  if (loc_id_ == 0 || loc_id_ == 1)
    command_pool_.print_log();
#endif

}

/**
 *
 * @param txn_box
 * @param inn_id, if 0, execute all pieces.
 */
void TxLogServer::Execute(Tx &txn_box,
                          innid_t inn_id) {
  if (inn_id == 0) {
    for (auto &pair : txn_box.paused_pieces_) {
      auto &up_pause = pair.second;
      verify(up_pause);
      up_pause->Set(1);
    }
    txn_box.paused_pieces_.clear();
  } else {
    auto &up_pause = txn_box.paused_pieces_[inn_id];
    verify(up_pause);
    up_pause->Set(1);
    txn_box.paused_pieces_.erase(inn_id);
  }
}

void TxLogServer::reg_table(const std::string &name,
                            mdb::Table *tbl) {
  verify(mdb_txn_mgr_ != NULL);
  mdb_txn_mgr_->reg_table(name, tbl);
  if (name == TPCC_TB_ORDER) {
    mdb::Schema *schema = new mdb::Schema();
    const mdb::Schema *o_schema = tbl->schema();
    mdb::Schema::iterator it = o_schema->begin();
    for (; it != o_schema->end(); it++)
      if (it->indexed)
        if (it->name != "o_id")
          schema->add_column(it->name.c_str(), it->type, true);
    schema->add_column("o_c_id", Value::I32, true);
    schema->add_column("o_id", Value::I32, false);
    mdb_txn_mgr_->reg_table(TPCC_TB_ORDER_C_ID_SECONDARY,
                            new mdb::SortedTable(name, schema));
  }
}

void TxLogServer::DestroyExecutor(txnid_t txn_id) {
  Log_debug("destroy tid %ld\n", txn_id);
  auto it = executors_.find(txn_id);
  verify(it != executors_.end());
  auto exec = it->second;
  executors_.erase(it);
  delete exec;
}

void TxLogServer::Pause() {
  Log_info("!!!!!!!! TxLogServer::Pause()");
  commo_->Pause();
  paused_ = true;
  Log_info("[PAUSE_STATE] TxLogServer=%p paused_=1 comm_paused=%d",
           (void*) this, commo_ ? commo_->paused : -1);
};

void TxLogServer::Resume() {
  commo_->Resume();
  paused_ = false;
};

void TxLogServer::TriggerUpgradeEpoch() {
  if (site_id_ == 0) {
    auto t_now = std::time(nullptr);
    auto d = std::difftime(t_now, last_upgrade_time_);
    if (d < EPOCH_DURATION || in_upgrade_epoch_) {
      return;
    }
    last_upgrade_time_ = t_now;
    in_upgrade_epoch_ = true;
    epoch_t epoch = epoch_mgr_.curr_epoch_;
    commo()->SendUpgradeEpoch(epoch,
                              std::bind(&TxLogServer::UpgradeEpochAck,
                                        this,
                                        std::placeholders::_1,
                                        std::placeholders::_2,
                                        std::placeholders::_3));
  }
}

void TxLogServer::UpgradeEpochAck(parid_t par_id,
                                  siteid_t site_id,
                                  int32_t res) {
  auto parids = Config::GetConfig()->GetAllPartitionIds();
  epoch_replies_[par_id][site_id] = res;
  if (epoch_replies_.size() < parids.size()) {
    return;
  }
  for (auto &pair: epoch_replies_) {
    auto par_id = pair.first;
    auto par_size = Config::GetConfig()->GetPartitionSize(par_id);
    verify(epoch_replies_[par_id].size() <= par_size);
    if (epoch_replies_[par_id].size() != par_size) {
      return;
    }
  }

  epoch_t smallest_inactive = 0xFFFFFFFF;
  for (auto &pair1 : epoch_replies_) {
    for (auto &pair2 : pair1.second) {
      if (smallest_inactive > pair2.second) {
        smallest_inactive = pair2.second;
      }
    }
  }
  in_upgrade_epoch_ = false;
  epoch_replies_.clear();
  int x = 5;
  if (smallest_inactive >= x) {
    epoch_t epoch_to_truncate = smallest_inactive - x;
    if (epoch_to_truncate >= epoch_mgr_.oldest_active_) {
      Log_info("truncate epoch %d", epoch_to_truncate);
      commo()->SendTruncateEpoch(epoch_to_truncate);
    }
  }
}

int32_t TxLogServer::OnUpgradeEpoch(uint32_t old_epoch) {
  epoch_mgr_.GrowActive();
  epoch_mgr_.GrowBuffer();
  return epoch_mgr_.CheckBufferInactive();
}

UniqueCmdID TxLogServer::GetUniqueCmdID(shared_ptr<Marshallable> cmd) {
  shared_ptr<vector<shared_ptr<SimpleCommand>>> sp_vec_piece{nullptr};
  if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT) {
    shared_ptr<TpcCommitCommand> tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
    VecPieceData *cmd_cast = (VecPieceData*)(tpc_cmd->cmd_.get());
    sp_vec_piece = cmd_cast->sp_vec_piece_data_;
  } else if (cmd->kind_ == MarshallDeputy::CMD_VEC_PIECE) {
    shared_ptr<VecPieceData> cmd_cast = dynamic_pointer_cast<VecPieceData>(cmd);
    sp_vec_piece = cmd_cast->sp_vec_piece_data_;
  } else {
    verify(0);
  }
  shared_ptr<TxPieceData> vector0 = *(sp_vec_piece->begin());
  shared_ptr<CmdData> casted_cmd = dynamic_pointer_cast<CmdData>(vector0);
  UniqueCmdID cmd_id;
  cmd_id.client_id_ = casted_cmd->client_id_;
  cmd_id.cmd_id_ = casted_cmd->cmd_id_in_client_;
  return cmd_id;
}

value_t TxLogServer::DBGet(const shared_ptr<Marshallable>& cmd) {
  shared_ptr<SimpleRWCommand> parsed_cmd_ = make_shared<SimpleRWCommand>(cmd);
  return kv_table_[parsed_cmd_->key_];
}

value_t TxLogServer::DBPut(const shared_ptr<Marshallable>& cmd) {
  shared_ptr<SimpleRWCommand> parsed_cmd_ = make_shared<SimpleRWCommand>(cmd);
  kv_table_[parsed_cmd_->key_] = parsed_cmd_->value_;
  return 1;
}


// below are about rule

double TxLogServer::GetQueueDepthForRule() {
  if (rep_sched_) {
    return rep_sched_->request_queues_depth_.recent_100_ave();
  }
  return request_queues_depth_.recent_100_ave();
}

void TxLogServer::OnRuleSpeculativeExecute(const shared_ptr<Marshallable>& cmd,
                    epoch_t req_view,
                    bool_t* accepted,
                    value_t* result,
                    bool_t* is_leader,
                    double* cpu_usage,
                    double* queue_depth,
                    epoch_t* reply_view) {
#ifdef JETPACK_PROF
  auto prof_t0 = std::chrono::steady_clock::now();
#endif
  // All Jetpack state lives on the replication server; this tx_sched_'s own
  // jepoch_/jetpack_status_ are never updated.
  TxLogServer* rs = rep_sched_ ? rep_sched_ : this;
  // First, so that every return path carries it (the generated wrapper's
  // outputs start uninitialized): the installed view, also in RECOVERY.
  *reply_view = rs->jepoch_;
  if (paused_) { // [Jetpack] Bad fix, should be blocked from handle_write, not to this layer
    *accepted = false;
    *result = 0;
    *is_leader = false;
    if (cpu_usage) *cpu_usage = -1.0;
    if (queue_depth) *queue_depth = -1.0;
    return;
  }
  // View gate, decided without yielding and before the CURP branch and
  // the ZERO_OVERHEAD variant: ack only if READY and the request was sent in
  // the installed view. Outside Jetpack recovery every replica stays READY in
  // view 0 and clients send view 0, so the gate never fires there. An
  // amnesiac replica (restarted with an empty pool) acks nothing until it
  // installs a fresh view.
  const bool ready = rs->jetpack_status_ == JetpackStatus::READY && rs->jp_rejoin_.AckAllowed();
  const bool view_ok = jp::AckAllowed(ready, rs->jepoch_, req_view);
  bool no_conflict;
  if (!view_ok) {
    no_conflict = false;
    if (!ready) {
      // RECOVERY (or amnesiac): nothing is inserted (push_back refuses in
      // RECOVERY as well; an amnesiac pool is cleared when it rejoins).
      rs->jp_fp_not_ready_++;
    } else {
      rs->jp_fp_view_mismatch_++;
      // Record the command as a non-acked conflict guard. Its Dispatch is
      // not view-gated, so it may sit in the leader's log ahead of a later
      // conflicting command of this view; it never becomes the bucket's
      // to_recover entry and is GC'd when it commits.
      if (!Config::GetConfig()->IsCurpMode()) {
        rs->command_pool_.push_back(cmd, /*allow_ack=*/false);
      }
    }
  } else if (Config::GetConfig()->IsCurpMode()) {
    // CURP path: every replica records the optimistic attempt in its
    // own witness and signals back whether any in-flight attempt on
    // the same key would conflict (write-write or write-read).
    no_conflict = rep_sched_->curp_witness_.record_attempt(cmd);
  } else {
    // Jetpack path (all replicas) or CURP non-leader (witness): check command pool
#ifdef ZERO_OVERHEAD
#ifdef JETPACK_PROF
    auto pool_t0 = std::chrono::steady_clock::now();
#endif
    no_conflict = rep_sched_->command_pool_.push_back(cmd) && !rep_sched_->ConflictWithOriginalUnexecutedLog(cmd);
#ifdef JETPACK_PROF
    auto pool_t1 = std::chrono::steady_clock::now();
    rep_sched_->prof_pool_push_calls_.fetch_add(1, std::memory_order_relaxed);
    rep_sched_->prof_pool_push_ns_.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(pool_t1 - pool_t0).count(),
        std::memory_order_relaxed);
#endif
#else
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-DEBUG] OnRuleSpeculativeExecute about to push_back loc_id %d ", loc_id_);
#endif
#ifdef JETPACK_PROF
    auto pool_t0 = std::chrono::steady_clock::now();
#endif
    // Leader-side cross-path conflict check before touching the pool.
    // pool.push_back ALWAYS appends (it returns conflict status but
    // still inserts). If we push first and discover a cross-path
    // conflict via the map, the pool ends up holding a phantom entry
    // for a rejected fast-path attempt — that attempt never makes it
    // to Raft, so applyLogs never runs GC for it, and the entry
    // false-positive-conflicts every future fast-path on the same key.
    bool skip_pool_conflict = false;
    if (Config::GetConfig()->GetJetpackSkipPoolForOriginalPath() &&
        rep_sched_->IsLeader()) {
      skip_pool_conflict = rep_sched_->ConflictWithOriginalUnexecutedLog(cmd);
    }
    if (skip_pool_conflict) {
      no_conflict = false;
    } else {
      no_conflict = rep_sched_->command_pool_.push_back(cmd);
    }
#ifdef JETPACK_PROF
    auto pool_t1 = std::chrono::steady_clock::now();
    rep_sched_->prof_pool_push_calls_.fetch_add(1, std::memory_order_relaxed);
    rep_sched_->prof_pool_push_ns_.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(pool_t1 - pool_t0).count(),
        std::memory_order_relaxed);
#endif
#endif
  }
  if (no_conflict) {
    // SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
    // Log_info("Server %d OnRuleSpeculativeExecute <%d, %d> key %d", rep_sched_->loc_id_, parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second, parsed_cmd.key_);
    // Log_info("command_pool_.push_back server %d push cmd_id <%d, %d> %lld key %d success 1", loc_id_, parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second,
      // (long long)SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second), parsed_cmd.key_);
    // verify(command_pool_.remove(cmd));
    *accepted = true;
    // [RULE] TODO: return speculative result
    *result = 0;
  } else {
    *accepted = false;
    *result = 0;
  }
  // The proposer of the request's view (IsLeader() outside
  // Jetpack recovery).
  *is_leader = rs->JetpackIsProposerOf(req_view);
  if (cpu_usage) {
    *cpu_usage = SampleCpuUsage();
  }
  if (queue_depth) {
    *queue_depth = GetQueueDepthForRule();
  }
#ifdef JETPACK_PROF
  auto prof_t1 = std::chrono::steady_clock::now();
  prof_spec_calls_.fetch_add(1, std::memory_order_relaxed);
  prof_spec_ns_.fetch_add(
      std::chrono::duration_cast<std::chrono::nanoseconds>(prof_t1 - prof_t0).count(),
      std::memory_order_relaxed);
#endif
}

void TxLogServer::OriginalPathUnexecutedCmdConflictPlaceHolder(const shared_ptr<Marshallable>& cmd) {
  if (Config::GetConfig()->tx_proto_ == MODE_RULE && SimpleRWCommand::NeedRecordConflictInOriginalPath(cmd)) {
    // Optimization gate: when jetpack_skip_pool_for_original_path is on,
    // the command pool only tracks fast-path-attempted commands.
    // Original-path-only commands (which is what NeedRecordConflictInOriginalPath
    // identifies) are instead tracked in a small per-replica map that
    // the leader's ConflictWithOriginalUnexecutedLog iterates directly.
    // RuleCommandPoolGC removes from the same map — see below.
    if (Config::GetConfig()->GetJetpackSkipPoolForOriginalPath()) {
      // Track original-path-only commands in the lean key-indexed map
      // and SKIP the pool entirely. The leader uses
      // ConflictWithOriginalUnexecutedLog to consult this map for
      // cross-path conflict detection on every fast-path attempt.
      // Followers don't have an authoritative uncommitted log, so they
      // fall back to consulting the pool (which still tracks fast-path
      // attempts) — they may miss cross-path conflicts, matching
      // baseline behavior since OriginalPathUnexecutedCmdConflictPlaceHolder
      // was already leader-only via service.cc:Dispatch.
      key_t key;
      uint64_t cmd_id;
      bool is_write;
      if (SimpleRWCommand::ExtractPoolKeys(cmd, &key, &cmd_id, &is_write)) {
        rep_sched_->inflight_original_path_[key].push_back({cmd_id, is_write});
      }
      return;
    }
    rep_sched_->command_pool_.push_back(cmd);
  }
}

void TxLogServer::RuleCommandPoolGC(const shared_ptr<Marshallable>& cmd) {
  if (Config::GetConfig()->tx_proto_ == MODE_RULE) {
    // CURP path: clear the just-applied attempt from this replica's
    // witness so future attempts on the same key see it as no longer
    // in flight. Returns the count of cleared entries (0 on a replica
    // that never witnessed this cmd, e.g. the leader when the spec
    // broadcast was configured to skip it).
    if (Config::GetConfig()->IsCurpMode()) {
      curp_witness_.clear_attempt(cmd);
      return;
    }
    // Optimization gate: when jetpack_skip_pool_for_original_path is on,
    // original-path-only commands were never pushed to the pool — they
    // were tracked in inflight_original_path_ instead. Erase by cmd_id.
    // Fast-path commands still go through the pool as usual.
    if (Config::GetConfig()->GetJetpackSkipPoolForOriginalPath() &&
        SimpleRWCommand::NeedRecordConflictInOriginalPath(cmd)) {
      // applyLogs calls RuleCommandPoolGC with `this == RaftServer`, so
      // the map lives on `this` (NOT `rep_sched_` — RaftServer's
      // rep_sched_ field is null). The companion insert path runs from
      // tx_sched_ (where `this` is SchedulerNone) and writes to
      // rep_sched_->inflight_original_path_ — which IS the same map,
      // since rep_sched_ on tx_sched_ points to this RaftServer.
      key_t key;
      uint64_t cmd_id;
      bool is_write;
      if (SimpleRWCommand::ExtractPoolKeys(cmd, &key, &cmd_id, &is_write)) {
        auto it = inflight_original_path_.find(key);
        if (it != inflight_original_path_.end()) {
          auto& bucket = it->second;
          for (auto bit = bucket.begin(); bit != bucket.end(); ++bit) {
            if (bit->cmd_id == cmd_id) {
              bucket.erase(bit);
              break;
            }
          }
          if (bucket.empty()) {
            inflight_original_path_.erase(it);
          }
        }
      }
      return;
    }
    command_pool_.remove(cmd);
  }
  // SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
  // uint64_t cmd_id = SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second);
  // Log_info("command_pool_.remove server %d remove cmd_id <%d, %d> %lld key %d success %d", loc_id_, parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second,
  //     (long long)SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second), parsed_cmd.key_, command_pool_.remove(cmd));
  // Log_info("command_pool_.remove(cmd) %d", command_pool_.remove(cmd));
  // command_pool_.remove(cmd);
}


void RevoveryCandidates::insert(uint64_t cmd_id, shared_ptr<Marshallable> cmd,
                                bool is_write, bool acked) {
  candidates_[cmd_id] = Entry{cmd, is_write, acked};
  if (acked && is_write) {
    // An acked write needs a conflict-free bucket, so no other write exists.
    verify(total_write_ == 0 && to_recover_id_ == (uint64_t)(-1));
    to_recover_id_ = cmd_id;
  }
  total_write_ += is_write;
#ifdef JETPACK_DEDUPLICATE_OPTIMIZATION
  appeared_[cmd_id] = true;
#endif
}

const RevoveryCandidates::Entry* RevoveryCandidates::find(uint64_t cmd_id) const {
  auto it = candidates_.find(cmd_id);
  return it == candidates_.end() ? nullptr : &it->second;
}

bool RevoveryCandidates::remove(uint64_t cmd_id) {
  auto it = candidates_.find(cmd_id);
  if (it != candidates_.end()) {
    // is_write is cached in Entry — no SimpleRWCommand reparse needed.
    bool was_write = it->second.is_write;
    if (total_write_ == 1 && was_write) {
      to_recover_id_ = (uint64_t)(-1);
    }
    total_write_ -= was_write;
    candidates_.erase(it);
    return 1;
  } else {
    return 0;
  }
}

bool RevoveryCandidates::has_appeared(uint64_t cmd_id) {
  return appeared_[cmd_id];
}

size_t RevoveryCandidates::size() const {
  return candidates_.size();
}

int RevoveryCandidates::total_write() const {
  return total_write_;
}

bool RevoveryCandidates::has_cmd_to_recover() const {
  return to_recover_id_ != (uint64_t)(-1);
}

shared_ptr<Marshallable> RevoveryCandidates::cmd_to_recover() const {
  if (to_recover_id_ != (uint64_t)(-1)) {
    auto it = candidates_.find(to_recover_id_);
    if (it != candidates_.end()) {
      return it->second.cmd;
    }
  }
  return nullptr;
}

shared_ptr<Marshallable> RevoveryCandidates::get_cmd(uint64_t cmd_id) const {
  auto it = candidates_.find(cmd_id);
  if (it != candidates_.end()) {
    return it->second.cmd;
  }
  return nullptr;
}

#ifdef COMMAND_POOL_ON_DISK
void JetpackCommandPool::OpenCommandPoolFile() {
  if (command_pool_file_.is_open()) {
    return;
  }
  if (owner_ == nullptr ||
      owner_->loc_id_ == std::numeric_limits<locid_t>::max()) {
    return;
  }
  command_pool_loc_id_ = owner_->loc_id_;
  const std::string path = "/tmp/command_pool_" + std::to_string(command_pool_loc_id_);
  command_pool_file_.open(path, std::ios::out | std::ios::trunc);
  if (!command_pool_file_.is_open()) {
    Log_warn("[COMMAND_POOL] failed to open %s", path.c_str());
  }
}

void JetpackCommandPool::CloseCommandPoolFile() {
  if (command_pool_file_.is_open()) {
    command_pool_file_.close();
  }
}

void JetpackCommandPool::WriteCommandToDisk(const SimpleRWCommand& cmd) {
  if (!command_pool_file_.is_open()) {
    OpenCommandPoolFile();
  }
  if (command_pool_file_.is_open()) {
    command_pool_file_ << cmd.key_ << "," << cmd.value_ << "\n";
  }
}
#endif

JetpackCommandPool::~JetpackCommandPool() {
#ifdef COMMAND_POOL_ON_DISK
  CloseCommandPoolFile();
#endif
}

bool JetpackCommandPool::push_back(const shared_ptr<Marshallable>& cmd, bool allow_ack) {
  if (owner_ && owner_->jetpack_status_ == TxLogServer::JetpackStatus::RECOVERY) {
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-DEBUG] JetpackCommandPool::push_back rejected because Jetpack is recovering");
#endif
    return false;
  }
  // Extract key/cmd_id/is_write from cmd without copying the value map
  // (SimpleRWCommand's full ctor deep-copies it twice).
#ifdef JETPACK_PROF
  auto t_ext0 = std::chrono::steady_clock::now();
#endif
  key_t key;
  uint64_t cmd_id;
  bool is_write;
  if (!SimpleRWCommand::ExtractPoolKeys(cmd, &key, &cmd_id, &is_write)) {
    verify(0);
  }
#ifdef JETPACK_PROF
  auto t_ext1 = std::chrono::steady_clock::now();
#endif
  auto& bucket = candidates_[key];
#ifdef JETPACK_PROF
  auto t_lookup1 = std::chrono::steady_clock::now();
  if (owner_) {
    owner_->prof_pool_extract_ns_.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(t_ext1 - t_ext0).count(),
        std::memory_order_relaxed);
    owner_->prof_pool_outer_lookup_ns_.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(t_lookup1 - t_ext1).count(),
        std::memory_order_relaxed);
  }
#endif
  // A redelivered request gets its first verdict back and changes nothing.
  if (const auto* seen = bucket.find(cmd_id)) {
    return seen->acked;
  }
  bool was_empty = bucket.size() == 0;

#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-DEBUG] JetpackCommandPool::push_back called for key=%d, cmd_id=%lu allow_ack=%d",
           key, cmd_id, allow_ack);
#endif

#ifdef JETPACK_PROF
  auto t_inner0 = std::chrono::steady_clock::now();
#endif
#ifdef READ_NOT_CONFLICT_OPTIMIZATION
  bool no_conflict = bucket.total_write() == 0;
#else
  bool no_conflict = bucket.size() == 0;
#endif
  // Only an acked write becomes the bucket's to_recover entry; a non-acked
  // insert is recorded purely as a conflict guard.
  bool acked = allow_ack && no_conflict;
  bucket.insert(cmd_id, cmd, is_write, acked);
#ifdef JETPACK_RECOVERY_DEBUG
  if (acked) {
    Log_info("[JETPACK-DEBUG] Added cmd to candidates[%d], no conflict", key);
  } else {
    Log_info("[JETPACK-DEBUG] Added cmd to candidates[%d], not acked (size now=%zu)",
             key, bucket.size());
  }
#endif
#ifdef COMMAND_POOL_LOG_DEBUG
  pool_log_.push_back(CommandPoolLog(0, cmd, acked, pool_size_));
#endif
#ifdef COMMAND_POOL_ON_DISK
  if (acked) {
    // Disk write still needs value; fall back to full parse on the rare path.
    WriteCommandToDisk(SimpleRWCommand(cmd));
  }
#endif
  pool_cmd_count_++;
  // Also for a non-acked insert into an empty bucket, so that remove() (which
  // decrements when the last entry leaves) stays balanced.
  if (was_empty) {
    pool_size_distribution_.mid_time_append(++pool_size_);
  }
#ifdef JETPACK_PROF
  auto t_inner1 = std::chrono::steady_clock::now();
  if (owner_) {
    owner_->prof_pool_inner_insert_ns_.fetch_add(
        std::chrono::duration_cast<std::chrono::nanoseconds>(t_inner1 - t_inner0).count(),
        std::memory_order_relaxed);
    if (acked) {
      uint64_t prev_keys = owner_->prof_pool_peak_keys_.load(std::memory_order_relaxed);
      while ((uint64_t)pool_size_ > prev_keys &&
             !owner_->prof_pool_peak_keys_.compare_exchange_weak(prev_keys, pool_size_));
      uint64_t prev_cmds = owner_->prof_pool_peak_cmds_.load(std::memory_order_relaxed);
      while ((uint64_t)pool_cmd_count_ > prev_cmds &&
             !owner_->prof_pool_peak_cmds_.compare_exchange_weak(prev_cmds, pool_cmd_count_));
    }
  }
#endif
  return acked;
}

int JetpackCommandPool::remove(const shared_ptr<Marshallable>& cmd) {
#ifdef JETPACK_PROF
  auto t_rm0 = std::chrono::steady_clock::now();
  auto rm_bookkeep = [&]() {
    if (owner_) {
      auto t_rm1 = std::chrono::steady_clock::now();
      owner_->prof_pool_remove_calls_.fetch_add(1, std::memory_order_relaxed);
      owner_->prof_pool_remove_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(t_rm1 - t_rm0).count(),
          std::memory_order_relaxed);
    }
  };
#else
  auto rm_bookkeep = []() {};
#endif
  if (cmd->kind_ != MarshallDeputy::CMD_TPC_BATCH) {
    // Lightweight extract — no full SimpleRWCommand (saves ~1 μs per call at
    // 10k/s). Same optimization as push_back.
    key_t key;
    uint64_t cmd_id;
    bool is_write;  // unused in remove path, but cheap to compute
    if (!SimpleRWCommand::ExtractPoolKeys(cmd, &key, &cmd_id, &is_write)) {
      verify(0);
    }
    auto& bucket = candidates_[key];
    size_t before_size = bucket.size();
    bool removed = bucket.remove(cmd_id);
    if (removed) {
      pool_cmd_count_--;
      if (before_size == 1) {
        pool_size_distribution_.mid_time_append(--pool_size_);
      }
    }
#ifdef COMMAND_POOL_LOG_DEBUG
    pool_log_.push_back(CommandPoolLog(1, cmd, removed, pool_size_));
#endif
    rm_bookkeep();
    return removed;
  } else {
    auto cmds = dynamic_pointer_cast<TpcBatchCommand>(cmd);
    int total_removed = 0;
    for (auto& c: cmds->cmds_) {
      key_t key;
      uint64_t cmd_id;
      bool is_write;
      if (!SimpleRWCommand::ExtractPoolKeys(c, &key, &cmd_id, &is_write)) {
        verify(0);
      }
      auto& bucket = candidates_[key];
      size_t before_size = bucket.size();
      bool removed = bucket.remove(cmd_id);
      if (removed) {
        pool_cmd_count_--;
        if (before_size == 1) {
          pool_size_distribution_.mid_time_append(--pool_size_);
          // if (bucket.size() == 0) candidates_.erase(parsed_cmd.key_);
        }
        total_removed++;
      }
#ifdef COMMAND_POOL_LOG_DEBUG
      pool_log_.push_back(CommandPoolLog(1, c, removed, pool_size_));
#endif
    }
    rm_bookkeep();
    return total_removed;
  }
}

bool JetpackCommandPool::has_appeared(const shared_ptr<Marshallable>& cmd) {
#ifdef JETPACK_PROF
  auto t_ha0 = std::chrono::steady_clock::now();
  auto ha_bookkeep = [&]() {
    if (owner_) {
      auto t_ha1 = std::chrono::steady_clock::now();
      owner_->prof_pool_has_appeared_calls_.fetch_add(1, std::memory_order_relaxed);
      owner_->prof_pool_has_appeared_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(t_ha1 - t_ha0).count(),
          std::memory_order_relaxed);
    }
  };
#else
  auto ha_bookkeep = []() {};
#endif
  // For a batched command, return whether all of them have appeared
  if (cmd->kind_ != MarshallDeputy::CMD_TPC_BATCH) {
    SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
    uint64_t cmd_id = SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second);
    bool r = candidates_[parsed_cmd.key_].has_appeared(cmd_id);
    ha_bookkeep();
    return r;
  } else {
    auto cmds = dynamic_pointer_cast<TpcBatchCommand>(cmd);
    bool all_has_appeared = true;
    for (auto& c: cmds->cmds_) {
      SimpleRWCommand parsed_cmd = SimpleRWCommand(c);
      uint64_t cmd_id = SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second);
      if (!candidates_[parsed_cmd.key_].has_appeared(cmd_id)) {
        all_has_appeared = false;
        break;
      }
    }
    ha_bookkeep();
    return all_has_appeared;
  }
}

void JetpackCommandPool::set_owner(TxLogServer* owner) {
  owner_ = owner;
}

void JetpackCommandPool::set_belongs_to_leader(bool belongs_to_leader) {
  belongs_to_leader_ = belongs_to_leader;
}

std::vector<double> JetpackCommandPool::pool_size_distribution() {
  // Log_info("pool 50pct %d %.2f" , pool_size_distribution_.count(), pool_size_distribution_.pct50());
  // Log_info("pool 90pct %d %.2f" , pool_size_distribution_.count(), pool_size_distribution_.pct90());
  // Log_info("pool 99pct %d %.2f" , pool_size_distribution_.count(), pool_size_distribution_.pct99());
  // Log_info("pool ave %d %.2f" , pool_size_distribution_.count(), pool_size_distribution_.ave());
  std::vector<double> ret;
  ret.push_back(pool_size_distribution_.pct50());
  ret.push_back(pool_size_distribution_.pct90());
  ret.push_back(pool_size_distribution_.pct99());
  ret.push_back(pool_size_distribution_.ave());
  // Log_info("pool ret %.2f %.2f %.2f %.2f", ret[0], ret[1], ret[2], ret[3]);
  return ret;
}

void JetpackCommandPool::AckedSnapshot(KeyCmdBatchData& out) const {
  for (const auto& kv : candidates_) {
    if (!kv.second.has_cmd_to_recover()) {
      continue;
    }
    // nullptr: the reported write was GC'd (committed) while a later
    // conflicting write is still recorded; nothing to recover for it.
    auto cmd = kv.second.cmd_to_recover();
    if (cmd) {
      out.AddEntry(kv.first, cmd);
    }
  }
#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY-CommandPool] acked snapshot size %zu", out.Size());
#endif
}

bool JetpackCommandPool::HasAckedWrite(key_t key) const {
  // find(), not operator[]: a lookup must not create an empty bucket.
  auto it = candidates_.find(key);
  return it != candidates_.end() && it->second.has_cmd_to_recover();
}

void JetpackCommandPool::ClearPool() {
  candidates_.clear();
  pool_size_ = 0;
  pool_cmd_count_ = 0;
  pool_size_distribution_ = Distribution();
}


#ifdef COMMAND_POOL_LOG_DEBUG
void JetpackCommandPool::print_log() {
  if (pool_log_.size() == 0)
    return;
  for (int i = 0; i < pool_log_.size(); i++) {
    pool_log_[i].print(pool_log_[0].time_);
  }
}
#endif


/************************ Jetpack recovery begin ****************************/
// Replica handlers (non-yielding, guard first, no side effect on reject) and
// the recovery coordinator (one driver coroutine per server object,
// round-local state, re-validated after every yield).

namespace {

// Timing (kept here, not in constants.h, to avoid rebuilding every TU).
const int64_t kJpSliceUs = 250 * 1000;              // longest single wait
const int64_t kJpPhaseDeadlineUs = 2 * 1000 * 1000; // Pull / Accept round
const int64_t kJpBackoffMinUs = 10 * 1000;          // round + resubmit retry
const int64_t kJpBackoffMaxUs = 1000 * 1000;
const int64_t kJpFrBackoffMinUs = 1000 * 1000;      // FinishRecovery resend
const int64_t kJpFrBackoffMaxUs = 10 * 1000 * 1000;
const int64_t kJpResubmitLogEveryUs = 10 * 1000 * 1000;
const int64_t kJpDriverIdleUs = 100 * 1000;
const int64_t kJpTakeoverTickUs = 500 * 1000;       // takeover timer resolution
const int64_t kJpRejoinTermWaitUs = 30LL * 1000 * 1000;  // no rejoin term by then: Log_error

// Raft stability marker: a recovery-flagged no-op committed in term v.
// Its tx id lives far above every client tx id ((coo_id << 32) + n), and its
// ret_ is REJECT, so CommitReplicated finishes it without executing anything.
const txnid_t kJpMarkerTxBase = 0xFFFFFF00ULL << 32;
const int32_t kJpMarkerClientId = -2;
// The replication coordinator returned without calling back (e.g. the Raft
// term moved while it waited, or the server is paused).
const int kJpNoCallback = -1001;

int64_t JpNowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

double JpWallMs() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return static_cast<double>(tv.tv_sec) * 1000.0 +
         static_cast<double>(tv.tv_usec) / 1000.0;
}

long long JpMsSince(const std::chrono::steady_clock::time_point& t) {
  return (long long) std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - t).count();
}

// rrr's Event::Wait(0) means "no timeout", so every computed wait is
// clamped to [1us, kJpSliceUs].
uint64_t JpClampWaitUs(int64_t us) {
  if (us < 1) return 1;
  if (us > kJpSliceUs) return (uint64_t) kJpSliceUs;
  return (uint64_t) us;
}

int64_t JpJitter(int64_t us) {
  return std::max<int64_t>(1, (int64_t) (us * RandomGenerator::rand_double(0.5, 1.5)));
}

// 10ms, 20ms, ... capped at 1s; attempt >= 1.
int64_t JpRetryBackoffUs(int attempt) {
  int64_t b = kJpBackoffMinUs;
  for (int i = 1; i < attempt && b < kJpBackoffMaxUs; i++) b *= 2;
  return JpJitter(std::min(b, kJpBackoffMaxUs));
}

void JpSetSignal(const std::string& role, const std::string& value, const std::string& host) {
  try {
    jm_signal::set_key(role, value, host);
  } catch (const std::exception& e) {
    Log_warn("[JETPACK-RECOVERY] failed to write signal %s:%s on JM_Jetpack_%s: %s",
             role.c_str(), value.c_str(), host.c_str(), e.what());
  }
}

// Recovery classification of the replies of a failed round.
struct JpRoundClass {
  bool superseded = false;   // some replica joined a view newer than v
  bool finished = false;     // some replica already installed v or newer
  ballot_t max_promise_same_view = -1;
};

template <class R>
JpRoundClass JpClassify(const std::vector<R>& replies, epoch_t v) {
  JpRoundClass c;
  for (const auto& r : replies) {
    if (r.vid > v) c.superseded = true;
    if (r.view_id >= v) c.finished = true;
    if (jp::BallotView(r.promised) == v && r.promised > c.max_promise_same_view) {
      c.max_promise_same_view = r.promised;
    }
  }
  return c;
}

typedef shared_ptr<Marshallable> JpBody;

// Pull reply -> rule input. The cmd id is recomputed from the body, which is
// what the pool keyed it by.
bool JpToEntries(const shared_ptr<KeyCmdBatchData>& batch,
                 std::vector<jp::Entry<JpBody>>* out) {
  if (!batch) return true;
  bool all_ok = true;
  for (size_t i = 0; i < batch->Size(); i++) {
    auto cmd = batch->GetCommand(i);
    key_t key = 0;
    uint64_t cmd_id = 0;
    bool is_write = false;
    if (!cmd || !SimpleRWCommand::ExtractPoolKeys(cmd, &key, &cmd_id, &is_write)) {
      all_ok = false;
      continue;
    }
    out->push_back(jp::Entry<JpBody>{batch->GetKey(i), cmd_id, cmd});
  }
  return all_ok;
}

// The pieces of a recovered command body (pool entries are VecPieceData).
shared_ptr<VecPieceData> JpRecoveredPieces(const shared_ptr<Marshallable>& cmd) {
  if (!cmd) return nullptr;
  shared_ptr<Marshallable> inner = cmd;
  if (inner->kind_ == MarshallDeputy::CMD_TPC_BATCH) {
    auto batch = std::dynamic_pointer_cast<TpcBatchCommand>(inner);
    if (!batch || batch->Size() != 1 || !batch->cmds_[0]) return nullptr;
    inner = batch->cmds_[0]->cmd_;
  } else if (inner->kind_ == MarshallDeputy::CMD_TPC_COMMIT) {
    auto tpc = std::dynamic_pointer_cast<TpcCommitCommand>(inner);
    if (!tpc) return nullptr;
    inner = tpc->cmd_;
  }
  if (!inner) return nullptr;
  if (inner->kind_ == MarshallDeputy::CMD_VEC_PIECE) {
    auto vpd = std::dynamic_pointer_cast<VecPieceData>(inner);
    if (!vpd || !vpd->sp_vec_piece_data_ || vpd->sp_vec_piece_data_->empty()) return nullptr;
    return vpd;
  }
  if (inner->kind_ == MarshallDeputy::CONTAINER_CMD) {
    auto piece = std::dynamic_pointer_cast<TxPieceData>(inner);
    if (!piece) return nullptr;
    auto vpd = std::make_shared<VecPieceData>();
    vpd->sp_vec_piece_data_ = std::make_shared<vector<shared_ptr<TxPieceData>>>();
    vpd->sp_vec_piece_data_->push_back(piece);
    return vpd;
  }
  return nullptr;
}

// One member of the chosen recovery set (or the Raft stability marker).
struct JpMember {
  enum State { kPending, kInflight, kDone, kFailed };
  key_t key = 0;
  uint64_t cmd_id = 0;
  txnid_t tx_id = 0;
  shared_ptr<VecPieceData> body;
  bool marker = false;
  State state = kPending;
  int attempts = 0;
  int64_t next_try_us = 0;
  int last_code = 0;
};

}  // namespace

bool TxLogServer::JetpackRecoveryEnabled() {
  auto* cfg = Config::GetConfig();
  if (cfg == nullptr) return false;
  if (cfg->tx_proto_ != MODE_RULE || cfg->IsCurpMode()) return false;
  switch (cfg->replica_proto_) {
    case MODE_RAFT:
    case MODE_ETCD:
    case MODE_MONGODB:
    case MODE_ZOOKEEPER:
      return true;
    default:
      return false;
  }
}

bool TxLogServer::JpTakeoverEnabled() {
  if (!JetpackRecoveryEnabled()) return false;
  switch (Config::GetConfig()->replica_proto_) {
    case MODE_ETCD:
    case MODE_MONGODB:
    case MODE_ZOOKEEPER:
      return true;
    default:
      return false;
  }
}

bool TxLogServer::JpRejoinRequested() {
  const char* e = std::getenv("JETPACK_REJOIN");
  return e != nullptr && std::string(e) == "1" && JetpackRecoveryEnabled();
}

const char* TxLogServer::JpValidityName(JpValidity r) {
  switch (r) {
    case kJpValid: return "valid";
    case kJpSuperseded: return "superseded";
    case kJpFinishedElsewhere: return "finished_elsewhere";
    case kJpNotCoordinator: return "not_coordinator";
    case kJpTakenOver: return "taken_over";
  }
  return "unknown";
}

void TxLogServer::JpJoin(epoch_t v) {
  verify(v > jepoch_ && v >= oepoch_);
  oepoch_ = v;
  jetpack_status_ = JetpackStatus::RECOVERY;
  // Recovery progress here (the takeover timer counts from it).
  jp_progress_us_ = JpNowUs();
}

const View& TxLogServer::JpInstalledView() {
  if (jp_installed_view_.IsEmpty()) {
    // No FinishRecovery applied yet: the static view, led by locale 0.
    auto* cfg = Config::GetConfig();
    int n = cfg->GetPartitionSize(partition_id_);
    int leader = -1;
    for (auto& si : cfg->SitesByPartitionId(partition_id_)) {
      if (si.locale_id == 0) {
        leader = si.id;
        break;
      }
    }
    jp_installed_view_ = View(n, leader, jepoch_);
  }
  return jp_installed_view_;
}

bool TxLogServer::JetpackIsProposerOf(epoch_t view) {
  if (!JetpackRecoveryEnabled()) {
    return IsLeader();
  }
  return view == jepoch_ && JpInstalledView().GetLeader() == (int) site_id_;
}

bool TxLogServer::JetpackLeaseReadAllowed(key_t key) const {
  if (!JetpackRecoveryEnabled()) {
    return true;
  }
  // In RECOVERY the local state may lack fast-committed writes that are still
  // being recovered. In READY an acked write of this key may have been
  // fast-committed without being applied here yet; the replicated read path
  // (OnCommit) is used then, and also on an amnesiac replica, whose pool
  // restarted empty.
  return jetpack_status_ == JetpackStatus::READY && jp_rejoin_.AckAllowed() &&
         !command_pool_.HasAckedWrite(key);
}

void TxLogServer::JpAdoptBaseView(const View& w, bool allow_same_id) {
  if (w.IsEmpty()) return;
  bool newer = w.view_id_ > new_view_.view_id_;
  bool replace = allow_same_id && w.view_id_ == new_view_.view_id_ &&
                 w.leaders_ != new_view_.leaders_;
  if (newer || replace) {
    old_view_ = new_view_;
    new_view_ = w;
  }
  if (commo_) {
    // The process-wide routing map (co-located clients route by it).
    // An applied FinishRecovery is authoritative for its view id, so it may
    // replace the leader of a known view of the same id (redirect); other
    // adoptions only take strictly newer ids.
    auto vd = std::make_shared<ViewData>(w, partition_id_);
    if (allow_same_id) {
      commo_->AdoptRedirectView(partition_id_, vd);
    } else {
      commo_->UpdatePartitionView(partition_id_, vd);
    }
  }
}

bool TxLogServer::JpBackendIsLeader() {
  if (!JetpackRecoveryEnabled()) {
    return loc_id_ == 0;
  }
  return JpInstalledView().GetLeader() == (int) site_id_;
}

View TxLogServer::JpReplyBaseView() {
  if (!new_view_.IsEmpty()) {
    return new_view_;
  }
  return JpInstalledView();
}

void TxLogServer::JpMarkWrongLeader(const shared_ptr<Marshallable>& cmd) {
  if (!cmd || cmd->kind_ != MarshallDeputy::CMD_TPC_COMMIT) {
    return;
  }
  auto tpc_cmd = std::dynamic_pointer_cast<TpcCommitCommand>(cmd);
  if (!tpc_cmd) {
    return;
  }
  tpc_cmd->ret_ = WRONG_LEADER;
  // Clients learn the base view (routing) and, under Jetpack recovery, its
  // id for their fast path.
  tpc_cmd->sp_view_data_ = std::make_shared<ViewData>(JpReplyBaseView(), partition_id_);
}

bool TxLogServer::JpBackendBounce(const shared_ptr<Marshallable>& cmd, const char* who) {
  if (SimpleRWCommand(cmd).IsRecoveryCommand()) {
    // Recovered commands are submitted by the coordinator itself, in RECOVERY
    // and before the view they belong to is installed here.
    return false;
  }
  const bool recovering = jetpack_status_ == JetpackStatus::RECOVERY;
  if (!recovering) {
    // Without Jetpack recovery every replica keeps accepting, as before.
    if (!JetpackRecoveryEnabled() || IsLeader()) {
      return false;
    }
    // A non-leader still writes a fast-path-attempted command through its own
    // backend endpoint: its conflict guard is its fast-path vote at every
    // replica (the proposer included), and if it was fast-committed (the
    // client ends the tx on the fast path and never re-sends its Dispatch) a
    // bounce would leave it durable only in the pools until the next
    // recovery. Only an original-path-only command must go to the leader, so
    // its placeholder is recorded at the fast-path proposer.
    if (!SimpleRWCommand::NeedRecordConflictInOriginalPath(cmd)) {
      return false;
    }
  }
#ifdef JETPACK_WRONG_LEADER_DEBUG
  {
    auto tpc_cmd = std::dynamic_pointer_cast<TpcCommitCommand>(cmd);
    Log_info("[WRONG_LEADER_FLOW] %s rejecting tx_id=%lu at loc_id=%d because %s",
             who, tpc_cmd ? (unsigned long) tpc_cmd->tx_id_ : 0UL, loc_id_,
             recovering ? "status=RECOVERY" : "not the leader of the installed view");
  }
#else
  (void) who;
#endif
  JpMarkWrongLeader(cmd);
  JpDropBouncedPlaceholder(cmd);
  return true;
}

void TxLogServer::JpDropBouncedPlaceholder(const shared_ptr<Marshallable>& cmd) {
  if (!cmd || !JetpackRecoveryEnabled() || cmd->kind_ != MarshallDeputy::CMD_TPC_COMMIT) {
    return;
  }
  auto tpc_cmd = std::dynamic_pointer_cast<TpcCommitCommand>(cmd);
  if (!tpc_cmd || !tpc_cmd->cmd_ || tpc_cmd->cmd_->kind_ != MarshallDeputy::CMD_VEC_PIECE) {
    return;
  }
  auto vpd = std::dynamic_pointer_cast<VecPieceData>(tpc_cmd->cmd_);
  if (!vpd || vpd->is_recovery_command_ || !vpd->sp_vec_piece_data_ ||
      vpd->sp_vec_piece_data_->empty()) {
    return;
  }
  // A fast-path-attempted command has no placeholder; its pool entry is its
  // fast-path vote, which must stay.
  if (!SimpleRWCommand::NeedRecordConflictInOriginalPath(cmd)) {
    return;
  }
  // The placeholder lives on the replication server (rep_sched_), like the
  // insert in OriginalPathUnexecutedCmdConflictPlaceHolder.
  TxLogServer* rs = rep_sched_ ? rep_sched_ : this;
  rs->RuleCommandPoolGC(cmd);
}

ballot_t TxLogServer::JpFinishLevel(epoch_t u) const {
  // The highest ballot this replica accepted (ballots of views older than u
  // are lower than every ballot of u; with a newer one FinishAllowed fails).
  ballot_t level = -1;
  for (const auto& kv : jp_accepted_) {
    level = std::max(level, kv.second.ballot);
  }
  if (jp::BallotView(jp_fr_floor_) == u) {
    level = std::max(level, jp_fr_floor_);
  }
  return level;
}

bool TxLogServer::JpApplyFinish(epoch_t u, ballot_t b, const View* w) {
  if (!jp::FinishAllowed(jepoch_, oepoch_, u)) {
    return false;
  }
  // One agreed leader per view: no lower same-view coordinator's view where a
  // higher one took part (jp::FinishBallotOk).
  if (!jp::FinishBallotOk(JpFinishLevel(u), b)) {
    return false;
  }
  // An amnesiac replica installs only a view that did not exist before
  // its restart (it may have acked or promised in any older one).
  if (!jp_rejoin_.FinishAllowed(u)) {
    return false;
  }
  jepoch_ = u;
  oepoch_ = u;
  // The fast-path log of the old view; the only place the pool is cleared.
  command_pool_.ClearPool();
  // accepted[vn] with vn < u can never be read again: any Pull quorum that
  // includes this replica now computes vn' >= u.
  for (auto it = jp_accepted_.begin(); it != jp_accepted_.end();) {
    if (it->first < u) {
      it = jp_accepted_.erase(it);
    } else {
      ++it;
    }
  }
  if (w != nullptr && !w->leaders_.empty()) {
    jp_installed_view_ = *w;
  } else {
    jp_installed_view_ = JpInstalledView();
  }
  jp_installed_view_.view_id_ = u;
  if (w != nullptr) {
    JpAdoptBaseView(*w, /*allow_same_id=*/true);
  }
  jp_progress_us_ = JpNowUs();
  if (jp_rejoin_.OnInstalled(u)) {
    const std::string t = jp_rejoin_.term_known() ? std::to_string(jp_rejoin_.term()) : "unknown";
    Log_info("[JETPACK-REJOIN] rejoined: installed fresh view u=%u (fresh from %llu, T_rejoin=%s) "
             "loc_id=%d; fast-path acks and recovery messages are allowed again",
             u, (unsigned long long) jp_rejoin_.fresh_from(), t.c_str(), loc_id_);
  }
  // Last: the fast-path ack gate opens only in view u.
  jetpack_status_ = JetpackStatus::READY;
  return true;
}

std::string TxLogServer::JpSignalHost() {
  std::string host;
  if (frame_ && frame_->site_info_) {
    auto* si = frame_->site_info_;
    if (!si->host.empty())
      host = si->host;
    else if (!si->proc_name.empty())
      host = si->proc_name;
    else if (!si->name.empty())
      host = si->name;
  }
#ifdef AWS
  host = "0.0.0.0";
#endif
  return host;
}

void TxLogServer::JpWriteFinishSignals() {
#if defined(JETPACK_MONGODB_RECOVERY) || defined(JETPACK_ETCD_RECOVERY) || defined(JETPACK_ZOOKEEPER_RECOVERY)
  Log_info("Mark FinishRecovery on %s", "recovery_finish");
  JpSetSignal("jetpack", "recovery_finish", "recovery_finish");
  Log_info("[JETPACK-RECOVERY] Wrote finish signal to JM_Jetpack_%s", "recovery_finish");
  bool failure_seen = false;
  try {
    failure_seen = jm_signal::exists_key("failure", "failure_triggered", "failure_triggered");
  } catch (const std::exception& e) {
    Log_warn("[JETPACK-RECOVERY] failed to read the failure_triggered signal: %s", e.what());
  }
  if (failure_seen) {
    JpSetSignal("jetpack", "recovery_finish_after_failure", "recovery_finish_after_failure");
    Log_info("[JETPACK-RECOVERY] Wrote post-failure finish signal to JM_Jetpack_%s",
             "recovery_finish_after_failure");
  }
#endif
}

bool TxLogServer::JpUsesStabilityMarker() const {
  // Raft only. etcd/Mongo/ZK have no marker; one would need fenced backend
  // writes, which this code does not use.
  return Config::GetConfig()->replica_proto_ == MODE_RAFT;
}

/* ---------------------------- replica handlers ---------------------------- */

void TxLogServer::OnJetpackPullRecovery(const epoch_t& v,
                                        const ballot_t& b,
                                        const MarshallDeputy& new_view,
                                        bool_t* ok,
                                        epoch_t* reply_view_id,
                                        epoch_t* reply_vid,
                                        ballot_t* reply_promised,
                                        const shared_ptr<KeyCmdBatchData>& acked,
                                        const shared_ptr<JetpackAcceptedMapData>& accepted) {
  TxLogServer* rs = rep_sched_ ? rep_sched_ : this;
  // Guard first; a rejection writes nothing (no freeze, no view change, no
  // promise, no step-down). An amnesiac replica answers no Pull: its
  // empty pool and forgotten promise would count as real acceptor state.
  const bool amnesiac = !rs->jp_rejoin_.RecoveryMsgAllowed();
  if (amnesiac || !rs->JpRecoveryMsgAllowed(v, b, jp::BallotRule::kStrict)) {
    *ok = 0;
    *reply_view_id = rs->jepoch_;
    *reply_vid = rs->oepoch_;
    *reply_promised = rs->jp_promised_;
    Log_info("[JETPACK-GUARD] PullRecovery rejected v=%u b=%lld view=%u vid=%u promised=%lld%s",
             v, (long long) b, rs->jepoch_, rs->oepoch_, (long long) rs->jp_promised_,
             amnesiac ? " (amnesiac)" : "");
    return;
  }
  // One non-yielding step: join (stop acking) BEFORE the snapshot, then
  // promise, then snapshot. Every snapshot entry was acked before the freeze.
  rs->JpJoin(v);
  rs->jp_promised_ = b;
  auto sp_view = std::dynamic_pointer_cast<ViewData>(new_view.sp_data_);
  if (sp_view) {
    rs->JpAdoptBaseView(sp_view->GetView());
  }
  rs->command_pool_.AckedSnapshot(*acked);
  for (const auto& kv : rs->jp_accepted_) {
    if (kv.first >= rs->jepoch_) {
      accepted->entries_.push_back(
          JetpackAcceptedMapData::Entry{kv.first, kv.second.ballot, kv.second.value});
    }
  }
  *ok = 1;
  *reply_view_id = rs->jepoch_;
  *reply_vid = rs->oepoch_;
  *reply_promised = b;
  Log_info("[JETPACK-RECOVERY] PullRecovery joined v=%u b=%lld view=%u acked=%zu accepted=%zu pool_keys=%d pool_cmds=%d",
           v, (long long) b, rs->jepoch_, acked->Size(), accepted->entries_.size(),
           rs->command_pool_.size(), rs->command_pool_.cmd_size());
}

void TxLogServer::OnJetpackAccept(const epoch_t& v,
                                  const epoch_t& vn,
                                  const ballot_t& b,
                                  const MarshallDeputy& value,
                                  bool_t* ok,
                                  epoch_t* reply_view_id,
                                  epoch_t* reply_vid,
                                  ballot_t* reply_promised) {
  TxLogServer* rs = rep_sched_ ? rep_sched_ : this;
  auto sp_value = std::dynamic_pointer_cast<KeyCmdBatchData>(value.sp_data_);
  const bool amnesiac = !rs->jp_rejoin_.RecoveryMsgAllowed();
  if (amnesiac || !sp_value ||
      !jp::AcceptAllowed(rs->jepoch_, rs->oepoch_, rs->jp_promised_, v, vn, b)) {
    *ok = 0;
    *reply_view_id = rs->jepoch_;
    *reply_vid = rs->oepoch_;
    *reply_promised = rs->jp_promised_;
    Log_info("[JETPACK-GUARD] Accept rejected v=%u vn=%u b=%lld view=%u vid=%u promised=%lld%s%s",
             v, vn, (long long) b, rs->jepoch_, rs->oepoch_, (long long) rs->jp_promised_,
             sp_value ? "" : " (no value)", amnesiac ? " (amnesiac)" : "");
    return;
  }
  rs->JpJoin(v);
  rs->jp_promised_ = b;
  // An accepted empty set is a value, too.
  rs->jp_accepted_[vn] = JpAccepted{b, sp_value};
  *ok = 1;
  *reply_view_id = rs->jepoch_;
  *reply_vid = rs->oepoch_;
  *reply_promised = b;
  Log_info("[JETPACK-RECOVERY] Accept accepted v=%u vn=%u b=%lld set=%zu",
           v, vn, (long long) b, sp_value->Size());
}

void TxLogServer::OnJetpackFinishRecovery(const epoch_t& u,
                                          const ballot_t& b,
                                          const MarshallDeputy& new_view,
                                          bool_t* applied,
                                          epoch_t* reply_view_id,
                                          epoch_t* reply_vid) {
  TxLogServer* rs = rep_sched_ ? rep_sched_ : this;
  auto sp_view = std::dynamic_pointer_cast<ViewData>(new_view.sp_data_);
  View w;
  const View* wp = nullptr;
  if (sp_view) {
    w = sp_view->GetView();
    wp = &w;
  }
  int cleared = rs->command_pool_.cmd_size();
  const ballot_t level = rs->JpFinishLevel(u);
  bool ok = rs->JpApplyFinish(u, b, wp);
  // "applied" = this replica is in view u with this FinishRecovery's leader,
  // installed now or by an earlier copy (the coordinator counts these
  // before it installs v itself, also across dropped replies).
  const bool installed = jp::FinishReplyInstalled(ok, rs->jepoch_, rs->jp_installed_view_.GetLeader(),
                                                  u, wp ? wp->GetLeader() : -1);
  *applied = installed ? 1 : 0;
  *reply_view_id = rs->jepoch_;
  *reply_vid = rs->oepoch_;
  if (ok) {
    Log_info("[JETPACK-FR] applied u=%u cleared=%d leader=%d", u, cleared,
             rs->jp_installed_view_.GetLeader());
    rs->JpWriteFinishSignals();
  } else {
    // A duplicate or stale FinishRecovery: no state change and no signal.
    const bool view_ok = jp::FinishAllowed(rs->jepoch_, rs->oepoch_, u);
    const bool lower = view_ok && !jp::FinishBallotOk(level, b);
    const bool amnesia = view_ok && !lower && !rs->jp_rejoin_.FinishAllowed(u);
    std::string why;
    if (installed) {
      why = " (already installed with this leader)";
    } else if (lower) {
      why = " (b=" + std::to_string(b) + " below this replica's level " + std::to_string(level) +
            ": a higher same-view coordinator took part here)";
    } else if (amnesia) {
      why = " (amnesiac: not a fresh view)";
    }
    Log_info("[JETPACK-FR] ignored u=%u view=%u vid=%u%s", u, rs->jepoch_, rs->oepoch_, why.c_str());
  }
}

/* ------------------------------- coordinator ------------------------------ */

void TxLogServer::JetpackRecoveryEntry(const View& target, bool emit_ack,
                                       uint64_t ack_nonce, bool ack_has_nonce,
                                       bool takeover) {
  const epoch_t v = target.view_id_;
  if (v == 0 || (uint64_t) v >= jp::kBallotViewLimit) {
    // The ballot encoding needs 0 < v < 2^31.
    Log_error("[JETPACK-RECOVERY] trigger with unusable view id v=%u (need 0 < v < 2^31), ignored", v);
    return;
  }
  bool joined = false;
  if (!JetpackRecoveryEnabled()) {
    Log_info("[JETPACK-RECOVERY] trigger v=%u: Jetpack recovery is not enabled in this mode, no recovery", v);
  } else {
    // First, so the driver parks on its event before anything is published.
    JpStartDriverIfNeeded();
    // v == vid passes (a takeover re-joins the view it is frozen in).
    if (JpRecoveryMsgAllowed(v, 0, jp::BallotRule::kIgnore)) {
      // Local freeze now. jp_promised_ stays untouched so the coordinator's
      // own Pull still passes b > promised.
      JpJoin(v);
      JpAdoptBaseView(target);
      joined = true;
      if (!takeover && jp_rejoin_.amnesiac()) {
        // This replica's own backend node won term v after the restart,
        // so v and every newer view did not exist before it.
        jp_rejoin_.NoteOwnTrigger(v);
        Log_info("[JETPACK-REJOIN] amnesiac replica coordinates its own view v=%u: views >= %llu are fresh here",
                 v, (unsigned long long) jp_rejoin_.fresh_from());
      }
      Log_info("[JETPACK-RECOVERY] %s v=%u site_id=%d loc_id=%d: joined locally (view=%u vid=%u), fast path stopped",
               takeover ? "takeover trigger" : "trigger", v, site_id_, loc_id_, jepoch_, oepoch_);
    } else {
      Log_info("[JETPACK-RECOVERY] stale %s v=%u view=%u vid=%u, skipped",
               takeover ? "takeover" : "trigger", v, jepoch_, oepoch_);
    }
  }
  if (emit_ack) {
    // After the freeze, also for a stale trigger: this replica is frozen at a
    // newer vid or installed in a view >= v, so it acks nothing older.
    std::string host = JpSignalHost();
    JpSetSignal("jetpack", "fastpath_stopped", host);
    std::string ack = "leader_paused term=" + std::to_string(v);
    if (ack_has_nonce) {
      ack += " nonce=" + std::to_string(ack_nonce);
    }
    JpSetSignal("jetpack", ack, host);
    Log_info("[JETPACK-RECOVERY] Emitted jetpack:%s on JM_Jetpack_%s", ack.c_str(), host.c_str());
  }
  // A newer view, or (a takeover) the view this node is frozen in once
  // more, to run with its own ballot even if it drove that view before.
  if (joined && (v > jp_pending_view_ || (takeover && v == jp_pending_view_))) {
    jp_pending_view_ = v;
    jp_pending_target_ = target;
    jp_pending_seq_++;
    if (jp_driver_event_) {
      jp_driver_event_->Set(1);
    }
  }
}

void TxLogServer::JpStartTakeoverTimer(const std::shared_ptr<std::atomic<bool>>& alive) {
  if (jp_takeover_started_ || !JpTakeoverEnabled()) {
    return;
  }
  jp_takeover_started_ = true;
  jp_takeover_clock_ = jp::TakeoverClock((uint32_t) loc_id_);
  Log_info("[JETPACK-TAKEOVER] timer started site_id=%d loc_id=%d: a recovery frozen here without progress "
           "for %lldms (doubling per takeover of the same view, up to x8) is taken over",
           site_id_, loc_id_, (long long) (jp::TakeoverDelayUs((uint32_t) loc_id_, 0) / 1000));
  auto keep = alive;
  Coroutine::CreateRun([this, keep]() {
    while (keep->load()) {
      Reactor::CreateSpEvent<TimeoutEvent>((uint64_t) kJpTakeoverTickUs)->Wait();
      if (!keep->load()) {
        break;  // the server is gone: touch nothing of it
      }
      JpTakeoverTick(JpNowUs());
    }
  });
}

epoch_t TxLogServer::JpTakeoverTick(int64_t now_us) {
  const bool frozen = oepoch_ > jepoch_;
  // A replica that could not lead the view (MongoDB: its mongod is not the
  // primary of that term) waits like a busy one: the attempt is not used up.
  std::string why;
  const bool can_lead = !frozen || JpTakeoverAllowedHere(oepoch_, &why);
  const epoch_t v = jp_takeover_clock_.Tick(now_us, frozen, oepoch_, jp_progress_us_,
                                            JpDriverBusy() || !can_lead);
  if (!can_lead && now_us >= jp_takeover_clock_.deadline_us() && jp_takeover_refused_view_ != oepoch_) {
    jp_takeover_refused_view_ = oepoch_;
    Log_info("[JETPACK-TAKEOVER] no recovery progress at vid=%u (view=%u), but loc_id=%d cannot lead it: %s",
             oepoch_, jepoch_, loc_id_, why.c_str());
  }
  if (v == 0) {
    return 0;
  }
  Log_info("[JETPACK-TAKEOVER] no recovery progress at vid=%u (view=%u) for %lldms: loc_id=%d site_id=%d "
           "takes over v=%u (attempt %d, next no earlier than %lldms)",
           oepoch_, jepoch_, (long long) ((now_us - jp_progress_us_) / 1000), loc_id_, site_id_, v,
           jp_takeover_clock_.attempts(),
           (long long) (jp::TakeoverDelayUs(jp_takeover_clock_.rank(), jp_takeover_clock_.attempts()) / 1000));
  const int n = Config::GetConfig()->GetPartitionSize(partition_id_);
  // Same view, this replica as coordinator (and, through its FinishRecovery,
  // leader of the view; JpTakeoverAllowedHere vetted that it can lead it).
  JetpackRecoveryEntry(View(n, (int) site_id_, v), /*emit_ack=*/false, 0, false, /*takeover=*/true);
  return v;
}

void TxLogServer::JpLearnRejoinTerm(uint64_t term, const char* source) {
  if (!jp_rejoin_.LearnTerm(term)) {
    return;
  }
  Log_info("[JETPACK-REJOIN] T_rejoin=%llu learned from %s (loc_id=%d): this restarted replica installs only "
           "views >= %llu (or one it coordinates itself)",
           (unsigned long long) term, source, loc_id_, (unsigned long long) jp_rejoin_.fresh_from());
}

void TxLogServer::JpRejoinTermUnavailable(const char* tag, const char* why) {
  if (!jp_rejoin_.amnesiac() || jp_rejoin_.term_known() || jp_rejoin_error_logged_) {
    return;
  }
  jp_rejoin_error_logged_ = true;
  Log_error("%s [JETPACK-REJOIN] cannot learn T_rejoin (%s): this restarted replica (loc_id=%d) stays amnesiac, "
            "no fast-path acks and no Pull/Accept, until it installs a view it coordinates itself",
            tag, why, loc_id_);
}

void TxLogServer::JpLogRejoinState(const char* tag) {
  const char* e = std::getenv("JETPACK_REJOIN");
  const bool requested = e != nullptr && std::string(e) == "1";
  if (!jp_rejoin_.amnesiac()) {
    if (requested && !JetpackRecoveryEnabled()) {
      Log_warn("%s [JETPACK-REJOIN] JETPACK_REJOIN=1 ignored: Jetpack recovery is not enabled in this mode", tag);
    }
    return;
  }
  Log_info("%s [JETPACK-REJOIN] JETPACK_REJOIN=1: restarted replica loc_id=%d site_id=%d starts amnesiac: "
           "no fast-path acks, no Pull/Accept, FinishRecovery only for a view above the backend term "
           "learned after the restart (T_rejoin) or one it coordinates itself",
           tag, loc_id_, site_id_);
}

bool TxLogServer::JpFinishLocally(epoch_t v, const View& target) {
  const int cleared = command_pool_.cmd_size();
  // n/2 others installed v with this coordinator as leader: decided.
  if (!JpApplyFinish(v, jp::kChosenBallot, &target)) {
    return false;
  }
  // As the RPC handler logs and signals an applied FinishRecovery.
  Log_info("[JETPACK-FR] applied u=%u cleared=%d leader=%d", v, cleared, jp_installed_view_.GetLeader());
  JpWriteFinishSignals();
  return true;
}

void TxLogServer::JpRunTermPoller(const char* tag, const std::string& role,
                                  const std::string& prefix,
                                  const std::shared_ptr<JetpackLeaderProbe>& probe,
                                  const std::shared_ptr<std::atomic<bool>>& alive) {
  const std::string host = JpSignalHost();
  const int poll_ms = JpLeaderPollMs();
  // View ids must stay below 2^31 (ballot encoding).
  JpTermTrigger rules((uint64_t) loc_id_, jp::kBallotViewLimit);
  // Lines already on disk are history (an earlier run, the startup election).
  rules.BaselineFromDisk(JpReadTermLine(role, host, prefix));
  Log_info("%s watching JM_Jetpack_%s for %s:%s term=T [loc=L] every %dms, self-detection %s "
           "(loc_id=%d site_id=%d, startup line term=%llu)",
           tag, host.c_str(), role.c_str(), prefix.c_str(), poll_ms, probe ? "on" : "off",
           loc_id_, site_id_, (unsigned long long) rules.line_baseline());
  const int64_t rejoin_wait_until = JpNowUs() + kJpRejoinTermWaitUs;
  while (alive->load()) {
    const JpTermLine line = JpReadTermLine(role, host, prefix);
    const JpTermProbe self = probe ? probe->Latest() : JpTermProbe();
    const JpTermTrigger::Step s = rules.Next(line, self);
    if (s.legacy_line && JpFirstLegacyWarning(role)) {
      Log_warn("%s ignoring legacy term-less %s:%s on JM_Jetpack_%s: it carries no view id, so it "
               "starts no Jetpack recovery; emitters must write %s:%s term=T [loc=L]",
               tag, role.c_str(), prefix.c_str(), host.c_str(), role.c_str(), prefix.c_str());
    }
    if (s.self_baseline) {
      Log_info("%s baseline term=%llu from the co-located node (leader=%d loc_id=%d), no recovery",
               tag, (unsigned long long) s.self_baseline_term, (int) s.self_baseline_leader, loc_id_);
      if (s.self_baseline_leader && loc_id_ != 0) {
        Log_warn("%s the co-located node leads term %llu at startup, but the initial Jetpack view is "
                 "led by locale 0 (loc_id=%d): no recovery before the next term",
                 tag, (unsigned long long) s.self_baseline_term, loc_id_);
      }
    }
    // T_rejoin = the co-located node's CURRENT term after the restart (a
    // secondary's / follower's own newest term can be older: the probe reports
    // it only when exact), raised to the newest term-bearing line on disk at
    // startup.
    if (jp_rejoin_.amnesiac() && !jp_rejoin_.term_known() && self.seq > 0 && self.ok &&
        self.current_term > 0 && self.current_term < jp::kBallotViewLimit) {
      JpLearnRejoinTerm(std::max<uint64_t>(self.current_term, rules.line_baseline()),
                        role == "mongo" ? "the co-located mongod (current term)"
                                        : "the co-located server (current epoch)");
    }
    if (jp_rejoin_.amnesiac() && !jp_rejoin_.term_known() && JpNowUs() >= rejoin_wait_until) {
      JpRejoinTermUnavailable(tag, probe ? "the co-located node reported no current term within 30s"
                                         : "no self-detection probe");
    }
    if (s.line_other_loc) {
      Log_info("%s %s:%s term=%llu names loc=%llu, not this replica (loc_id=%d): not coordinating",
               tag, role.c_str(), prefix.c_str(), (unsigned long long) s.line_term,
               (unsigned long long) s.line_loc, loc_id_);
    }
    if (s.unusable_term != 0) {
      Log_error("%s term=%llu is not a usable view id (need < 2^31): ignored", tag,
                (unsigned long long) s.unusable_term);
    }
    if (s.trigger != 0) {
      Log_info("%s failover term=%llu source=%s loc_id=%d site_id=%d", tag,
               (unsigned long long) s.trigger,
               s.from_line && s.from_self ? "signal+self" : (s.from_line ? "signal" : "self"),
               loc_id_, site_id_);
      const int n_rep = (int) Config::GetConfig()->GetPartitionSize(partition_id_);
      // Non-yielding: joins the view locally (the freeze), then acks
      // jetpack:leader_paused term=T and hands the recovery to the driver.
      JetpackRecoveryEntry(View(n_rep, (int) site_id_, (epoch_t) s.trigger), /*emit_ack=*/true);
    }
    Reactor::CreateSpEvent<TimeoutEvent>((uint64_t) poll_ms * 1000)->Wait();
    // Nothing of this object is touched once alive is false.
  }
}

void TxLogServer::JpStartDriverIfNeeded() {
  if (jp_driver_started_) {
    return;
  }
  jp_driver_started_ = true;
  jp_driver_event_ = Reactor::CreateSpEvent<IntEvent>();
  // Runs until its first wait and returns; it never runs inside the caller's
  // critical section beyond that.
  auto alive = jp_alive_;
  Coroutine::CreateRun([this, alive]() {
    this->JpDriverLoop(alive);
  });
}

void TxLogServer::JpDriverLoop(const std::shared_ptr<std::atomic<bool>>& alive) {
  Log_info("[JETPACK-RECOVERY] recovery driver started site_id=%d loc_id=%d", site_id_, loc_id_);
  while (alive->load() && !jp_driver_stop_) {
    if (jp_pending_seq_ > jp_driven_seq_) {
      // The newest published target (older ones it replaced are moot).
      View t = jp_pending_target_;
      jp_driven_seq_ = jp_pending_seq_;
      jp_driven_view_ = t.view_id_;
      jp_running_view_ = t.view_id_;
      JetpackRunRecovery(t);
      if (!alive->load()) {
        return;
      }
      jp_running_view_ = 0;
      continue;
    }
    // Re-arm, then a timed idle wait. The local reference keeps the event
    // alive across the wait even if this server is deleted meanwhile.
    auto ev = Reactor::CreateSpEvent<IntEvent>();
    jp_driver_event_ = ev;
    ev->Wait(JpClampWaitUs(kJpDriverIdleUs));
    // Nothing of this object is touched once alive is false.
  }
}

TxLogServer::JpValidity TxLogServer::JpCheckValid(epoch_t v) {
  if (jp_driver_stop_) return kJpNotCoordinator;
  if (oepoch_ > v) return kJpSuperseded;
  if (jepoch_ >= v) return kJpFinishedElsewhere;
  if (!JetpackStillCoordinator(v)) return kJpNotCoordinator;
  return kJpValid;
}

TxLogServer::JpValidity TxLogServer::JpWaitValid(const shared_ptr<Event>& e,
                                                 epoch_t v,
                                                 int64_t deadline_us) {
  while (!e->IsReady()) {
    int64_t left = deadline_us - JpNowUs();
    if (left <= 0) {
      break;
    }
    e->Wait(JpClampWaitUs(left));
    JpValidity r = JpCheckValid(v);
    if (r != kJpValid) {
      return r;
    }
  }
  return JpCheckValid(v);
}

TxLogServer::JpValidity TxLogServer::JpSleepValid(epoch_t v, int64_t sleep_us) {
  const int64_t end = JpNowUs() + sleep_us;
  while (true) {
    JpValidity r = JpCheckValid(v);
    if (r != kJpValid) {
      return r;
    }
    int64_t left = end - JpNowUs();
    if (left <= 0) {
      return kJpValid;
    }
    Reactor::CreateSpEvent<TimeoutEvent>(JpClampWaitUs(left))->Wait();
  }
}

void TxLogServer::JetpackRunRecovery(const View& target) {
  const epoch_t v = target.view_id_;
  const int n = Config::GetConfig()->GetPartitionSize(partition_id_);
  const int threshold = jp::RecoveryThreshold(n);
  jetpack_recovery_start_time_ = std::chrono::steady_clock::now();
  Log_info("[JETPACK-RECOVERY] ===== STARTING JETPACK RECOVERY ====== time=%.6fms v=%u",
           JpWallMs(), v);
  Log_info("[JETPACK-RECOVERY] Coordinator: site_id=%d loc_id=%d partition=%d view=%u vid=%u n=%d threshold=%d",
           site_id_, loc_id_, partition_id_, jepoch_, oepoch_, n, threshold);

  auto stop = [this, v](JpValidity r, const char* phase) {
    Log_info("[JETPACK-RECOVERY] recovery v=%u gives up in phase %s after %lldms (view=%u vid=%u pending=%u)",
             v, phase, JpMsSince(jetpack_recovery_start_time_), jepoch_, oepoch_, jp_pending_view_);
    Log_info("[JETPACK-RECOVERY] ===== JETPACK RECOVERY STOPPED ====== v=%u reason=%s",
             v, JpValidityName(r));
  };

  // ---- Phases 1-2: Paxos for the recovery value, retried while valid ----
  int64_t backoff = kJpBackoffMinUs;
  int round = 0;
  shared_ptr<KeyCmdBatchData> value;
  epoch_t chosen_vn = 0;
  ballot_t chosen_b = -1;
  // Start above the same-view promise seen here (a takeover's first Pull
  // must beat the stalled coordinator's ballot).
  jp_ballot_counter_ = jp::CounterAbovePromise(jp_ballot_counter_, v, jp_promised_);
  while (true) {
    JpValidity r = JpCheckValid(v);
    if (r != kJpValid) {
      stop(r, "round start");
      return;
    }
    round++;
    jp_ballot_counter_++;
    if (!jp::BallotArgsOk(v, jp_ballot_counter_, loc_id_)) {
      Log_error("[JETPACK-RECOVERY] cannot build a ballot for v=%u counter=%u loc_id=%d",
                v, jp_ballot_counter_, loc_id_);
      stop(kJpNotCoordinator, "ballot");
      return;
    }
    const ballot_t b = jp::MakeBallot(v, jp_ballot_counter_, loc_id_);

    // Phase 1: Pull = BeginRecovery + Prepare + fast-log snapshot.
    auto pull_start = std::chrono::steady_clock::now();
    auto pe = commo()->JetpackBroadcastPullRecovery(partition_id_, v, b, target);
    r = JpWaitValid(pe, v, JpNowUs() + kJpPhaseDeadlineUs);
    if (r != kJpValid) {
      stop(r, "pull");
      return;
    }
    if (!pe->Yes()) {
      auto cls = JpClassify(pe->replies_, v);
      Log_info("[JETPACK-RECOVERY] PullRecovery FAILED v=%u b=%lld round=%d yes=%d no=%d errors=%d wait=%lldms",
               v, (long long) b, round, pe->n_voted_yes_, pe->n_voted_no_, pe->n_errors_,
               JpMsSince(pull_start));
      if (cls.superseded) {
        stop(kJpSuperseded, "pull");
        return;
      }
      if (cls.finished) {
        stop(kJpFinishedElsewhere, "pull");
        return;
      }
      if (cls.max_promise_same_view > b) {
        jp_ballot_counter_ = std::max(jp_ballot_counter_, jp::BallotCounter(cls.max_promise_same_view));
      }
      r = JpSleepValid(v, JpJitter(backoff));
      backoff = std::min(backoff * 2, kJpBackoffMaxUs);
      if (r != kJpValid) {
        stop(r, "pull backoff");
        return;
      }
      continue;
    }
    std::vector<jp::PullOk<JpBody>> oks;
    for (const auto& rep : pe->replies_) {
      if (!rep.ok) continue;
      jp::PullOk<JpBody> pk;
      pk.view_id = rep.view_id;
      if (!JpToEntries(rep.acked, &pk.acked)) {
        Log_error("[JETPACK-RECOVERY] PullRecovery v=%u: unparsable acked entry from site %d", v, rep.site);
      }
      for (const auto& a : rep.accepted->entries_) {
        std::vector<jp::Entry<JpBody>> val;
        if (!JpToEntries(a.value, &val)) {
          Log_error("[JETPACK-RECOVERY] PullRecovery v=%u: unparsable accepted entry from site %d", v, rep.site);
        }
        pk.accepted[a.vn] = std::make_pair(a.ballot, std::move(val));
      }
      oks.push_back(std::move(pk));
    }
    auto choice = jp::ChooseRecoveryValue(oks, threshold);
    value = std::make_shared<KeyCmdBatchData>();
    for (const auto& e : choice.value) {
      value->AddEntry(e.key, e.body);
    }
    Log_info("[JETPACK-RECOVERY] PullRecovery SUCCESS v=%u b=%lld vn=%u replies=%d set=%zu adopted=%d adopted_b=%lld wait=%lldms",
             v, (long long) b, choice.vn, (int) oks.size(), value->Size(), (int) choice.adopted,
             (long long) choice.adopted_ballot, JpMsSince(pull_start));

    // Phase 2: Accept at the same ballot b.
    auto accept_start = std::chrono::steady_clock::now();
    auto ae = commo()->JetpackBroadcastAccept(partition_id_, v, choice.vn, b, value);
    r = JpWaitValid(ae, v, JpNowUs() + kJpPhaseDeadlineUs);
    if (r != kJpValid) {
      stop(r, "accept");
      return;
    }
    if (!ae->Yes()) {
      auto cls = JpClassify(ae->replies_, v);
      Log_info("[JETPACK-RECOVERY] Accept FAILED v=%u vn=%u b=%lld round=%d yes=%d no=%d errors=%d wait=%lldms",
               v, choice.vn, (long long) b, round, ae->n_voted_yes_, ae->n_voted_no_, ae->n_errors_,
               JpMsSince(accept_start));
      if (cls.superseded) {
        stop(kJpSuperseded, "accept");
        return;
      }
      if (cls.finished) {
        stop(kJpFinishedElsewhere, "accept");
        return;
      }
      if (cls.max_promise_same_view > b) {
        jp_ballot_counter_ = std::max(jp_ballot_counter_, jp::BallotCounter(cls.max_promise_same_view));
      }
      // The next round re-Pulls with a new ballot and re-adopts accepted[vn]
      // if a value was chosen meanwhile.
      r = JpSleepValid(v, JpJitter(backoff));
      backoff = std::min(backoff * 2, kJpBackoffMaxUs);
      if (r != kJpValid) {
        stop(r, "accept backoff");
        return;
      }
      continue;
    }
    Log_info("[JETPACK-RECOVERY] Accept SUCCESS v=%u vn=%u b=%lld acks=%d/%d wait=%lldms",
             v, choice.vn, (long long) b, ae->n_voted_yes_, n, JpMsSince(accept_start));
    chosen_vn = choice.vn;
    chosen_b = b;
    break;
  }

  // From here on this coordinator aims to lead v: its own replica takes part
  // at ballot b (one agreed leader per view, jp::FinishBallotOk).
  JpValidity r = JpOwnAccept(target, chosen_vn, chosen_b, value);
  if (r != kJpValid) {
    stop(r, "own accept");
    return;
  }

  // ---- Phase 3: resubmit every member; FinishRecovery only after all SUCCESS ----
  r = JpResubmitAll(target, value, JpUsesStabilityMarker(), chosen_vn, chosen_b);
  if (r != kJpValid) {
    stop(r, "resubmit");
    return;
  }
  Log_info("[JETPACK-RECOVERY] All recovery completed v=%u members=%zu", v, value->Size());
  r = JpCheckValid(v);
  if (r != kJpValid) {
    stop(r, "before finish");
    return;
  }

  // ---- Phase 4: FinishRecovery(v) until a majority applied it ----
  // One leader per view id (etcd / MongoDB / ZooKeeper, where a takeover
  // can give view v several coordinators): this replica installs v from its
  // own FinishRecovery, and so starts leading v, only after n/2 other
  // replicas installed v with this coordinator as leader; with this replica
  // that is a majority (jp::SelfInstallAllowed). Raft has one coordinator per
  // term and sends the FinishRecovery to itself like to everybody
  // (JpCheckValid is not used from here on: our own applied FR sets
  // jepoch_ = v).
  const bool self_last = JpTakeoverEnabled();
  bool self_installed = !self_last;
  std::set<siteid_t> fr_done;     // applied v or are past it (pre-credited on resends)
  std::set<siteid_t> fr_ours;     // other replicas in view v led by this coordinator
  std::set<siteid_t> fr_foreign;  // other replicas in view v led by another coordinator
  int64_t fr_backoff = kJpFrBackoffMinUs;
  auto fr_wait_start = std::chrono::steady_clock::now();
  auto self_install_step = [&]() -> JpValidity {
    if (self_installed) return kJpValid;
    if (jp_driver_stop_) return kJpNotCoordinator;
    if (oepoch_ > v || jp_pending_view_ > v) return kJpSuperseded;
    // Another coordinator's FinishRecovery installed v here: it leads v.
    if (jepoch_ >= v) return kJpFinishedElsewhere;
    if (jp::SelfInstallAllowed(n, (int) fr_ours.size())) {
      if (!JpFinishLocally(v, target)) {
        Log_error("[JETPACK-RECOVERY] FinishRecovery v=%u: cannot install v here (view=%u vid=%u amnesiac=%d)",
                  v, jepoch_, oepoch_, (int) jp_rejoin_.amnesiac());
        return kJpNotCoordinator;
      }
      self_installed = true;
      fr_done.insert(site_id_);
      return kJpValid;
    }
    if (jp::SelfInstallImpossible(n, (int) fr_foreign.size())) return kJpFinishedElsewhere;
    return kJpValid;
  };
  JpValidity fr_r = self_install_step();  // n == 1: no other replica to wait for
  if (fr_r != kJpValid) {
    stop(fr_r, "finish");
    return;
  }
  while (true) {
    const int ours_needed = self_installed ? 0 : std::max(1, n / 2 - (int) fr_ours.size());
    // At the ballot that chose the value: replicas where a higher same-view
    // coordinator took part do not install it (jp::FinishBallotOk).
    auto fe = commo()->JetpackBroadcastFinishRecovery(partition_id_, v, chosen_b, target, fr_done,
                                                      /*wait_all=*/false,
                                                      self_installed ? -1 : (int) site_id_,
                                                      ours_needed);
    const int64_t deadline = JpNowUs() + kJpPhaseDeadlineUs;
    while (!fe->IsReady() && !jp_driver_stop_ && !JpNewerViewSeen(v) &&
           (self_installed || jepoch_ < v)) {
      int64_t left = deadline - JpNowUs();
      if (left <= 0) break;
      fe->Wait(JpClampWaitUs(left));
    }
    fr_done.insert(fe->done_.begin(), fe->done_.end());
    for (const auto& rep : fe->replies_) {
      if (rep.site == site_id_) continue;
      if (rep.applied) {
        fr_ours.insert(rep.site);
      } else if (rep.view_id == v) {
        fr_foreign.insert(rep.site);
      }
    }
    fr_r = self_install_step();
    if (fr_r != kJpValid) {
      stop(fr_r, "finish");
      return;
    }
    if (self_installed && (int) fr_done.size() >= n / 2 + 1) {
      break;
    }
    if (jp_driver_stop_ || JpNewerViewSeen(v) || fe->NewerViewSeen()) {
      // A newer recovery will unfreeze everybody.
      stop(kJpSuperseded, "finish");
      return;
    }
    std::string here;
    if (!self_installed) {
      here = " ours=" + std::to_string(fr_ours.size()) + " foreign=" +
             std::to_string(fr_foreign.size()) + ", not installed here yet";
    }
    Log_info("[JETPACK-RECOVERY] FinishRecovery v=%u not yet applied by a majority (done=%zu/%d errors=%d%s), resend in %lldms",
             v, fr_done.size(), n, fe->n_errors_, here.c_str(), (long long) (fr_backoff / 1000));
    const int64_t resend_at = JpNowUs() + fr_backoff;
    while (!jp_driver_stop_ && !JpNewerViewSeen(v) && (self_installed || jepoch_ < v) &&
           JpNowUs() < resend_at) {
      Reactor::CreateSpEvent<TimeoutEvent>(JpClampWaitUs(resend_at - JpNowUs()))->Wait();
    }
    fr_backoff = std::min(fr_backoff * 2, kJpFrBackoffMaxUs);
  }
  JpWriteFinishSignals();
  Log_info("[JETPACK-RECOVERY-FINISH-WAIT] FinishRecovery quorum ack after %lldms",
           JpMsSince(fr_wait_start));
  Log_info("[JETPACK-RECOVERY] FinishRecovery broadcast completed, fast path restored v=%u applied=%zu/%d",
           v, fr_done.size(), n);
  if ((int) fr_done.size() < n) {
    View t = target;
    std::set<siteid_t> done = fr_done;
    auto alive = jp_alive_;
    Coroutine::CreateRun([this, v, t, done, alive]() {
      this->JpFinishStragglers(v, t, done, alive);
    });
  }
  Log_info("[JETPACK-RECOVERY] ===== JETPACK RECOVERY COMPLETED ====== duration=%lldms time=%.6fms v=%u",
           JpMsSince(jetpack_recovery_start_time_), JpWallMs(), v);
}

TxLogServer::JpValidity TxLogServer::JpOwnAccept(const View& target, epoch_t vn, ballot_t b,
                                                 const shared_ptr<KeyCmdBatchData>& value) {
  const epoch_t v = target.view_id_;
  if (oepoch_ > v) return kJpSuperseded;
  if (jepoch_ >= v) return kJpFinishedElsewhere;
  if (jp::BallotView(jp_promised_) == v && jp_promised_ > b) {
    // A higher coordinator of v pulled this replica: it, not this one, is to
    // lead v (it adopts the same chosen value).
    Log_info("[JETPACK-RECOVERY] own replica promised b=%lld above b=%lld of v=%u: taken over",
             (long long) jp_promised_, (long long) b, v);
    return kJpTakenOver;
  }
  if (jp_rejoin_.RecoveryMsgAllowed() && jp::AcceptAllowed(jepoch_, oepoch_, jp_promised_, v, vn, b)) {
    // What this coordinator's Accept RPC to its own replica does (it may still
    // be in flight; applying it again later changes nothing).
    JpJoin(v);
    jp_promised_ = b;
    jp_accepted_[vn] = JpAccepted{b, value ? value : std::make_shared<KeyCmdBatchData>()};
  }
  jp_fr_floor_ = b;
  return kJpValid;
}

void TxLogServer::JpFinishStragglers(epoch_t v, View target, std::set<siteid_t> done,
                                     std::shared_ptr<std::atomic<bool>> alive) {
  // No try cap; capped backoff; stop when every replica is done or a
  // newer view is pending/joined here or reported by a replica. A replica
  // that stays down keeps this coroutine running until shutdown.
  const int n = Config::GetConfig()->GetPartitionSize(partition_id_);
  int64_t backoff = kJpFrBackoffMinUs;
  int rounds = 0;
  while ((int) done.size() < n) {
    const int64_t resend_at = JpNowUs() + backoff;
    while (!jp_driver_stop_ && !JpNewerViewSeen(v) && JpNowUs() < resend_at) {
      Reactor::CreateSpEvent<TimeoutEvent>(JpClampWaitUs(resend_at - JpNowUs()))->Wait();
      if (!alive->load()) {
        return;  // the server is gone: touch nothing of it
      }
    }
    if (jp_driver_stop_ || JpNewerViewSeen(v)) {
      Log_info("[JETPACK-RECOVERY] FinishRecovery stragglers v=%u: newer view here, stop (done=%zu/%d)",
               v, done.size(), n);
      return;
    }
    rounds++;
    // The leader of v is decided (a majority installed it): every replica
    // still frozen in v may install it, whatever ballot it took part in.
    auto fe = commo()->JetpackBroadcastFinishRecovery(partition_id_, v, jp::kChosenBallot, target, done,
                                                      /*wait_all=*/true);
    const int64_t deadline = JpNowUs() + kJpPhaseDeadlineUs;
    while (!fe->IsReady()) {
      int64_t left = deadline - JpNowUs();
      if (left <= 0) break;
      fe->Wait(JpClampWaitUs(left));
      if (!alive->load()) {
        return;
      }
    }
    done.insert(fe->done_.begin(), fe->done_.end());
    if (fe->NewerViewSeen()) {
      Log_info("[JETPACK-RECOVERY] FinishRecovery stragglers v=%u: a replica is past v, stop (done=%zu/%d)",
               v, done.size(), n);
      return;
    }
    if (rounds == 1 || rounds % 10 == 0 || (int) done.size() == n) {
      Log_info("[JETPACK-RECOVERY] FinishRecovery stragglers v=%u round=%d done=%zu/%d",
               v, rounds, done.size(), n);
    }
    backoff = std::min(backoff * 2, kJpFrBackoffMaxUs);
  }
}

// Duplicate-replay window (etcd / MongoDB / ZooKeeper). There the
// state machine is the external store: a resubmitted member is a plain
// backend write, with no exactly-once marker and no view fence (backend
// fencing / exactly-once is not implemented here). Raft is not affected: term
// fencing plus CommitReplicated's executed-flag dedup. On the other
// backends a replayed member can overwrite a later write to the same key when
//  1. it was already written through its own original path but not yet GC'd
//     at threshold-many Pull repliers, and a later original-path write to the
//     key landed before the replay;
//  2. several coordinators run for one term (a shared signal file with an
//     unknown etcd member id or a line without loc=/member=, a misconfigured
//     loc=/member=, a coordinator takeover): a slower coordinator's
//     resubmissions may still sit in the backend pool or be in flight after
//     another one's FinishRecovery reopened the partition and later writes
//     landed;
//  3. this coordinator is superseded or stops (JpCheckValid): resubmissions
//     already queued or in flight are not recalled;
//  4. an ambiguous backend failure (deadline, dropped connection) is retried,
//     although the first attempt may have been applied (at-least-once).
// Only the exposure is reduced: one coordinator per term (etcd member=, Mongo
// and ZooKeeper loc= lines and self-detection of the co-located node),
// strictly newer terms only, and on MongoDB directConnection (only the replica
// next to the primary can write).
TxLogServer::JpValidity TxLogServer::JpResubmitAll(const View& target,
                                                   const shared_ptr<KeyCmdBatchData>& value,
                                                   bool with_marker,
                                                   epoch_t vn,
                                                   ballot_t b) {
  const epoch_t v = target.view_id_;
  TxLogServer* txs = tx_sched_ ? tx_sched_ : this;
  std::vector<shared_ptr<JpMember>> members;
  for (size_t i = 0; value && i < value->Size(); i++) {
    auto m = std::make_shared<JpMember>();
    m->key = value->GetKey(i);
    m->body = JpRecoveredPieces(value->GetCommand(i));
    if (!m->body) {
      // Every pool entry is a VecPieceData; anything else cannot be replayed.
      Log_error("[JETPACK-RECOVERY] Resubmit v=%u: member key=%d has no replayable body (kind=%d), skipped",
                v, m->key, value->GetCommand(i) ? value->GetCommand(i)->kind_ : -1);
      continue;
    }
    auto& piece0 = m->body->sp_vec_piece_data_->at(0);
    m->tx_id = piece0->root_id_;
    m->cmd_id = SimpleRWCommand::CombineInt32(piece0->client_id_, piece0->cmd_id_in_client_);
    members.push_back(m);
  }
  if (with_marker) {
    // Stability marker: committed in term v through this leader, it
    // commits every older entry of the log before FinishRecovery(v).
    auto piece = std::make_shared<TxPieceData>();
    piece->id_ = kJpMarkerTxBase | (txnid_t) v;
    piece->root_id_ = piece->id_;
    piece->type_ = RW_BENCHMARK_R_TXN_0;
    piece->inn_id_ = RW_BENCHMARK_R_TXN_0;
    piece->root_type_ = RW_BENCHMARK_R_TXN;
    piece->partition_id_ = partition_id_;
    piece->client_id_ = kJpMarkerClientId;
    piece->cmd_id_in_client_ = (int32_t) v;
    piece->input[0] = Value((i32) 0);
    auto m = std::make_shared<JpMember>();
    m->marker = true;
    m->key = 0;
    m->tx_id = piece->root_id_;
    m->cmd_id = SimpleRWCommand::CombineInt32(piece->client_id_, piece->cmd_id_in_client_);
    m->body = std::make_shared<VecPieceData>();
    m->body->sp_vec_piece_data_ = std::make_shared<vector<shared_ptr<TxPieceData>>>();
    m->body->sp_vec_piece_data_->push_back(piece);
    members.push_back(m);
  }
  Log_info("[JETPACK-RECOVERY] Resubmit v=%u members=%zu marker=%d via own replication coordinator",
           v, members.size(), (int) with_marker);

  // "Current wake-up event" holder: a completion Sets whatever event the
  // loop waits on at that moment.
  auto wake = std::make_shared<shared_ptr<IntEvent>>(Reactor::CreateSpEvent<IntEvent>());
  auto submit = [this, v, wake, txs](const shared_ptr<JpMember>& m) {
    if (!m->marker) {
      // Already executed here (e.g. committed through its own Dispatch).
      auto tx = txs->GetTx(m->tx_id);
      if (tx && tx->committed_) {
        m->state = JpMember::kDone;
        m->last_code = SUCCESS;
        return;
      }
    }
    // A fresh recovery-flagged command for every attempt; the body came from
    // an RPC reply and is shared with no pool.
    auto vpd = std::make_shared<VecPieceData>();
    vpd->sp_vec_piece_data_ = m->body->sp_vec_piece_data_;
    vpd->time_sent_from_client_ = m->body->time_sent_from_client_;
    vpd->is_recovery_command_ = true;
    auto tpc = std::make_shared<TpcCommitCommand>();
    tpc->tx_id_ = m->tx_id;
    tpc->ret_ = m->marker ? REJECT : SUCCESS;
    tpc->term = 0;
    tpc->cmd_ = vpd;
    m->state = JpMember::kInflight;
    m->attempts++;
    Coroutine::CreateRun([this, v, wake, m, tpc]() {
      auto called = std::make_shared<bool>(false);
      shared_ptr<Coordinator> coo{CreateRepCoord(0)};
      shared_ptr<Marshallable> sp_m = tpc;
      coo->Submit(sp_m, [v, wake, m, tpc, called]() {
        *called = true;
        const int code = tpc->ret_;
        // Only SUCCESS counts; the marker keeps its no-op REJECT unless the
        // coordinator bounced it (WRONG_LEADER).
        const bool ok = m->marker ? (code == REJECT) : (code == SUCCESS);
        m->last_code = code;
        if (ok) {
          m->state = JpMember::kDone;
        } else {
          m->state = JpMember::kFailed;
          m->next_try_us = JpNowUs() + JpRetryBackoffUs(m->attempts);
          if (code == REJECT) {
            Log_error("[JETPACK-RECOVERY] Resubmit v=%u key=%d tx=%llu was REJECTed (attempt %d), retrying",
                      v, m->key, (unsigned long long) m->tx_id, m->attempts);
          } else if (m->attempts == 1 || m->attempts % 10 == 0) {
            Log_info("[JETPACK-RECOVERY] Resubmit v=%u key=%d tx=%llu failed with %d (attempt %d), retrying",
                     v, m->key, (unsigned long long) m->tx_id, code, m->attempts);
          }
        }
        (*wake)->Set(1);
      });
      if (!*called && m->state == JpMember::kInflight) {
        m->state = JpMember::kFailed;
        m->last_code = kJpNoCallback;
        m->next_try_us = JpNowUs() + JpRetryBackoffUs(m->attempts);
        (*wake)->Set(1);
      }
    });
  };

  // Keepalive (etcd / MongoDB / ZooKeeper): re-send Accept(v, vn, b,
  // value) every jp::kKeepaliveEveryUs. It is idempotent where b is still the
  // promise and counts as recovery progress there, so frozen replicas do not
  // take a live recovery over; its replies stop this resubmission once the
  // recovery was superseded, finished elsewhere or taken over (a higher
  // ballot of v: that coordinator adopts the same chosen value).
  const bool keepalive = JpTakeoverEnabled();
  auto ka_events = std::make_shared<std::vector<shared_ptr<JetpackAcceptQuorumEvent>>>();
  int64_t next_keepalive = JpNowUs() + jp::kKeepaliveEveryUs;
  auto keepalive_verdict = [&]() -> JpValidity {
    for (auto it = ka_events->begin(); it != ka_events->end();) {
      const auto& e = *it;
      for (const auto& rep : e->replies_) {
        const jp::KeepaliveVerdict kv =
            jp::ClassifyKeepaliveReply(v, b, rep.view_id, rep.vid, rep.promised);
        if (kv == jp::KeepaliveVerdict::kContinue) continue;
        Log_info("[JETPACK-RECOVERY] keepalive Accept v=%u vn=%u b=%lld: site %d reports view=%u vid=%u promised=%lld",
                 v, vn, (long long) b, rep.site, rep.view_id, rep.vid, (long long) rep.promised);
        if (kv == jp::KeepaliveVerdict::kSuperseded) return kJpSuperseded;
        if (kv == jp::KeepaliveVerdict::kFinishedElsewhere) return kJpFinishedElsewhere;
        return kJpTakenOver;
      }
      if ((int) e->replies_.size() + e->n_errors_ >= e->n_total_) {
        it = ka_events->erase(it);  // every reply seen
      } else {
        ++it;
      }
    }
    return kJpValid;
  };

  const auto start = std::chrono::steady_clock::now();
  int64_t last_log = JpNowUs();
  while (true) {
    const int64_t now = JpNowUs();
    int64_t earliest = std::numeric_limits<int64_t>::max();
    for (auto& m : members) {
      if (m->state != JpMember::kPending && m->state != JpMember::kFailed) continue;
      if (now >= m->next_try_us) {
        submit(m);
      } else {
        earliest = std::min(earliest, m->next_try_us);
      }
    }
    size_t done = 0;
    for (auto& m : members) {
      done += (m->state == JpMember::kDone) ? 1 : 0;
    }
    if (done == members.size()) {
      Log_info("[JETPACK-RECOVERY] Resubmit v=%u done=%zu/%zu after %lldms",
               v, done, members.size(), JpMsSince(start));
      return kJpValid;
    }
    if (keepalive && now >= next_keepalive) {
      next_keepalive = now + jp::kKeepaliveEveryUs;
      // Its own coroutine: the broadcaster yields (WAN_WAIT) before sending.
      Coroutine::CreateRun([this, v, vn, b, value, ka_events]() {
        ka_events->push_back(commo()->JetpackBroadcastAccept(partition_id_, v, vn, b, value));
      });
    }
    int64_t wait_us = kJpSliceUs;
    if (earliest != std::numeric_limits<int64_t>::max()) {
      wait_us = std::min(wait_us, earliest - now);
    }
    if (keepalive) {
      wait_us = std::min(wait_us, next_keepalive - now);
    }
    (*wake)->Wait(JpClampWaitUs(wait_us));
    // Single reactor thread: a completion that ran before this re-arm already
    // updated its member, which the next scan sees; a later one Sets the new
    // event.
    *wake = Reactor::CreateSpEvent<IntEvent>();
    JpValidity r = JpCheckValid(v);
    if (r == kJpValid && keepalive) {
      r = keepalive_verdict();
    }
    if (r != kJpValid) {
      size_t d = 0;
      for (auto& m : members) d += (m->state == JpMember::kDone) ? 1 : 0;
      Log_info("[JETPACK-RECOVERY] Resubmit v=%u stopped (%s) done=%zu/%zu",
               v, JpValidityName(r), d, members.size());
      return r;
    }
    if (JpNowUs() - last_log >= kJpResubmitLogEveryUs) {
      last_log = JpNowUs();
      std::map<int, int> codes;
      size_t d = 0, inflight = 0;
      for (auto& m : members) {
        if (m->state == JpMember::kDone) d++;
        else if (m->state == JpMember::kInflight) inflight++;
        else if (m->state == JpMember::kFailed) codes[m->last_code]++;
      }
      std::ostringstream oss;
      for (auto& kv : codes) oss << kv.first << "x" << kv.second << " ";
      Log_info("[JETPACK-RECOVERY] resubmit v=%u done=%zu/%zu inflight=%zu failed_codes=%s",
               v, d, members.size(), inflight, oss.str().c_str());
    }
  }
}

/************************* Jetpack recovery end *****************************/

} // namespace janus
