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
  StartCpuMonitorIfNeeded();
  return last_cpu_usage_;
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
                    bool_t* accepted,
                    value_t* result,
                    bool_t* is_leader,
                    double* cpu_usage,
                    double* queue_depth) {
#ifdef JETPACK_PROF
  auto prof_t0 = std::chrono::steady_clock::now();
#endif
  if (paused_) { // [Jetpack] Bad fix, should be blocked from handle_write, not to this layer
    *accepted = false;
    *result = 0;
    *is_leader = false;
    if (cpu_usage) *cpu_usage = -1.0;
    if (queue_depth) *queue_depth = -1.0;
    return;
  }
  // CURP mode: leader checks Raft log for conflicts, non-leader checks command pool
  bool curp_mode = Config::GetConfig()->jetpack_fastpath_attempt_rate_ == CURP_MODE;
  bool no_conflict;
  if (curp_mode && IsLeader()) {
    // CURP leader: check uncommitted Raft log entries for key conflicts
    no_conflict = !ConflictWithUncommittedRaftLog(cmd);
    // Leader does NOT insert into command pool — it uses the log as source of truth
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
    no_conflict = rep_sched_->command_pool_.push_back(cmd);
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
  *is_leader = IsLeader();
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
    // Log_info("[JETPACK-CommandPool] loc_id %d about to push_back", loc_id_);
    rep_sched_->command_pool_.push_back(cmd);
  }
}

void TxLogServer::RuleCommandPoolGC(const shared_ptr<Marshallable>& cmd) {
  if (Config::GetConfig()->tx_proto_ == MODE_RULE)
    command_pool_.remove(cmd);
  // SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
  // uint64_t cmd_id = SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second);
  // Log_info("command_pool_.remove server %d remove cmd_id <%d, %d> %lld key %d success %d", loc_id_, parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second,
  //     (long long)SimpleRWCommand::CombineInt32(parsed_cmd.cmd_id_.first, parsed_cmd.cmd_id_.second), parsed_cmd.key_, command_pool_.remove(cmd));
  // Log_info("command_pool_.remove(cmd) %d", command_pool_.remove(cmd));
  // command_pool_.remove(cmd);
}


bool TxLogServer::ConflictWithUncommittedRaftLog(const shared_ptr<Marshallable>& cmd) {
  auto key = SimpleRWCommand::GetKey(cmd);
  auto cmd_id = SimpleRWCommand::GetCombinedCmdID(cmd);
  auto* raft_svr = dynamic_cast<RaftServer*>(rep_sched_);
  if (!raft_svr) return false;  // safety: should not happen in CURP mode

  // Scan uncommitted entries: commitIndex+1 to lastLogIndex
  // Use find() instead of operator[] to avoid creating spurious map entries.
  for (uint64_t i = raft_svr->commitIndex + 1; i <= raft_svr->lastLogIndex; i++) {
    auto it = raft_svr->raft_logs_.find(i);
    if (it == raft_svr->raft_logs_.end()) continue;
    auto& sp_instance = it->second;
    if (sp_instance && sp_instance->log_) {
      // Skip the command itself (it may already be in the log from the Raft Submit path)
      auto log_cmd_id = SimpleRWCommand::GetCombinedCmdID(sp_instance->log_);
      if (log_cmd_id == cmd_id) continue;
      auto log_key = SimpleRWCommand::GetKey(sp_instance->log_);
      if (log_key == key) return true;  // conflict: different command on same key
    }
  }
  return false;  // no conflict
}

void RevoveryCandidates::push_back(uint64_t cmd_id, shared_ptr<Marshallable> cmd, bool is_write) {
  candidates_[cmd_id] = Entry{cmd, is_write};
  if (total_write_ == 0 && is_write) {
    verify(to_recover_id_ == (uint64_t)(-1));
    to_recover_id_ = cmd_id;
  }
  total_write_ += is_write;
#ifdef JETPACK_DEDUPLICATE_OPTIMIZATION
  appeared_[cmd_id] = true;
#endif
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

int RevoveryCandidates::total_write() {
  return total_write_;
}

bool RevoveryCandidates::has_cmd_to_recover() const {
  return to_recover_id_ != (uint64_t)(-1);
}

shared_ptr<Marshallable> RevoveryCandidates::cmd_to_recover() {
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

bool JetpackCommandPool::push_back(const shared_ptr<Marshallable>& cmd) {
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
  bool was_empty = bucket.size() == 0;

#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-DEBUG] JetpackCommandPool::push_back called for key=%d, cmd_id=%lu", key, cmd_id);
#endif

#ifdef JETPACK_PROF
  auto t_inner0 = std::chrono::steady_clock::now();
#endif
#ifdef READ_NOT_CONFLICT_OPTIMIZATION
  if (bucket.total_write() == 0) {
#endif
#ifndef READ_NOT_CONFLICT_OPTIMIZATION
  if (bucket.size() == 0) {
#endif
    // not exist conflict
    bucket.push_back(cmd_id, cmd, is_write);
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-DEBUG] Added cmd to candidates[%d], no conflict", key);
#endif
#ifdef COMMAND_POOL_LOG_DEBUG
    pool_log_.push_back(CommandPoolLog(0, cmd, 1, pool_size_));
#endif
#ifdef COMMAND_POOL_ON_DISK
    // Disk write still needs value; fall back to full parse on the rare path.
    WriteCommandToDisk(SimpleRWCommand(cmd));
#endif
    pool_cmd_count_++;
    if (was_empty) {
      pool_size_distribution_.mid_time_append(++pool_size_);
    }
#ifdef JETPACK_PROF
    auto t_inner1 = std::chrono::steady_clock::now();
    if (owner_) {
      owner_->prof_pool_inner_insert_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(t_inner1 - t_inner0).count(),
          std::memory_order_relaxed);
      uint64_t prev_keys = owner_->prof_pool_peak_keys_.load(std::memory_order_relaxed);
      while ((uint64_t)pool_size_ > prev_keys &&
             !owner_->prof_pool_peak_keys_.compare_exchange_weak(prev_keys, pool_size_));
      uint64_t prev_cmds = owner_->prof_pool_peak_cmds_.load(std::memory_order_relaxed);
      while ((uint64_t)pool_cmd_count_ > prev_cmds &&
             !owner_->prof_pool_peak_cmds_.compare_exchange_weak(prev_cmds, pool_cmd_count_));
    }
#endif
    return true;
  } else {
    // exist conflict, candidates_[key].size() >= 1
    bucket.push_back(cmd_id, cmd, is_write);
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-DEBUG] Added cmd to candidates[%d], WITH conflict (size now=%zu)",
             key, bucket.size());
#endif
#ifdef COMMAND_POOL_LOG_DEBUG
    pool_log_.push_back(CommandPoolLog(0, cmd, 0, pool_size_));
#endif
    pool_cmd_count_++;
#ifdef JETPACK_PROF
    auto t_inner1 = std::chrono::steady_clock::now();
    if (owner_) {
      owner_->prof_pool_inner_insert_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(t_inner1 - t_inner0).count(),
          std::memory_order_relaxed);
    }
