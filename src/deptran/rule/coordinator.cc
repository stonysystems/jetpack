#include "coordinator.h"
#include "frame.h"
#include "benchmark_control_rpc.h"
#include "../RW_command.h"
#include "../../rrr/misc/rand.hpp"
#include "commo.h"

#ifdef JETPACK_PROF
#include <atomic>
#include <chrono>
#endif

namespace janus {

#ifdef JETPACK_PROF
// Per-phase wall-time accounting for CoordinatorRule. Static file-scope
// atomics aggregate across all client threads on this process. Sub-phase
// counters break down INIT_END so we can attribute the 285 ms gap to
// GetReadyPiecesData / cmds_by_par_ loop / dispatch path. Dumped from
// s_main.cc::client_shutdown() via JetpackProfRule_Dump().
static std::atomic<uint64_t> g_rule_init_end_calls_{0};
static std::atomic<uint64_t> g_rule_init_end_ns_{0};
static std::atomic<uint64_t> g_rule_init_end_get_ready_ns_{0};
static std::atomic<uint64_t> g_rule_init_end_bookkeep_ns_{0};   // cmds_by_par_ loop, dispatch_acks_ map, frequency_.append
static std::atomic<uint64_t> g_rule_init_end_dispatch_ns_{0};   // DispatchAsync + BroadcastRuleSpeculativeExecute
static std::atomic<uint64_t> g_rule_dispatched_calls_{0};
static std::atomic<uint64_t> g_rule_dispatched_ns_{0};
static std::atomic<uint64_t> g_rule_waiting_origin_calls_{0};
static std::atomic<uint64_t> g_rule_waiting_origin_ns_{0};

void JetpackProfRule_Dump() {
  uint64_t ie_n = g_rule_init_end_calls_.load();
  uint64_t ie_ns = g_rule_init_end_ns_.load();
  uint64_t ie_gr_ns = g_rule_init_end_get_ready_ns_.load();
  uint64_t ie_bk_ns = g_rule_init_end_bookkeep_ns_.load();
  uint64_t ie_dp_ns = g_rule_init_end_dispatch_ns_.load();
  uint64_t d_n = g_rule_dispatched_calls_.load();
  uint64_t d_ns = g_rule_dispatched_ns_.load();
  uint64_t w_n = g_rule_waiting_origin_calls_.load();
  uint64_t w_ns = g_rule_waiting_origin_ns_.load();
  auto avg_us = [](uint64_t n, uint64_t ns) {
    return n ? (double)ns / n / 1000.0 : 0.0;
  };
  Log_info("[PROF-COORD-RULE] init_end_calls=%lu init_end_avg_us=%.2f init_end_total_ms=%.2f | "
           "init_end_get_ready_total_ms=%.2f init_end_bookkeep_total_ms=%.2f init_end_dispatch_total_ms=%.2f | "
           "dispatched_calls=%lu dispatched_avg_us=%.2f dispatched_total_ms=%.2f | "
           "waiting_origin_calls=%lu waiting_origin_avg_us=%.2f waiting_origin_total_ms=%.2f",
           ie_n, avg_us(ie_n, ie_ns), ie_ns / 1e6,
           ie_gr_ns / 1e6, ie_bk_ns / 1e6, ie_dp_ns / 1e6,
           d_n, avg_us(d_n, d_ns), d_ns / 1e6,
           w_n, avg_us(w_n, w_ns), w_ns / 1e6);
}
#endif  // JETPACK_PROF

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
#ifdef JETPACK_PROF
  auto _prof_t0 = std::chrono::high_resolution_clock::now();
  int _prof_branch = phase_ % n_phase;
#endif
  switch (phase_++ % n_phase) {
    case Phase::INIT_END:
    {
#ifdef JETPACK_PROF
      auto _prof_get_ready_t0 = std::chrono::high_resolution_clock::now();
#endif
      dispatch_time_ = SimpleRWCommand::GetCurrentMsTime();
      dispatch_duration_3_times_ = (dispatch_time_ - clientworker_creation_time_) * 3;
      client_worker_->dispatch_time_distribution_.append(dispatch_time_ - clientworker_creation_time_);
      phase_cp = phase_;
      verify(phase_ % n_phase == Phase::DISPATCHED);
      fast_path_success_ = false;
      dispatch_ack_ = false;
      // FIX 1 (2026-05-19): increment coord-side in-flight counter.
      // Decrement happens before each End() call in this state machine.
      client_worker_->rule_outstanding_dispatches_.fetch_add(
          1, std::memory_order_relaxed);

      // [Ze] Get cmds_by_par_ and sp_vec_piece_by_par_ in advance here since both original path and fastpath need this
      cmds_by_par_ = ((TxData*) cmd_)->GetReadyPiecesData(100); // TODO setting n_pd larger than 1 will cause 2pl to wait forever
      for (auto& pair: cmds_by_par_) {
        auto& cmds = pair.second;
        if (cmds.size() > 0)
          cmd_is_write_ = SimpleRWCommand(cmds[0]).IsWrite();
      }
#ifdef JETPACK_PROF
      g_rule_init_end_get_ready_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::high_resolution_clock::now() - _prof_get_ready_t0).count(),
          std::memory_order_relaxed);
#endif

