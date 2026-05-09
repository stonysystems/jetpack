
#include "coordinator.h"
#include "frame.h"
#include "benchmark_control_rpc.h"

#ifdef JETPACK_PROF
#include <atomic>
#include <chrono>
#endif

namespace janus {

#ifdef JETPACK_PROF
// Per-phase wall-time accounting for CoordinatorNone. Static file-scope
// atomics aggregate across all client threads on this process. Dumped from
// s_main.cc::client_shutdown() via JetpackProfNone_Dump().
static std::atomic<uint64_t> g_none_init_end_calls_{0};
static std::atomic<uint64_t> g_none_init_end_ns_{0};
static std::atomic<uint64_t> g_none_dispatch_calls_{0};
static std::atomic<uint64_t> g_none_dispatch_ns_{0};

void JetpackProfNone_Dump() {
  uint64_t ie_n = g_none_init_end_calls_.load();
  uint64_t ie_ns = g_none_init_end_ns_.load();
  uint64_t d_n  = g_none_dispatch_calls_.load();
  uint64_t d_ns = g_none_dispatch_ns_.load();
  auto avg_us = [](uint64_t n, uint64_t ns) {
    return n ? (double)ns / n / 1000.0 : 0.0;
  };
  Log_info("[PROF-COORD-NONE] init_end_calls=%lu init_end_avg_us=%.2f init_end_total_ms=%.2f | "
           "dispatch_calls=%lu dispatch_avg_us=%.2f dispatch_total_ms=%.2f",
           ie_n, avg_us(ie_n, ie_ns), ie_ns / 1e6,
           d_n,  avg_us(d_n, d_ns),  d_ns / 1e6);
}
#endif  // JETPACK_PROF

/** thread safe */

void CoordinatorNone::GotoNextPhase() {
  Log_debug("GoToNextPhase on client side");
  // uint64_t coroutine_id = Coroutine::CurrentCoroutine()->id;
  // uint64_t coroutine_global_id = Coroutine::CurrentCoroutine()->global_id;
  // Log_info("Enter GotoNextPhase CoroutineID %d %d phase_ = %d", Coroutine::CurrentCoroutine()->id, Coroutine::CurrentCoroutine()->global_id, phase_);
  int n_phase = 2;
  // int judgement_phase = phase_;
  bool latency_window = dispatch_duration_3_times_ > Config::GetConfig()->duration_ * 1000 &&
                            dispatch_duration_3_times_ < Config::GetConfig()->duration_ * 2 * 1000;
  bool skip_latency = latency_window && aborted_;
#ifdef JETPACK_PROF
  auto _prof_t0 = std::chrono::high_resolution_clock::now();
#endif
  int _prof_branch = phase_ % n_phase;
  switch (phase_++ % n_phase) {
    case Phase::INIT_END:
      // Log_info("Enter switch CoroutineID %d %d phase_ = %d", Coroutine::CurrentCoroutine()->id, Coroutine::CurrentCoroutine()->global_id, phase_);
      verify(phase_ % n_phase == Phase::DISPATCH);
      dispatch_time_ = SimpleRWCommand::GetCurrentMsTime();
      dispatch_duration_3_times_ = (dispatch_time_ - clientworker_creation_time_) * 3;
      client_worker_->dispatch_time_distribution_.append(dispatch_time_ - clientworker_creation_time_);
      // Wire cmd_is_write_ for the mid-10s R/W split (set 2026-05-05).
      // Use IsReadOnly() (non-destructive — reads txn type_ field) rather
      // than GetReadyPiecesData (which transitions DISPATCHABLE→DISPATCHED
      // and would consume the pieces before CoordinatorClassic::DispatchAsync
      // can see them).
      cmd_is_write_ = !((TxData*) cmd_)->IsReadOnly();
      DispatchAsync();
      break;
    case Phase::DISPATCH:
      // Log_info("Enter switch CoroutineID %d %d phase_ = %d", Coroutine::CurrentCoroutine()->id, Coroutine::CurrentCoroutine()->global_id, phase_);
      committed_ = true;
      verify(phase_ % n_phase == Phase::INIT_END);
      // if (skip_latency) {
      //   Log_info("[CLIENT-LATENCY] Skip cli2cli logging due to ABORTED (aborted=%d)", aborted_);
      // }
      if (latency_window && !skip_latency) {
        client_worker_->cli2cli_[3].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        client_worker_->cli2cli_[4].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        client_worker_->cli2cli_[5].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        // Mid-10s R/W split (set 2026-05-05).
        client_worker_->cli2cli_[10 + cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
      }
      // Log_info("End");
#ifdef JETPACK_WRONG_LEADER_DEBUG
      if (aborted_) {
        Log_info("[WRONG_LEADER_FLOW] CoordinatorNone skipping commit_time (aborted) for tx_id=%lu phase=%d dispatch_since_birth=%.2fms",
                 ((TxData*)cmd_)->id_, phase_,
                 dispatch_time_ - clientworker_creation_time_);
      } else {
        Log_info("[WRONG_LEADER_FLOW] CoordinatorNone recording commit_time for tx_id=%lu phase=%d dispatch_since_birth=%.2fms",
                 ((TxData*)cmd_)->id_, phase_,
                 dispatch_time_ - clientworker_creation_time_);
      }
#endif
      if (!aborted_)
        client_worker_->commit_time_.push_back(std::make_pair(dispatch_time_, SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
      End();
      break;
    default:
      verify(0);
  }
#ifdef JETPACK_PROF
  uint64_t _prof_dt = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::high_resolution_clock::now() - _prof_t0).count();
  if (_prof_branch == Phase::INIT_END) {
    g_none_init_end_calls_.fetch_add(1, std::memory_order_relaxed);
    g_none_init_end_ns_.fetch_add(_prof_dt, std::memory_order_relaxed);
  } else {
    g_none_dispatch_calls_.fetch_add(1, std::memory_order_relaxed);
    g_none_dispatch_ns_.fetch_add(_prof_dt, std::memory_order_relaxed);
  }
#endif
}

} // namespace janus