#endif
    return false;
  }
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

shared_ptr<VecRecData> JetpackCommandPool::id_set() {
  auto result = std::make_shared<VecRecData>();
  result->key_data_ = std::make_shared<vector<key_t>>();
  
  for (const auto& kv : candidates_) {
    key_t key = kv.first;
    if (kv.second.has_cmd_to_recover()) {
      result->key_data_->push_back(key);
    }
  }
  
#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY-CommandPool] id_set size %d", result->key_data_->size());
#endif

  return result;
}

void JetpackCommandPool::reset() {
  candidates_.clear();
  pool_size_ = 0;
  pool_cmd_count_ = 0;
  pool_size_distribution_ = Distribution();
  
  // Reset recovery related fields
  max_seen_ballot_ = -1;
  max_accepted_ballot_ = -1;
  sid_ = -1;
  committed_ = false;
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


void TxLogServer::JetpackRecoveryEntry() {
  jetpack_recovery_start_time_ = std::chrono::steady_clock::now();
  struct timeval recovery_start_tv;
  gettimeofday(&recovery_start_tv, nullptr);
  double recovery_start_ms = static_cast<double>(recovery_start_tv.tv_sec) * 1000.0 +
                             static_cast<double>(recovery_start_tv.tv_usec) / 1000.0;
  Log_info("[JETPACK-RECOVERY] ===== STARTING JETPACK RECOVERY ====== time=%.6fms",
           recovery_start_ms);
  Log_info("[JETPACK-RECOVERY] Leader: site_id=%d, jepoch=%d, oepoch=%d", site_id_, jepoch_, oepoch_);
  jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;

  // Emit fastpath_stopped signal so the new leader's backend knows the
  // Jetpack fast path is now stopped and it is safe to resume request
  // processing.  This signal must be written as soon as we enter RECOVERY,
  // *before* the multi-phase recovery protocol runs.
  {
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
    jm_signal::set_key("jetpack", "fastpath_stopped", host);
    Log_info("[JETPACK-RECOVERY] Emitted jetpack:fastpath_stopped on JM_Jetpack_%s",
             host.c_str());
  }

  // Combined recovery RPC: updates views and pulls commands
  JetpackRecovery();

  // // Comment JetpackRecovery(); and uncomment below can enable original path failure recovery only
  // Log_info("Mark FinishRecovery on %s", "recovery_finish");
  // jm_signal::set_key("jetpack", "recovery_finish", "recovery_finish");
  // Log_info("[JETPACK-RECOVERY] Wrote finish signal to JM_Jetpack_%s", "recovery_finish");
  // if (jm_signal::exists_key("failure", "failure_triggered", "failure_triggered")) {
  //   jm_signal::set_key("jetpack", "recovery_finish_after_failure", "recovery_finish_after_failure");
  //   Log_info("[JETPACK-RECOVERY] Wrote post-failure finish signal to JM_Jetpack_%s",
  //             "recovery_finish_after_failure");
  // }
  // auto e = commo()->JetpackBroadcastFinishRecovery(partition_id_, site_id_, oepoch_);
  
  auto recovery_end_time = std::chrono::steady_clock::now();
  auto recovery_duration_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      recovery_end_time - jetpack_recovery_start_time_).count();
  struct timeval recovery_end_tv;
  gettimeofday(&recovery_end_tv, nullptr);
  double recovery_end_ms = static_cast<double>(recovery_end_tv.tv_sec) * 1000.0 +
                           static_cast<double>(recovery_end_tv.tv_usec) / 1000.0;
  Log_info("[JETPACK-RECOVERY] ===== JETPACK RECOVERY COMPLETED ====== duration=%lldms time=%.6fms",
           static_cast<long long>(recovery_duration_ms),
           recovery_end_ms);
}