      if (Config::GetConfig()->IsCurpMode()) {
        go_to_fastpath_ = true;  // CURP: always attempt fast path, no throttle
      } else if (0 <= Config::GetConfig()->jetpack_fastpath_attempt_rate_ && Config::GetConfig()->jetpack_fastpath_attempt_rate_ <= 100) {
        // fixed percentage
        go_to_fastpath_ = RandomGenerator::rand(0, 99) < Config::GetConfig()->jetpack_fastpath_attempt_rate_;
      } else if (Config::GetConfig()->jetpack_fastpath_attempt_rate_ == 101) {
        if (Config::GetConfig()->replica_proto_ == MODE_RAFT) {
          // m=101 + Raft (set 2026-05-06 by user): strongly attempt fast path.
          //
          // The adaptive gate (warmup OR fp-latency<sp-latency OR bandit)
          // self-locked at saturation in v2 data (2026-05-06): on
          // rule_raft, fp%-attempted dropped from 97 % at c=50 to 0.9 %
          // at c=100 to 0 % at c≥150. Cluster-avg latency consequently
          // jumped from 161 ms to 394 ms between c=50 and c=100. Root
          // cause was the bandit-record bug (line 249, see below) feeding
          // fake "fail" signals on un-attempted transactions, cascading
          // into a closed gate. Hardcoding go_to_fastpath_=true makes
          // m=101+raft attempt-rate-equivalent to m=100 while keeping
          // all stat tracking intact.
          //
          // Scope: ONLY raft. Copilot / Mencius keep the adaptive gate
          // because their saturation behaviour is different (Mencius
          // already has the CPU-disable branch below; Copilot has its
          // own knee at c=75-100 that we don't want to override).
          go_to_fastpath_ = true;
        } else {
          go_to_fastpath_ = client_worker_->go_to_jetpack_fastpath_cnt_ < 10
                            || (client_worker_->cli2cli_[6+cmd_is_write_].count() > 0 && client_worker_->cli2cli_[6+cmd_is_write_].recent_100_ave() < client_worker_->cli2cli_[8+cmd_is_write_].recent_100_ave())
                            || client_worker_->one_armed_bandit_.ConsultAttempt();
        }
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
        // CPU-throttle for m=101+raft DISABLED 2026-05-06 by user.
        //
        // The block below was the previous adaptive-throttle: at high
        // leader CPU it would probabilistically suppress fast-path
        // attempts so jp-raft-adaptive gracefully degrades to vanilla
        // Raft at peak load. But it was overriding the m=101+raft
        // hardcode ("strongly attempt fast path") and producing
        // fp%-attempted = 0 at c=100 (leader CPU saturated above the
        // FP_LO=70% threshold). Disabling per user request to make
        // m=101+raft truly fp100 — accepting that c=300 will lose its
        // graceful-degradation property.
        //
        // } else if (Config::GetConfig()->replica_proto_ == MODE_RAFT ||
        //            Config::GetConfig()->replica_proto_ == MODE_FPGA_RAFT) {
        //   constexpr double FP_LO = 70.0;
        //   constexpr double FP_HI = 95.0;
        //   constexpr double FP_RANGE = FP_HI - FP_LO;
        //   double avg_leaders = client_worker_->cpu_usage_leaders_.recent_100_ave();
        //   double rand_val = RandomGenerator::rand(0, static_cast<int>(FP_RANGE));
        //   bool cpu_disabled = (avg_leaders - FP_LO) > rand_val;
        //   if (cpu_disabled) {
        //     go_to_fastpath_ = false;
        //   }
        //   static int raft_log_counter = 0;
        //   if (++raft_log_counter % 500 == 1) {
        //     Log_info("[CPU-RAFT] avg_leaders=%.2f "
        //              "ramp=[%.0f,%.0f] rand=%.2f cpu_disabled=%d go_fp=%d "
        //              "fp_cnt=%d",
        //              avg_leaders, FP_LO, FP_HI, rand_val,
        //              cpu_disabled, go_to_fastpath_,
        //              client_worker_->go_to_jetpack_fastpath_cnt_);
        //   }
        // }
      } else {
        verify(0);
      }

