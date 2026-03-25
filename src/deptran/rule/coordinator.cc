#include "coordinator.h"
#include "frame.h"
#include "benchmark_control_rpc.h"
#include "../RW_command.h"
#include "../../rrr/misc/rand.hpp"
#include "commo.h"

namespace janus {

// This Coordinator should be on Client Side

CoordinatorRule::CoordinatorRule(uint32_t coo_id,
                                       int32_t benchmark,
                                       ClientControlServiceImpl *ccsi,
                                       uint32_t thread_id)
  : CoordinatorClassic(coo_id, benchmark, ccsi, thread_id) {
  // if (Config::GetConfig()->replica_proto_ == MODE_FPGA_RAFT) {
  //   margin_success_rate_ = 0.724;
  // } else if (Config::GetConfig()->replica_proto_ == MODE_COPILOT) {
  //   margin_success_rate_ = 0.713;
  // } else if (Config::GetConfig()->replica_proto_ == MODE_MENCIUS) {
  //   margin_success_rate_ = 0.930;
  // } else {
  //   verify(0);
  // }
}

// CommunicatorRule* CoordinatorRule::commo() {
//   if (commo_ == nullptr) {
//     commo_ = new CommunicatorRule;
//   }
//   verify(commo_ != nullptr);
//   return commo_;
// }

void CoordinatorRule::GotoNextPhase() {
  int n_phase = 3;
  int current_phase = phase_ % n_phase;
  int phase_cp;
  auto txn = static_cast<TxData*>(cmd_);
#ifdef JETPACK_WRONG_LEADER_DEBUG
  Log_info("[WRONG_LEADER_FLOW] CoordinatorRule entering GotoNextPhase raw_phase=%d current_phase=%d res=%d aborted=%d fast_path_success_=%d dispatch_ack_=%d dispatch_since_birth=%.2fms",
           phase_, current_phase,
           txn ? txn->reply_.res_ : 0,
           aborted_,
           fast_path_success_,
           dispatch_ack_,
           dispatch_time_ - clientworker_creation_time_);
#endif
  bool latency_window = dispatch_duration_3_times_ > Config::GetConfig()->duration_ * 1000 &&
                              dispatch_duration_3_times_ < Config::GetConfig()->duration_ * 2 * 1000;
  bool skip_latency = latency_window && (txn->reply_.res_ == WRONG_LEADER || aborted_);
  switch (phase_++ % n_phase) {
    case Phase::INIT_END:
      dispatch_time_ = SimpleRWCommand::GetCurrentMsTime();
      dispatch_duration_3_times_ = (dispatch_time_ - clientworker_creation_time_) * 3;
      client_worker_->dispatch_time_distribution_.append(dispatch_time_ - clientworker_creation_time_);
      phase_cp = phase_;
      verify(phase_ % n_phase == Phase::DISPATCHED);
      fast_path_success_ = false;
      dispatch_ack_ = false;

      // [Ze] Get cmds_by_par_ and sp_vec_piece_by_par_ in advance here since both original path and fastpath need this
      cmds_by_par_ = ((TxData*) cmd_)->GetReadyPiecesData(100); // TODO setting n_pd larger than 1 will cause 2pl to wait forever
      for (auto& pair: cmds_by_par_) {
        auto& cmds = pair.second;
        if (cmds.size() > 0)
          cmd_is_write_ = SimpleRWCommand(cmds[0]).IsWrite();
      }

      if (0 <= Config::GetConfig()->jetpack_fastpath_attempt_rate_ && Config::GetConfig()->jetpack_fastpath_attempt_rate_ <= 100) {
        // fixed percentage
        go_to_fastpath_ = RandomGenerator::rand(0, 99) < Config::GetConfig()->jetpack_fastpath_attempt_rate_;
      } else if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ == 101) {
        go_to_fastpath_ = client_worker_->go_to_jetpack_fastpath_cnt_ < 10
                          || (client_worker_->cli2cli_[6+cmd_is_write_].count() > 0 && client_worker_->cli2cli_[6+cmd_is_write_].recent_100_ave() < std::min(client_worker_->cli2cli_[8+cmd_is_write_].recent_100_ave(), 500.0))
                          || client_worker_->one_armed_bandit_.ConsultAttempt();
        if (Config::GetConfig()->replica_proto_ == MODE_MENCIUS) {
          double avg_all = client_worker_->cpu_usage_all_.recent_100_ave();
          double avg_leaders = client_worker_->cpu_usage_leaders_.recent_100_ave();
          static double max_leader_avg = 0.0;
          if (avg_leaders > max_leader_avg) {
            max_leader_avg = avg_leaders;
          }
          double rand_val = RandomGenerator::rand(0, 30);
          bool cpu_disabled = (max_leader_avg - 60.0 > rand_val);
          if (cpu_disabled) {
            go_to_fastpath_ = false;
          }
          // Log controller state periodically (every 500 txns) to avoid
          // flooding .res files while still capturing decision evidence.
          static int mencius_log_counter = 0;
          if (++mencius_log_counter % 500 == 1) {
            Log_info("[CPU-MENC] avg_all=%.2f avg_leaders=%.2f max_leader=%.2f "
                     "threshold=%.2f rand=%.2f cpu_disabled=%d go_fp=%d "
                     "fp_cnt=%d",
                     avg_all, avg_leaders, max_leader_avg,
                     max_leader_avg - 60.0, rand_val,
                     cpu_disabled, go_to_fastpath_,
                     client_worker_->go_to_jetpack_fastpath_cnt_);
          }
        }
      } else {
        verify(0);
      }

      // Throttle fast-path at high queue depth for MongoDB/Etcd/ZK/Copilot.
      // At low queue depth (<50): fast-path freely for latency benefit.
      // At high queue depth (>50): ramp down fast-path to avoid overhead from
      // failed speculative RPCs which hurt peak throughput at high concurrency.
      if (Config::GetConfig()->replica_proto_ == MODE_MONGODB ||
          Config::GetConfig()->replica_proto_ == MODE_ETCD ||
          Config::GetConfig()->replica_proto_ == MODE_ZOOKEEPER) {
        double queue_depth = client_worker_->queue_depth_.recent_100_ave();
        if (queue_depth > 50) {
          double rand_val = RandomGenerator::rand(0, 99);
          double throttle = (queue_depth - 50) * 0.5; // ramp: 50% at 150, 100% at 250+
          if (throttle > rand_val) {
            go_to_fastpath_ = false;
          }
        }
      } else if (Config::GetConfig()->replica_proto_ == MODE_COPILOT) {
        double queue_depth = client_worker_->queue_depth_.recent_100_ave();
        double rand_val = RandomGenerator::rand(0, 99);
        if (queue_depth - 300 > rand_val) {
          go_to_fastpath_ = false;
        }
      }

      client_worker_->go_to_jetpack_fastpath_cnt_ += go_to_fastpath_;

      sp_vec_piece_by_par_.clear();
      for (auto& pair: cmds_by_par_) {
        const parid_t& par_id = pair.first;
        auto& cmds = pair.second;
        n_dispatch_ += cmds.size();
        auto sp_vec_piece = std::make_shared<vector<shared_ptr<TxPieceData>>>();
        for (auto c: cmds) {
          c->id_ = next_pie_id();
          c->rule_mode_on_and_is_original_path_only_command_ = !go_to_fastpath_;
          dispatch_acks_[c->inn_id_] = false;
          sp_vec_piece->push_back(c);
          client_worker_->frequency_.append(SimpleRWCommand::GetKey(c));
        }
        sp_vec_piece_by_par_[par_id] = sp_vec_piece;
      }

      DispatchAsync(go_to_fastpath_ || Config::GetConfig()->replica_proto_ == MODE_COPILOT); // Copilot fast path or not both need to send to pilot and copilot

      if (go_to_fastpath_) {
        BroadcastRuleSpeculativeExecute(phase_cp);
      } else {
        // Do nothing
      }
      break;
    case Phase::DISPATCHED:
      // if (go_to_fastpath_) {
      //   if (fast_path_success_)
      //     recent_fastpath_success_.append(1);
      //   else
      //     recent_fastpath_success_.append(0);
      // }
      if (aborted_) {
#ifdef JETPACK_WRONG_LEADER_DEBUG
          Log_info("[WRONG_LEADER_FLOW] CoordinatorRule skipping commit_time for tx_id=%lu res=%d aborted=%d phase=%d (DISPATCHED) dispatch_since_birth=%.2fms",
                   txn->id_, txn->reply_.res_, aborted_, current_phase,
                   dispatch_time_ - clientworker_creation_time_);
#endif
        End();
      }
      if (fast_path_success_ || dispatch_ack_) {
        committed_ = true;
        // verify(phase_ % n_phase == Phase::WAITING_ORIGIN);
        phase_++;
        verify(phase_ % n_phase == Phase::INIT_END);
        // Log_info("CoordinatorRule coo_id=%d thread_id=%d cmd_ver_=%d current_phase=%d [before dispatch end] fast_path_success_=%d dispatch_ack_=%d", coo_id_, thread_id_, cmd_ver_, current_phase, fast_path_success_, dispatch_ack_);
        client_worker_->one_armed_bandit_.Record(fast_path_success_); // record succee only when efficient fast path success
        // if (skip_latency) {
        //   Log_info("[CLIENT-LATENCY] Skip cli2cli logging due to %s (res=%d, aborted=%d)",
        //            txn->reply_.res_ == WRONG_LEADER ? "WRONG_LEADER" : "ABORTED",
        //            txn->reply_.res_, aborted_);
        // }
        if (latency_window && !skip_latency) {
          // verify(!(fast_path_success_ && dispatch_ack_));
          if (fast_path_success_) {
            client_worker_->cli2cli_[2].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
          }
          else {
            client_worker_->cli2cli_[4].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
          }
          client_worker_->cli2cli_[5].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        }
        if (!fast_path_success_ && !skip_latency)
          client_worker_->cli2cli_[8+cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
#ifdef JETPACK_WRONG_LEADER_DEBUG
        Log_info("[WRONG_LEADER_FLOW] CoordinatorRule recording commit_time for tx_id=%lu phase=%d (DISPATCHED) dispatch_since_birth=%.2fms",
                  txn->id_, current_phase,
                  dispatch_time_ - clientworker_creation_time_);
#endif
        client_worker_->commit_time_.push_back(
          std::make_pair(dispatch_time_,
                          SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
        End();
      } else {
        verify(phase_ % n_phase == Phase::WAITING_ORIGIN);
        client_worker_->one_armed_bandit_.RecordFail(); // record fail since fast path fail
        // Log_info("CoordinatorRule coo_id=%d thread_id=%d cmd_ver_=%d current_phase=%d [before into WAITING_ORIGIN] fast_path_success_=%d dispatch_ack_=%d", coo_id_, thread_id_, cmd_ver_, current_phase, fast_path_success_, dispatch_ack_);
      }
      break;
    case Phase::WAITING_ORIGIN:
      committed_ = true;
      verify(phase_ % n_phase == Phase::INIT_END);
      // Log_info("CoordinatorRule coo_id=%d thread_id=%d cmd_ver_=%d current_phase=%d [before WAITING_ORIGIN end]", coo_id_, thread_id_, cmd_ver_, current_phase);
      // if (skip_latency) {
      //   Log_info("[CLIENT-LATENCY] Skip cli2cli logging due to %s (res=%d, aborted=%d)",
      //            txn->reply_.res_ == WRONG_LEADER ? "WRONG_LEADER" : "ABORTED",
      //            txn->reply_.res_, aborted_);
      // }
      if (latency_window && !skip_latency) {
        client_worker_->cli2cli_[4].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        client_worker_->cli2cli_[5].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
      }
      if (!skip_latency) {
        client_worker_->cli2cli_[8+cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
      }
#ifdef JETPACK_WRONG_LEADER_DEBUG
      if (txn->reply_.res_ == WRONG_LEADER || aborted_) {
        Log_info("[WRONG_LEADER_FLOW] CoordinatorRule skipping commit_time for tx_id=%lu res=%d aborted=%d phase=%d (WAITING_ORIGIN) dispatch_since_birth=%.2fms",
                 txn->id_, txn->reply_.res_, aborted_, current_phase,
                 dispatch_time_ - clientworker_creation_time_);
      } else {
        Log_info("[WRONG_LEADER_FLOW] CoordinatorRule recording commit_time for tx_id=%lu phase=%d (WAITING_ORIGIN) dispatch_since_birth=%.2fms",
                 txn->id_, current_phase,
                 dispatch_time_ - clientworker_creation_time_);
      }
#endif
      if (!(txn->reply_.res_ == WRONG_LEADER || aborted_))
        client_worker_->commit_time_.push_back(std::make_pair(dispatch_time_, SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
      // Log_info("End");
      End();
      break;
    default:
      verify(0);
  }
}

void CoordinatorRule::BroadcastRuleSpeculativeExecute(int phase) {
  auto txn = (TxData*) cmd_;
  auto n_pd = Config::GetConfig()->n_parallel_dispatch_;
  n_pd = 100;
  // auto cmds_by_par = txn->GetReadyPiecesData(n_pd); // TODO setting n_pd larger than 1 will cause 2pl to wait forever
  auto cmds_by_par = cmds_by_par_;
  Log_debug("Dispatch for tx_id: %" PRIx64, txn->root_id_);
  // [Jetpack] TODO: only support partition = 1 now
  verify(cmds_by_par.size() == 1);
  shared_ptr<RuleSpeculativeExecuteQuorumEvent> e;
  for (auto& pair: cmds_by_par) {
    const parid_t& par_id = pair.first;
    auto& cmds = pair.second;
    // n_dispatch_ += cmds.size();
    auto sp_vec_piece = sp_vec_piece_by_par_[par_id];
    // for (auto c: cmds) {
    //   c->id_ = next_pie_id();
    //   dispatch_acks_[c->inn_id_] = false;
    //   sp_vec_piece->push_back(c);
    // }
    verify(sp_vec_piece->size() == 1); // for Jetpack setting
    cmdid_t cmd_id = sp_vec_piece->at(0)->root_id_;
    verify(sp_vec_piece->size() > 0);
    verify(par_id == sp_vec_piece->at(0)->PartitionId());
    shared_ptr<VecPieceData> sp_vpd(new VecPieceData);
    sp_vpd->sp_vec_piece_data_ = sp_vec_piece;
    sp_vpd_ = sp_vpd;
#ifdef MONGODB_DEBUG
    Log_info("%.2f BroadcastRuleSpeculativeExecute <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(sp_vpd_).first, SimpleRWCommand::GetCmdID(sp_vpd_).second);
#endif
    e = ((CommunicatorRule *)commo())->BroadcastRuleSpeculativeExecute(sp_vec_piece);
    // e = commo()->BroadcastRuleSpeculativeExecute(sp_vec_piece);
  }
  e->Wait();
  // Log_info("[CPU] AvgCpuAll=%.2f AvgCpuLeaders=%.2f", e->AvgCpuAll(), e->AvgCpuLeaders());
  if (client_worker_) {
    client_worker_->cpu_usage_all_.append(e->AvgCpuAll());
    client_worker_->cpu_usage_leaders_.append(e->AvgCpuLeaders());
    double leader_queue_depth = e->LeaderQueueDepth();
    if (leader_queue_depth >= 0.0) {
      client_worker_->queue_depth_.append(leader_queue_depth);
    }
  }
#ifdef MONGODB_DEBUG
  Log_info("%.2f BroadcastRuleSpeculativeExecute after wait <%d, %d>", SimpleRWCommand::GetMsTimeElaps(), SimpleRWCommand::GetCmdID(sp_vpd_).first, SimpleRWCommand::GetCmdID(sp_vpd_).second);
#endif
  bool latency_window = dispatch_duration_3_times_ > Config::GetConfig()->duration_ * 1000 &&
                        dispatch_duration_3_times_ < Config::GetConfig()->duration_ * 2 * 1000;
  bool skip_latency = latency_window && (txn->reply_.res_ == WRONG_LEADER || aborted_);
  // if (skip_latency) {
  //   Log_info("[CLIENT-LATENCY] Skip cli2cli logging due to %s (res=%d, aborted=%d)",
  //            txn->reply_.res_ == WRONG_LEADER ? "WRONG_LEADER" : "ABORTED",
  //            txn->reply_.res_, aborted_);
  // }
  if (latency_window && !skip_latency) {
    client_worker_->cli2cli_[0].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
  }
  if (e->Yes()) {
    fast_path_success_ = true;
    if (latency_window && !skip_latency)
      client_worker_->cli2cli_[1].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
    if (!skip_latency) {
      client_worker_->cli2cli_[6+cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
    }
  } else if (e->No() || e->timeouted_) {
    fast_path_success_ = false;
  } else {
    verify(0);
  }
  result_ = e->GetResult();
  // fast_path_success_ = false;
  if (phase != phase_) return;
  if (fast_path_success_)
    GotoNextPhase();
}

void CoordinatorRule::DispatchAsync(bool fastpath_broadcast_mode) {
  Log_debug("commo Broadcast to the server on client worker");
  std::lock_guard<std::recursive_mutex> lock(mtx_);
  auto txn = (TxData*) cmd_;

  auto n_pd = Config::GetConfig()->n_parallel_dispatch_;
  n_pd = 100;
  // ReadyPiecesData cmds_by_par;
  // cmds_by_par = txn->GetReadyPiecesData(n_pd); // TODO setting n_pd larger than 1 will cause 2pl to wait forever
  // cmds_by_par_ = cmds_by_par;
  auto cmds_by_par = cmds_by_par_;
  Log_debug("Dispatch for tx_id: %" PRIx64, txn->root_id_);
  for (auto& pair: cmds_by_par) {
    const parid_t& par_id = pair.first;
    auto sp_vec_piece = sp_vec_piece_by_par_[par_id];
    ((CommunicatorRule *)commo())->BroadcastDispatch(fastpath_broadcast_mode,
                                                      sp_vec_piece,
                                                      this,
                                                      std::bind(&CoordinatorClassic::DispatchAck,
                                                                this,
                                                                phase_,
                                                                dispatch_time_,
                                                                std::placeholders::_1,
                                                                std::placeholders::_2));
  }
}

} // namespace janus