void TxLogServer::JetpackRecovery() {
  Log_info("[JETPACK-RECOVERY] Step 1: PullRecovery + Prepare (parallel) for partition %d", partition_id_);

  const auto step1_start = std::chrono::steady_clock::now();
  const auto pull_start = step1_start;
  auto recovery_e = commo()->JetpackBroadcastPullRecovery(partition_id_, site_id_, old_view_, new_view_, jepoch_, oepoch_);

  const auto prepare_start = std::chrono::steady_clock::now();
  auto prepare_e = commo()->JetpackBroadcastPrepare(
      partition_id_, site_id_, jepoch_, oepoch_, command_pool_.max_seen_ballot_);

  // Round 1: PullRecovery and Prepare in parallel.
  prepare_e->Wait();
  auto prepare_wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - prepare_start).count();
  recovery_e->Wait();
  auto pull_wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - pull_start).count();
  const auto round1_handle_start = std::chrono::steady_clock::now();

  if (!recovery_e->Yes()) {
    Log_info("[JETPACK-RECOVERY] PullRecovery FAILED: got %d/%d responses wait=%lldms",
             recovery_e->n_voted_yes_, recovery_e->n_total_, (long long) pull_wait_ms);
    if (recovery_e->max_jepoch_ > jepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating jepoch from %d to %d", jepoch_, recovery_e->max_jepoch_);
#endif
      jepoch_ = recovery_e->max_jepoch_;
      command_pool_.reset();
    }
    if (recovery_e->max_oepoch_ > oepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating oepoch from %d to %d", oepoch_, recovery_e->max_oepoch_);
#endif
      oepoch_ = recovery_e->max_oepoch_;
    }
    auto step1_end = std::chrono::steady_clock::now();
    auto handle_round1_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step1_end - round1_handle_start).count();
    auto step1_total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step1_end - step1_start).count();
    Log_info("[JETPACK-RECOVERY][STEP1] pull_wait=%lldms prepare_wait=%lldms handle=%lldms total=%lldms",
             (long long) pull_wait_ms, (long long) prepare_wait_ms,
             (long long) handle_round1_ms, (long long) step1_total_ms);
    return;
  }

  auto recovered_key_ids = recovery_e->GetRecoveredKeyIds();
  Log_info("[JETPACK-RECOVERY] PullRecovery SUCCESS: recovered %zu key-ids wait=%lldms",
           recovered_key_ids.size(), (long long) pull_wait_ms);

  sid = ((sid_cnt_++) << 8) | loc_id_;

  // Record id set into local rec_set_
  rec_set_.set_rec_set(sid, recovered_key_ids);
  // Build missing list where local command pool lacks matching cmd id
  std::vector<std::pair<key_t, uint64_t>> missing_ids;
  for (const auto& entry : recovered_key_ids) {
    key_t key = entry.first;
    uint64_t cmd_id = entry.second;
    auto it = command_pool_.candidates_.find(key);
    auto has_local = it != command_pool_.candidates_.end() && it->second.get_cmd(cmd_id);
    if (!has_local) {
      missing_ids.push_back(entry);
    }
  }

  bool prepare_ok = prepare_e->Yes();
  int propose_sid = sid;
  if (prepare_ok && prepare_e->HasValue()) {
    propose_sid = prepare_e->GetSid();
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Using previously accepted value: sid=%d", propose_sid);
#endif
  } else if (prepare_ok) {
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] No previous value, proposing recovered values: sid=%d", propose_sid);
#endif
  }

  auto step1_end = std::chrono::steady_clock::now();
  auto handle_round1_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      step1_end - round1_handle_start).count();
  auto step1_total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      step1_end - step1_start).count();
  Log_info("[JETPACK-RECOVERY][STEP1] pull_wait=%lldms prepare_wait=%lldms handle=%lldms total=%lldms",
           (long long) pull_wait_ms, (long long) prepare_wait_ms,
           (long long) handle_round1_ms, (long long) step1_total_ms);

  // Round 2: RecordCmd and Accept (if Prepare succeeded) in parallel.
  const auto step2_start = std::chrono::steady_clock::now();
  auto record_start = std::chrono::steady_clock::now();
  auto record_e = commo()->JetpackBroadcastRecordCmd(partition_id_, site_id_, jepoch_, oepoch_, sid, recovered_key_ids, missing_ids);

  std::shared_ptr<JetpackAcceptQuorumEvent> accept_e = nullptr;
  std::chrono::steady_clock::time_point accept_start;
  if (prepare_ok) {
    Log_info("[JETPACK-RECOVERY] Step 2: Starting Paxos Accept phase");
    command_pool_.max_seen_ballot_++;
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Accept: proposing sid=%d, ballot=%lld",
             propose_sid, command_pool_.max_seen_ballot_);
#endif
    accept_start = std::chrono::steady_clock::now();
    accept_e = commo()->JetpackBroadcastAccept(
        partition_id_, site_id_, jepoch_, oepoch_, command_pool_.max_seen_ballot_, propose_sid);
  }

  long long accept_wait_ms = 0;
  if (accept_e) {
    accept_e->Wait();
    accept_wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - accept_start).count();
  }
  if (record_e) {
    record_e->Wait();
  }
  auto record_wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - record_start).count();
  
      auto round2_handle_start = std::chrono::steady_clock::now();
  
  if (record_e) {
    if (record_e->Yes()) {
      std::vector<std::pair<key_t, shared_ptr<Marshallable>>> missed_cmds;
      for (const auto& kv : record_e->GetRecoveredCmds()) {
        auto key = kv.first;
        auto cmd = kv.second;
        if (!cmd) {
          continue;
        }
        missed_cmds.emplace_back(key, cmd);
      }
      rec_set_.set_missed_key_cmd_set(sid, missed_cmds);
      Log_info("[JETPACK-RECOVERY] RecordCmd SUCCESS: recorded=%zu wait=%lldms",
               recovered_key_ids.size(), (long long) record_wait_ms);
    } else {
      Log_info("[JETPACK-RECOVERY] RecordCmd FAILED: got %d/%d responses wait=%lldms",
               record_e->n_voted_yes_, record_e->n_total_, (long long) record_wait_ms);
    }
  }

  if (!prepare_ok) {
    Log_info("[JETPACK-RECOVERY] Prepare FAILED: got %d/%d responses", prepare_e->n_voted_yes_, prepare_e->n_total_);
    if (prepare_e->max_jepoch_ > jepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating jepoch from %d to %d", jepoch_, prepare_e->max_jepoch_);
#endif
      jepoch_ = prepare_e->max_jepoch_;
      command_pool_.reset();
    }
    if (prepare_e->max_oepoch_ > oepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating oepoch from %d to %d", oepoch_, prepare_e->max_oepoch_);
#endif
      oepoch_ = prepare_e->max_oepoch_;
    }
    if (prepare_e->max_seen_ballot_ > command_pool_.max_seen_ballot_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating ballot from %lld to %lld",
               command_pool_.max_seen_ballot_, prepare_e->max_seen_ballot_);
#endif
      command_pool_.max_seen_ballot_ = prepare_e->max_seen_ballot_;
    }
    auto step2_end = std::chrono::steady_clock::now();
    auto handle_round2_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step2_end - round2_handle_start).count();
    auto step2_total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step2_end - step2_start).count();
    Log_info("[JETPACK-RECOVERY][STEP2] record_wait=%lldms accept_wait=%lldms handle=%lldms total=%lldms",
             (long long) record_wait_ms, 0LL,
             (long long) handle_round2_ms, (long long) step2_total_ms);
    return;
  }

  if (accept_e && !accept_e->Yes()) {
    Log_info("[JETPACK-RECOVERY] Accept FAILED: got %d/%d responses", accept_e->n_voted_yes_, accept_e->n_total_);
    if (accept_e->max_jepoch_ > jepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating jepoch from %d to %d", jepoch_, accept_e->max_jepoch_);
#endif
      jepoch_ = accept_e->max_jepoch_;
      command_pool_.reset();
    }
    if (accept_e->max_oepoch_ > oepoch_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating oepoch from %d to %d", oepoch_, accept_e->max_oepoch_);
#endif
      oepoch_ = accept_e->max_oepoch_;
    }
    if (accept_e->max_seen_ballot_ > command_pool_.max_seen_ballot_) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Updating ballot from %lld to %lld",
               command_pool_.max_seen_ballot_, accept_e->max_seen_ballot_);