      // Throttle fast-path at high queue depth for MongoDB/Etcd/ZK/Copilot.
      // At low queue depth (<25): fast-path freely for latency benefit.
      // At high queue depth (>25): ramp down fast-path to avoid overhead from
      // failed speculative RPCs which hurt peak throughput at high concurrency.
      //
      // FIX 1 (2026-05-19): switched from
      // `client_worker_->queue_depth_.recent_100_ave()` (fed by spec-broadcast
      // replies, so only updates when fast-path actually fires — useless as
      // a feedback signal because it disables fast-path which kills the
      // signal source) to the coord-side `rule_outstanding_dispatches_`
      // atomic counter (tracks in-flight dispatches at this client). The new
      // signal is bounded by the test's `conc` parameter (per-client), so
      // thresholds are recalibrated for that scale.
      if (Config::GetConfig()->replica_proto_ == MODE_MONGODB ||
          Config::GetConfig()->replica_proto_ == MODE_ETCD ||
          Config::GetConfig()->replica_proto_ == MODE_ZOOKEEPER) {
        double queue_depth =
            static_cast<double>(client_worker_->rule_outstanding_dispatches_.load(
                std::memory_order_relaxed));
        if (queue_depth > 25) {
          double rand_val = RandomGenerator::rand(0, 99);
          double throttle = (queue_depth - 25) * 10; // 100% disable past qd=35
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

      // FIX 2 (2026-05-19): for KV-backend protocols (mongodb/etcd/zookeeper),
      // when fast-path will NOT fire for this transaction (either m=0 or
      // throttled by Fix 1), short-circuit the rule coord's bookkeeping.
      // Skip sp_vec_piece_by_par_, frequency_, and the per-piece map writes
      // that are only useful when the spec-broadcast path runs. Saves reactor
      // event work to keep the coord's per-tx overhead from compounding into
      // pplx callback queueing at saturation. Scope is gated to KV backends to
      // keep zero impact on raft/copilot/mencius where the rule machinery is
      // integral to the protocol's correctness.
      rule_short_circuit_ =
          (!go_to_fastpath_) &&
          (Config::GetConfig()->replica_proto_ == MODE_MONGODB ||
           Config::GetConfig()->replica_proto_ == MODE_ETCD ||
           Config::GetConfig()->replica_proto_ == MODE_ZOOKEEPER);

#ifdef JETPACK_PROF
      auto _prof_bookkeep_t0 = std::chrono::high_resolution_clock::now();
#endif
      if (rule_short_circuit_) {
        // Minimal INIT_END: only what DispatchAsync needs. Skip
        // sp_vec_piece_by_par_ (unused without spec broadcast), skip the
        // frequency_ stat append, but keep dispatch_acks_ (used by the
        // DISPATCHED commit path).
        for (auto& pair: cmds_by_par_) {
          auto& cmds = pair.second;
          n_dispatch_ += cmds.size();
          for (auto c: cmds) {
            c->id_ = next_pie_id();
            c->rule_mode_on_and_is_original_path_only_command_ = true;
            dispatch_acks_[c->inn_id_] = false;
          }
        }
      } else {
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
      }
#ifdef JETPACK_PROF
      g_rule_init_end_bookkeep_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::high_resolution_clock::now() - _prof_bookkeep_t0).count(),
          std::memory_order_relaxed);
      auto _prof_dispatch_t0 = std::chrono::high_resolution_clock::now();
#endif