#endif
      command_pool_.max_seen_ballot_ = accept_e->max_seen_ballot_;
    }
    auto step2_end = std::chrono::steady_clock::now();
    auto handle_round2_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step2_end - round2_handle_start).count();
    auto step2_total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        step2_end - step2_start).count();
    Log_info("[JETPACK-RECOVERY][STEP2] record_wait=%lldms accept_wait=%lldms handle=%lldms total=%lldms",
             (long long) record_wait_ms, (long long) accept_wait_ms,
             (long long) handle_round2_ms, (long long) step2_total_ms);
    return;
  }

  auto step2_end = std::chrono::steady_clock::now();
  auto handle_round2_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      step2_end - round2_handle_start).count();
  auto step2_total_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      step2_end - step2_start).count();

  Log_info("[JETPACK-RECOVERY][STEP2] record_wait=%lldms accept_wait=%lldms handle=%lldms total=%lldms",
           (long long) record_wait_ms, (long long) accept_wait_ms,
           (long long) handle_round2_ms, (long long) step2_total_ms);

  Log_info("[JETPACK-RECOVERY] Accept SUCCESS: got %d/%d responses, proceeding to commit sid=%d",
           accept_e->n_voted_yes_, accept_e->n_total_, propose_sid);
  JetpackCommit(propose_sid);
  
}

void TxLogServer::JetpackCommit(int commit_sid) {
  Log_info("[JETPACK-RECOVERY] Step 3: Broadcasting Commit for consensus decision");
#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY] Commit: sid=%d", commit_sid);
#endif
  
  // Commit cannot fail - it's just notification after successful Accept
  auto e = commo()->JetpackBroadcastCommit(partition_id_, site_id_, jepoch_, oepoch_, commit_sid);
  // e->Wait(); // Wait for at least 1 response (quorum size can be 1)
  
#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY] Commit sent for sid=%d, proceeding to resubmit", commit_sid);
#endif
  JetpackResubmit(commit_sid);
}

void TxLogServer::JetpackResubmit(int sid) {
  const int batch_size = 1;
  Log_info("[JETPACK-RECOVERY] Step 4: Starting resubmit process for sid=%d (batch_size=%d)",
           sid, batch_size);

  std::vector<std::shared_ptr<TpcCommitCommand>> cmds_to_dispatch;
  const auto* rec_vec = rec_set_.get_rec_set(sid);
  const auto* missed_vec = rec_set_.get_missed_key_cmd_set(sid);
  std::unordered_map<key_t, shared_ptr<Marshallable>> missed_map;
  if (missed_vec) {
    for (const auto& kv : *missed_vec) {
      if (kv.second) {
        missed_map.emplace(kv.first, kv.second);
      }
    }
  }

  if (rec_vec) {
    for (const auto& entry : *rec_vec) {
      key_t key = entry.first;
      uint64_t cmd_id = entry.second;
      shared_ptr<Marshallable> cmd = nullptr;
      auto wit_it = command_pool_.candidates_.find(key);
      if (wit_it != command_pool_.candidates_.end()) {
        cmd = wit_it->second.get_cmd(cmd_id);
      }
      if (!cmd) {
        auto miss_it = missed_map.find(key);
        if (miss_it != missed_map.end()) {
          auto candidate = miss_it->second;
          if (candidate && SimpleRWCommand::GetCombinedCmdID(candidate) == cmd_id) {
            cmd = candidate;
          }
        }
      }
      if (!cmd || cmd->kind_ == MarshallDeputy::CMD_TPC_EMPTY) {
        continue;
      }
      auto tpc_cmd = std::dynamic_pointer_cast<TpcCommitCommand>(cmd);
      if (!tpc_cmd && cmd->kind_ == MarshallDeputy::CMD_VEC_PIECE) {
        auto vec_cmd = std::dynamic_pointer_cast<VecPieceData>(cmd);
        if (vec_cmd) {
          auto wrapper = std::make_shared<TpcCommitCommand>();
          wrapper->cmd_ = vec_cmd;
          tpc_cmd = wrapper;
        }
      }
      if (tpc_cmd) {
        cmds_to_dispatch.push_back(tpc_cmd);
      }
    }
  }

  const int total_to_dispatch = static_cast<int>(cmds_to_dispatch.size());
  shared_ptr<IntEvent> recovery_event = nullptr;
  if (total_to_dispatch > 0) {
    recovery_event = Reactor::CreateSpEvent<IntEvent>(total_to_dispatch);
  }

  std::vector<std::shared_ptr<TpcCommitCommand>> batch_buffer;
  batch_buffer.reserve(batch_size);
  int resubmitted = 0;
  auto flush_batch = [&]() {
    if (batch_buffer.empty()) return;
    size_t batch_count = batch_buffer.size();
    DispatchRecoveredBatch(batch_buffer, recovery_event);
    resubmitted += batch_count;
    if ((resubmitted % 100) == 0 || resubmitted == total_to_dispatch) {
      Log_info("[JETPACK-RECOVERY] Step 4: Resubmitted %d/%d commands for sid=%d",
               resubmitted, total_to_dispatch, sid);
    }
    batch_buffer.clear();
  };

  for (const auto& tpc_cmd : cmds_to_dispatch) {
    batch_buffer.push_back(tpc_cmd);
    if (batch_buffer.size() >= static_cast<size_t>(batch_size)) {
      flush_batch();
    }
  }

  flush_batch();
  
  // Wait for all recovery dispatches to complete
  if (recovery_event && recovery_event->target_ > 0) {
    auto start_time = std::chrono::steady_clock::now();
    recovery_event->Wait();
    auto end_time = std::chrono::steady_clock::now();
    auto wait_duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time).count();
    Log_info("[JETPACK-RECOVERY-EVENT] Wait() completed after %ldms. Final value=%d, target=%d", 
             wait_duration, recovery_event->value_, recovery_event->target_);
    Log_info("[JETPACK-RECOVERY] All recovery completed");
  }
  
  Log_info("[JETPACK-RECOVERY] Step 5: Broadcasting FinishRecovery to complete recovery");

  // Finally, broadcast FinishRecovery to update jepoch and make fast path available
#if defined(JETPACK_MONGODB_RECOVERY) || defined(JETPACK_ETCD_RECOVERY) || defined(JETPACK_ZOOKEEPER_RECOVERY)
  Log_info("Mark FinishRecovery on %s", "recovery_finish");
  jm_signal::set_key("jetpack", "recovery_finish", "recovery_finish");
  Log_info("[JETPACK-RECOVERY] Wrote finish signal to JM_Jetpack_%s", "recovery_finish");
  if (jm_signal::exists_key("failure", "failure_triggered", "failure_triggered")) {
    jm_signal::set_key("jetpack", "recovery_finish_after_failure", "recovery_finish_after_failure");
    Log_info("[JETPACK-RECOVERY] Wrote post-failure finish signal to JM_Jetpack_%s",
              "recovery_finish_after_failure");
  }
#endif
  
  auto e = commo()->JetpackBroadcastFinishRecovery(partition_id_, site_id_, oepoch_);
  // e->Wait(); [Jetpack] BroadcastFinishRecovery do not need to sync
  
  Log_info("[JETPACK-RECOVERY] FinishRecovery broadcast completed, fast path restored");
}


void TxLogServer::DispatchRecoveredBatch(
    const std::vector<std::shared_ptr<TpcCommitCommand>>& batch,
    shared_ptr<IntEvent> recovery_event) {
  if (batch.empty()) {
    return;
  }
  auto batch_cmd = std::make_shared<TpcBatchCommand>();
  auto cmds = batch;
  batch_cmd->AddCmds(cmds);
#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY] Dispatching recovered batch of %zu commands", batch.size());
#endif
  DispatchRecoveredCommand(batch_cmd, recovery_event);
}

void TxLogServer::DispatchRecoveredCommand(shared_ptr<Marshallable> cmd, shared_ptr<IntEvent> recovery_event) {
  if (!cmd) {
    return;
  }

  std::shared_ptr<TpcBatchCommand> batch_cmd_override = nullptr;
  int completion_weight = 1;
  shared_ptr<Marshallable> inner_cmd = cmd;

  if (cmd->kind_ == MarshallDeputy::CMD_TPC_BATCH) {
    batch_cmd_override = std::dynamic_pointer_cast<TpcBatchCommand>(cmd);
    if (!batch_cmd_override || batch_cmd_override->Size() == 0) {
      Log_error("[JETPACK-RECOVERY] Empty TpcBatchCommand during dispatch");
      return;
    }
    auto first_cmd = batch_cmd_override->cmds_.front();
    if (!first_cmd || !first_cmd->cmd_) {
      Log_error("[JETPACK-RECOVERY] Batch command missing inner command");
      return;
    }
    inner_cmd = first_cmd->cmd_;
    completion_weight = static_cast<int>(batch_cmd_override->Size());
    for (auto& single_cmd : batch_cmd_override->cmds_) {
      if (!single_cmd || !single_cmd->cmd_) {
        continue;
      }
      auto single_vec = dynamic_pointer_cast<VecPieceData>(single_cmd->cmd_);
      if (single_vec) {
        single_vec->is_recovery_command_ = true;
      }
    }
  } else if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT) {
    auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
    if (tpc_cmd && tpc_cmd->cmd_) {
      inner_cmd = tpc_cmd->cmd_;
    }
  }

  const char* sched_type = "UNKNOWN";
  if (rep_sched_ && this == rep_sched_) {
    sched_type = "REP_SCHED";
  } else if (!rep_sched_ || rep_sched_ != this) {
    sched_type = "TX_SCHED";
  }

#ifdef JETPACK_RECOVERY_DEBUG
  Log_info("[JETPACK-RECOVERY] Dispatching recovered command, kind=%d batch=%s size=%d",
           cmd->kind_,
           batch_cmd_override ? "YES" : "NO",
           batch_cmd_override ? batch_cmd_override->Size() : 1);