      {
        // Merge mode (fused DispatchWithRuleSpec to leader + spec to
        // followers) is only sound under CURP semantics. Under cc:rule
        // (Jetpack) the proposing replica MUST be in the spec quorum —
        // see docs/jetpack_pseudocode_optimized.tex:81 and recovery's
        // PullRecovery → Paxos Accept reconstruction. Skipping the leader
        // here would drop FQ from 4-of-5 to 3-of-4 and silently break
        // recovery for fast-committed cmds. Commit 62e1d7db acknowledged
        // this; the gate below makes it impossible to reach the unsafe
        // path under cc:rule even if the YAML flag is set.
        bool use_merge = go_to_fastpath_ &&
                         Config::GetConfig()->jetpack_merge_leader_rpc_ &&
                         Config::GetConfig()->IsCurpMode();
        if (use_merge) {
          DispatchAndSpeculativeExecuteFused(phase_cp);
        } else {
          DispatchAsync(go_to_fastpath_ || Config::GetConfig()->replica_proto_ == MODE_COPILOT); // Copilot fast path or not both need to send to pilot and copilot

          if (go_to_fastpath_) {
            BroadcastRuleSpeculativeExecute(phase_cp);
          } else {
            // Do nothing
          }
        }
      }
#ifdef JETPACK_PROF
      g_rule_init_end_dispatch_ns_.fetch_add(
          std::chrono::duration_cast<std::chrono::nanoseconds>(
              std::chrono::high_resolution_clock::now() - _prof_dispatch_t0).count(),
          std::memory_order_relaxed);
#endif
      break;
    }
    case Phase::DISPATCHED:
      // FIX 2 (2026-05-19): short-circuit commit path for KV-backend protocols
      // when fast-path didn't fire. Skip cli2cli stat appends and bandit
      // recording (nothing to record when no fast-path was attempted). Keep
      // commit_time_ push (used by figure data) and the Fix 1 counter
      // decrement.
      if (rule_short_circuit_) {
        if (aborted_) {
          client_worker_->rule_outstanding_dispatches_.fetch_sub(
              1, std::memory_order_relaxed);  // Fix 1
          End();
          break;
        }
        committed_ = true;
        phase_++;
        verify(phase_ % n_phase == Phase::INIT_END);
        client_worker_->commit_time_.push_back(
            std::make_pair(dispatch_time_,
                            SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
        client_worker_->rule_outstanding_dispatches_.fetch_sub(
            1, std::memory_order_relaxed);  // Fix 1
        End();
        break;
      }
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
        client_worker_->rule_outstanding_dispatches_.fetch_sub(
            1, std::memory_order_relaxed);  // Fix 1
        End();
      }
      if (fast_path_success_ || dispatch_ack_) {
        committed_ = true;
        // verify(phase_ % n_phase == Phase::WAITING_ORIGIN);
        phase_++;
        verify(phase_ % n_phase == Phase::INIT_END);
        // Log_info("CoordinatorRule coo_id=%d thread_id=%d cmd_ver_=%d current_phase=%d [before dispatch end] fast_path_success_=%d dispatch_ack_=%d", coo_id_, thread_id_, cmd_ver_, current_phase, fast_path_success_, dispatch_ack_);
        // Defense-in-depth: only feed the bandit on transactions that
        // actually attempted fast path. Without this gate, an unattempted
        // transaction (go_to_fastpath_=false → no spec broadcast →
        // fast_path_success_ stays at its initialiser of false) would feed
        // the bandit a fake "fail" signal, which is exactly the death-spiral
        // observed for m=101 in 2026-05-06 v2 data (fp%-attempted=0 at
        // c≥150). Moot under the current m=101 = always-true gate but kept
        // correct so any future m∈[1,100] adaptive variant can't relapse.
        if (go_to_fastpath_) {
          client_worker_->one_armed_bandit_.Record(fast_path_success_);
        }
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
          // Mid-10s R/W split (set 2026-05-05): partition slot 5 by R/W.
          client_worker_->cli2cli_[10 + cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
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
        client_worker_->rule_outstanding_dispatches_.fetch_sub(
            1, std::memory_order_relaxed);  // Fix 1
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
        // Mid-10s R/W split (set 2026-05-05).
        client_worker_->cli2cli_[10 + cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
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
      client_worker_->rule_outstanding_dispatches_.fetch_sub(
          1, std::memory_order_relaxed);  // Fix 1
      End();
      break;
    default:
      verify(0);
  }
#ifdef JETPACK_PROF
  uint64_t _prof_dt = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::high_resolution_clock::now() - _prof_t0).count();
  if (_prof_branch == Phase::INIT_END) {
    g_rule_init_end_calls_.fetch_add(1, std::memory_order_relaxed);
    g_rule_init_end_ns_.fetch_add(_prof_dt, std::memory_order_relaxed);
  } else if (_prof_branch == Phase::DISPATCHED) {
    g_rule_dispatched_calls_.fetch_add(1, std::memory_order_relaxed);
    g_rule_dispatched_ns_.fetch_add(_prof_dt, std::memory_order_relaxed);
  } else {
    g_rule_waiting_origin_calls_.fetch_add(1, std::memory_order_relaxed);
    g_rule_waiting_origin_ns_.fetch_add(_prof_dt, std::memory_order_relaxed);
  }
#endif
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
    if (e->AvgCpuAll() > 0.0) {
      client_worker_->cpu_usage_all_.append(e->AvgCpuAll());
    }
    // Only append when the event actually saw a leader CPU sample. In the
    // merge-RPC fused path the spec broadcast skips the leader, so this
    // is 0 and we'd otherwise poison the rolling-avg with zeros that
    // mask the real saturated leader (the leader sample is appended
    // separately from the fused RPC reply — see rule/commo.cc).
    if (e->AvgCpuLeaders() > 0.0) {
      client_worker_->cpu_usage_leaders_.append(e->AvgCpuLeaders());
    }
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

void CoordinatorRule::DispatchAndSpeculativeExecuteFused(int phase) {
  // Fused path: skip the leader in the spec fan-out and fire a single
  // DispatchWithRuleSpec RPC to the leader whose reply also feeds the spec
  // quorum event. Total RPCs: N (1 fused to leader + N-1 spec to followers)
  // vs. N+1 in the split path. Leader sees 1 RPC instead of 2.
  auto txn = (TxData*) cmd_;
  auto cmds_by_par = cmds_by_par_;
  // [Jetpack] only supports partition = 1 for the rule layer today; the
  // split path has the same verify below. Keep this constraint explicit.
  verify(cmds_by_par.size() == 1);

  // 1) Spec quorum event: launch follower-only spec RPCs, do NOT wait.
  //    The quorum event is sized for N-1 follower votes only; the leader's
  //    dispatch in the fused RPC provides a stronger guarantee than a spec
  //    vote (full Raft log entry), so fastpath can commit once followers
  //    form quorum — no waiting on the fused reply's 2-RTT round trip.
  //    Lock protects coordinator state while issuing the RPCs; released
  //    before e->Wait() to avoid deadlocking against DispatchAck which
  //    also takes mtx_ when the fused reply arrives on another coroutine.
  shared_ptr<RuleSpeculativeExecuteQuorumEvent> e;
  parid_t par_id = cmds_by_par.begin()->first;
  {
    std::unique_lock<std::recursive_mutex> lock(mtx_);
    auto sp_vec_piece = sp_vec_piece_by_par_[par_id];
    verify(sp_vec_piece->size() == 1);  // matches split path's per-piece assumption
    shared_ptr<VecPieceData> sp_vpd(new VecPieceData);
    sp_vpd->sp_vec_piece_data_ = sp_vec_piece;
    sp_vpd_ = sp_vpd;
#ifdef MONGODB_DEBUG
    Log_info("%.2f DispatchAndSpeculativeExecuteFused <%d, %d>",
             SimpleRWCommand::GetMsTimeElaps(),
             SimpleRWCommand::GetCmdID(sp_vpd_).first,
             SimpleRWCommand::GetCmdID(sp_vpd_).second);
#endif
    e = ((CommunicatorRule *)commo())
            ->BroadcastRuleSpeculativeExecuteSkipLeader(sp_vec_piece);

    // 2) Fused leader RPC: carries both Dispatch and RuleSpeculativeExecute
    //    payload in a single round trip. The leader's spec vote in the
    //    reply is intentionally not fed into the quorum event (see above);
    //    only the dispatch callback is invoked, driving the slowpath if
    //    the follower spec quorum is not reached.
    ((CommunicatorRule *)commo())->BroadcastDispatchWithRuleSpec(
        sp_vec_piece,
        this,
        e,
        std::bind(&CoordinatorClassic::DispatchAck,
                  this,
                  phase_,
                  dispatch_time_,
                  std::placeholders::_1,
                  std::placeholders::_2));
  }  // release mtx_ before waiting

  // 3) Wait for spec quorum from the N-1 follower votes.
  e->Wait();
  if (client_worker_) {
    if (e->AvgCpuAll() > 0.0) {
      client_worker_->cpu_usage_all_.append(e->AvgCpuAll());
    }
    // Merge-RPC path: the event holds follower samples only, so
    // AvgCpuLeaders() is 0. The leader's CPU is appended separately
    // from BroadcastDispatchWithRuleSpec's reply callback — skipping
    // the zero here keeps the rolling avg tracking real leader load.
    if (e->AvgCpuLeaders() > 0.0) {
      client_worker_->cpu_usage_leaders_.append(e->AvgCpuLeaders());
    }
    double leader_queue_depth = e->LeaderQueueDepth();
    if (leader_queue_depth >= 0.0) {
      client_worker_->queue_depth_.append(leader_queue_depth);
    }
  }
#ifdef MONGODB_DEBUG
  Log_info("%.2f DispatchAndSpeculativeExecuteFused after wait <%d, %d>",
           SimpleRWCommand::GetMsTimeElaps(),
           SimpleRWCommand::GetCmdID(sp_vpd_).first,
           SimpleRWCommand::GetCmdID(sp_vpd_).second);
#endif

  bool latency_window = dispatch_duration_3_times_ > Config::GetConfig()->duration_ * 1000 &&
                        dispatch_duration_3_times_ < Config::GetConfig()->duration_ * 2 * 1000;
  bool skip_latency = latency_window && (txn->reply_.res_ == WRONG_LEADER || aborted_);
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