#endif

  if (inner_cmd->kind_ == MarshallDeputy::CMD_VEC_PIECE) {
    auto vec_piece_data = dynamic_pointer_cast<VecPieceData>(inner_cmd);
    if (vec_piece_data && vec_piece_data->sp_vec_piece_data_) {
      vec_piece_data->is_recovery_command_ = true;

      auto par_id = vec_piece_data->sp_vec_piece_data_->at(0)->PartitionId();
      auto cmd_id = vec_piece_data->sp_vec_piece_data_->at(0)->root_id_;

      auto comm = commo();

      auto coo = std::make_unique<CoordinatorClassic>(999999,
                                                       Config::GetConfig()->benchmark_,
                                                       nullptr,
                                                       0);
      coo->loc_id_ = site_id_;
      coo->par_id_ = partition_id_;

      auto callback = [this, par_id, recovery_event, cmd_id, completion_weight](int res, TxnOutput& output) {
#ifdef JETPACK_RECOVERY_DEBUG
        Log_info("[JETPACK-RECOVERY] Dispatch callback received, res=%d (target=%d current=%d weight=%d)",
                 res,
                 recovery_event ? recovery_event->target_ : -1,
                 recovery_event ? recovery_event->value_ : -1,
                 completion_weight);
#endif
        if (res == WRONG_LEADER) {
#ifdef JETPACK_WRONG_LEADER_DEBUG
          Log_error("[JETPACK-RECOVERY] Received WRONG_LEADER during recovery dispatch for partition %d.", par_id);
#endif
        } else if (res == REJECT) {
          Log_info("[JETPACK-RECOVERY] Command rejected during recovery dispatch (expected if tx already processed)");
        } else if (res != SUCCESS) {
          Log_warn("[JETPACK-RECOVERY] Dispatch failed with result: %d", res);
        }

        if (recovery_event) {
          int old_value = recovery_event->value_;
          recovery_event->Set(old_value + completion_weight);
          if (recovery_event->value_ % 100 == 0 || recovery_event->IsReady()) {
            Log_info("[JETPACK-RECOVERY-EVENT] After increment: new value=%d, target=%d. Event ready=%s",
                     recovery_event->value_,
                     recovery_event->target_,
                     recovery_event->IsReady() ? "YES" : "NO");
          }
        }
      };

      if (batch_cmd_override) {
        comm->BroadcastDispatch(nullptr, coo.get(), callback, batch_cmd_override);
      } else {
        comm->BroadcastDispatch(vec_piece_data->sp_vec_piece_data_, coo.get(), callback);
      }
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-RECOVERY] Command dispatched through communicator to leader");
#endif
    } else {
      Log_error("[JETPACK-RECOVERY] DispatchRecoveredCommand failed: inner command kind=%d (expected VecPieceData)", inner_cmd->kind_);
    }
  } else {
    Log_error("[JETPACK-RECOVERY] DispatchRecoveredCommand unsupported command kind=%d", inner_cmd->kind_);
  }
}

void TxLogServer::OnJetpackPullRecovery(const MarshallDeputy& old_view,
                                        const MarshallDeputy& new_view,
                                        const epoch_t& jepoch,
                                        const epoch_t& oepoch,
                                        bool_t* ok,
                                        epoch_t* reply_jepoch,
                                        epoch_t* reply_oepoch,
                                        MarshallDeputy* reply_old_view,
                                        MarshallDeputy* reply_new_view,
                                        shared_ptr<KeyCmdIdBatchData>& batch) {
  if (!reply_old_view || !reply_new_view || !batch) {
    if (ok) {
      *ok = 0;
    }
    return;
  }

  OnJetpackBeginRecovery(old_view, new_view, oepoch);
  reply_old_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->old_view_));
  reply_new_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->new_view_));

  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_) {
    rep_sched_->jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;
    *ok = 1;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    Log_info("[JETPACK-RECOVERY] PullRecovery command pool candidates size=%zu pool_size=%d",
             rep_sched_->command_pool_.candidates_.size(), rep_sched_->command_pool_.size());
    for (const auto& kv : rep_sched_->command_pool_.candidates_) {
      key_t key = kv.first;
      if (rep_sched_->command_pool_.has_cmd_to_recover(key)) {
        auto cmd = rep_sched_->command_pool_.cmd_to_recover(key);
        if (cmd) {
          uint64_t cmd_id = SimpleRWCommand::GetCombinedCmdID(cmd);
          batch->AddEntry(key, cmd_id);
        }
      }
    }
  } else {
    *ok = 0;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
  }
}

void TxLogServer::OnJetpackBeginRecovery(const MarshallDeputy& old_view,
                                         const MarshallDeputy& new_view, 
                                         const epoch_t& new_view_id) {
  rep_sched_->jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;
  rep_sched_->oepoch_ = new_view_id;
  auto config = Config::GetConfig();
  
  // Extract ViewData from MarshallDeputy parameters
  auto sp_old_view_data = dynamic_pointer_cast<ViewData>(old_view.sp_data_);
  auto sp_new_view_data = dynamic_pointer_cast<ViewData>(new_view.sp_data_);
  
  // Update the views if extraction was successful
  if (sp_old_view_data) {
    rep_sched_->old_view_ = sp_old_view_data->GetView();
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Updated old_view from MarshallDeputy");
#endif
  } else {
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Warning: Could not extract old_view from MarshallDeputy");
#endif
  }
  
  if (sp_new_view_data) {
    const View& incoming_view = sp_new_view_data->GetView();
    Log_info("[VIEW_DEBUG] OnJetpackBeginRecovery partition %d view transition %s -> %s",
             partition_id_, rep_sched_->new_view_.ToString().c_str(), incoming_view.ToString().c_str());
    rep_sched_->new_view_ = incoming_view;
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Updated new_view from MarshallDeputy");
#endif
    
    // Update the communicator's view immediately
    if (commo_) {
      auto my_comm = commo();
      Log_info("[JETPACK-RECOVERY] This TxLogServer %p has communicator %p (loc_id=%d)", 
               this, my_comm, my_comm ? my_comm->loc_id_ : -1);
      if (my_comm) {
        my_comm->UpdatePartitionView(partition_id_, sp_new_view_data);
      }
    }
    
    // // Also update rep_sched's communicator if different
    // if (rep_sched_ && rep_sched_ != this && rep_sched_->commo_) {
    //   auto rep_comm = rep_sched_->commo();
    //   Log_info("[JETPACK-RECOVERY] Also updating rep_sched %p communicator %p (loc_id=%d)", 
    //            rep_sched_, rep_comm, rep_comm ? rep_comm->loc_id_ : -1);
    //   if (rep_comm) {
    //     rep_comm->UpdatePartitionView(partition_id_, sp_new_view_data);
    //   }
    // }
    
    Log_info("[JETPACK-RECOVERY] Updated communicator view(s) for partition %d during BeginRecovery: %s", 
             partition_id_, sp_new_view_data->GetView().ToString().c_str());
    
    // Log leader information from the new view
    if (!sp_new_view_data->GetView().leaders_.empty()) {
      int new_leader = sp_new_view_data->GetView().GetLeader();
      bool should_be_leader = (new_leader == site_id_);
      Log_info("[JETPACK-VIEW-UPDATE] New view leader is %d, this server is %d, should_be_leader=%d", 
               new_leader, site_id_, should_be_leader);
      
      // Demote immediately if the recovery view picked a different leader
      if ((config->replica_proto_ == MODE_RAFT || config->replica_proto_ == MODE_FPGA_RAFT) && rep_sched_) {
        if (auto* raft_server = dynamic_cast<RaftServer*>(rep_sched_)) {
          if (new_leader != raft_server->site_id_ && raft_server->IsLeader()) {
            Log_info("[JETPACK-VIEW-UPDATE] Stepping down due to BeginRecovery view update; new leader=%d", new_leader);
            raft_server->setIsLeader(false);
          }
        }
      }
    } else {
      Log_info("[JETPACK-VIEW-UPDATE] WARNING: New view has no leaders in the new view");
    }
  } else {
#ifdef JETPACK_RECOVERY_DEBUG
    Log_info("[JETPACK-RECOVERY] Warning: Could not extract new_view from MarshallDeputy");
#endif
  }
}

void TxLogServer::OnJetpackPullIdSet(const epoch_t& jepoch,
                                     const epoch_t& oepoch,
                                     bool_t* ok,
                                     epoch_t* reply_jepoch,
                                     epoch_t* reply_oepoch,
                                     MarshallDeputy* reply_old_view,
                                     MarshallDeputy* reply_new_view,
                                     shared_ptr<VecRecData> id_set) {
  
  
  // Debug print command pool candidates
#ifdef JETPACK_RECOVERY_DEBUG
  if (rep_sched_) {

    Log_info("[JETPACK-DEBUG] Command pool candidates size: %zu", rep_sched_->command_pool_.candidates_.size());
    
    // Print all keys in command pool candidates
    std::stringstream pool_keys;
    int count = 0;
    for (const auto& kv : rep_sched_->command_pool_.candidates_) {
      if (count++ < 20) {
        pool_keys << kv.first << "(" << kv.second.size() << " cmds) ";
      }
    }
    if (rep_sched_->command_pool_.candidates_.size() > 20) {
      pool_keys << "... (and " << (rep_sched_->command_pool_.candidates_.size() - 20) << " more)";
    }
    Log_info("[JETPACK-DEBUG] Command pool candidate keys: %s", pool_keys.str().c_str());

  }
#endif
  
  // Initialize MarshallDeputy objects with ViewData objects
  reply_old_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->old_view_));
  reply_new_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->new_view_));
  
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_) {
    rep_sched_->jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;
    *ok = 1;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    // Copy data from command pool id_set to the response parameter
    auto pool_id_set = rep_sched_->command_pool_.id_set();
    id_set->key_data_ = pool_id_set->key_data_;
    
  } else {
    *ok = 0;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    // Initialize empty key_data_ for failed case
    id_set->key_data_ = std::make_shared<vector<key_t>>();
  }
}

void TxLogServer::OnJetpackPullCmd(const epoch_t& jepoch,
                                   const epoch_t& oepoch,
                                   const std::vector<key_t>& keys,
                                   bool_t* ok, 
                                   epoch_t* reply_jepoch, 
                                   epoch_t* reply_oepoch,
                                   MarshallDeputy* reply_old_view,
                                   MarshallDeputy* reply_new_view,
                                   shared_ptr<KeyCmdBatchData>& batch) {
  
  if (!rep_sched_ || !batch) {
    return;
  }
  
  if (!reply_old_view || !reply_new_view) {
    return;
  }
  
  reply_old_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->old_view_));
  reply_new_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->new_view_));
  
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_) {
    rep_sched_->jetpack_status_ = TxLogServer::JetpackStatus::RECOVERY;
    *ok = 1;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    
    for (const auto& key : keys) {
#ifdef JETPACK_RECOVERY_DEBUG
      Log_info("[JETPACK-SCHED-DEBUG] Processing batched key %d for PullCmd", key);
#endif
      auto& candidates = rep_sched_->command_pool_.candidates_;
      if (candidates.find(key) == candidates.end()) {
        continue;
      }
      if (rep_sched_->command_pool_.has_cmd_to_recover(key)) {
        auto cmd = rep_sched_->command_pool_.cmd_to_recover(key);
        if (cmd) {
          batch->AddEntry(key, cmd);
        }
      }
    }
  } else {
    *ok = 0;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
  }
  
}

void TxLogServer::OnJetpackRecordCmd(const epoch_t& jepoch, 
                                     const epoch_t& oepoch, 
                                     const int32_t& sid, 
                                     shared_ptr<KeyCmdIdBatchData>& record_batch,
                                     shared_ptr<KeyCmdIdBatchData>& missing_batch,
                                     shared_ptr<KeyCmdBatchData>& cmd_batch) {
  if (!rep_sched_) {
    return;
  }
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_) {
    // Record incoming key-id set
    if (record_batch) {
      std::vector<std::pair<key_t, uint64_t>> ids;
      ids.reserve(record_batch->Size());
      for (size_t idx = 0; idx < record_batch->Size(); idx++) {
        ids.emplace_back(record_batch->GetKey(idx), record_batch->GetCmdId(idx));
      }
      rep_sched_->rec_set_.set_rec_set(sid, ids);
    }
    if (missing_batch && cmd_batch) {
      for (size_t idx = 0; idx < missing_batch->Size(); idx++) {
        key_t key = missing_batch->GetKey(idx);
        uint64_t cmd_id = missing_batch->GetCmdId(idx);
        auto& candidates = rep_sched_->command_pool_.candidates_;
        auto it = candidates.find(key);
        if (it != candidates.end()) {
          auto cmd = it->second.get_cmd(cmd_id);
          if (cmd) {
            cmd_batch->AddEntry(key, cmd);
          }
        }
      }
    }
  }
}

void TxLogServer::OnJetpackPrepare(const epoch_t& jepoch, 
                                   const epoch_t& oepoch, 
                                   const ballot_t& max_seen_ballot, 
                                   bool_t* ok, 
                                   epoch_t* reply_jepoch,
                                   epoch_t* reply_oepoch,
                                   MarshallDeputy* reply_old_view,
                                   MarshallDeputy* reply_new_view,
                                   ballot_t* reply_max_seen_ballot,
                                   ballot_t* accepted_ballot, 
                                   int32_t* replied_sid) {
  // Initialize MarshallDeputy objects with ViewData objects
  reply_old_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->old_view_));
  reply_new_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->new_view_));
  
  if (max_seen_ballot > rep_sched_->command_pool_.max_seen_ballot_) {
    rep_sched_->command_pool_.max_seen_ballot_ = max_seen_ballot;
  }
  *reply_max_seen_ballot = rep_sched_->command_pool_.max_seen_ballot_;
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_ && max_seen_ballot >= rep_sched_->command_pool_.max_seen_ballot_) {
    *ok = 1;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    *accepted_ballot = rep_sched_->command_pool_.max_accepted_ballot_;
    *replied_sid = rep_sched_->command_pool_.sid_;
  } else {
    *ok = 0;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
  }
}

void TxLogServer::OnJetpackAccept(const epoch_t& jepoch, 
                                  const epoch_t& oepoch, 
                                  const ballot_t& max_seen_ballot, 
                                  const int32_t& sid, 
                                  bool_t* ok,
                                  epoch_t* reply_jepoch,
                                  epoch_t* reply_oepoch,
                                  MarshallDeputy* reply_old_view,
                                  MarshallDeputy* reply_new_view,
                                  ballot_t* reply_max_seen_ballot) {
  // Initialize MarshallDeputy objects with ViewData objects
  reply_old_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->old_view_));
  reply_new_view->SetMarshallable(std::make_shared<ViewData>(rep_sched_->new_view_));
  
  if (max_seen_ballot > rep_sched_->command_pool_.max_seen_ballot_) {
    rep_sched_->command_pool_.max_seen_ballot_ = max_seen_ballot;
  }
  *reply_max_seen_ballot = rep_sched_->command_pool_.max_seen_ballot_;
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_ && max_seen_ballot >= rep_sched_->command_pool_.max_seen_ballot_) {
    *ok = 1;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
    rep_sched_->command_pool_.max_accepted_ballot_ = max_seen_ballot;
    rep_sched_->command_pool_.sid_ = sid;
  } else {
    *ok = 0;
    *reply_jepoch = rep_sched_->jepoch_;
    *reply_oepoch = rep_sched_->oepoch_;
  }
}

void TxLogServer::OnJetpackCommit(const epoch_t& jepoch, 
                                  const epoch_t& oepoch, 
                                  const int32_t& sid) {
  if (jepoch >= rep_sched_->jepoch_ && oepoch >= rep_sched_->oepoch_) {
    rep_sched_->command_pool_.sid_ = sid;
    rep_sched_->command_pool_.committed_ = true;
  }
}

void TxLogServer::OnJetpackFinishRecovery(const epoch_t& oepoch) {
  if (oepoch >= rep_sched_->oepoch_) {
    rep_sched_->jepoch_ = oepoch;
    rep_sched_->oepoch_ = oepoch;
    rep_sched_->command_pool_.reset();
    rep_sched_->jetpack_status_ = TxLogServer::JetpackStatus::READY;
  }
  // Finally, broadcast FinishRecovery to update jepoch and make fast path available
#if defined(JETPACK_MONGODB_RECOVERY) || defined(JETPACK_ETCD_RECOVERY) || defined(JETPACK_ZOOKEEPER_RECOVERY)
  Log_info("Mark FinishRecovery on %s", "recovery_finish");
  jm_signal::set_key("jetpack", "recovery_finish", "recovery_finish");
  Log_info("[JETPACK-RECOVERY] Wrote finish signal to JM_Jetpack_%s", "recovery_finish");
  if (jm_signal::exists_key("failure", "failure_triggered", "failure_triggered")) {
    jm_signal::set_key("jetpack", "recovery_finish_after_failure", "recovery_finish_after_failure");
    Log_info("[JETPACK-RECOVERY] Wrote post-failure finish signal to JM_Jetpack_%s",
              "recovery_finish_after_failure");
  }
#endif
}

} // namespace janus
