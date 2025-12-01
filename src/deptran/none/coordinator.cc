
#include "coordinator.h"
#include "frame.h"
#include "benchmark_control_rpc.h"

namespace janus {

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
  switch (phase_++ % n_phase) {
    case Phase::INIT_END:
      // Log_info("Enter switch CoroutineID %d %d phase_ = %d", Coroutine::CurrentCoroutine()->id, Coroutine::CurrentCoroutine()->global_id, phase_);
      verify(phase_ % n_phase == Phase::DISPATCH);
      dispatch_time_ = SimpleRWCommand::GetCurrentMsTime();
      dispatch_duration_3_times_ = (dispatch_time_ - clientworker_creation_time_) * 3;
      client_worker_->dispatch_time_distribution_.append(dispatch_time_ - clientworker_creation_time_);
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
        client_worker_->commit_time_.push_back(std::make_pair(dispatch_time_ - clientworker_creation_time_, SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
      End();
      break;
    default:
      verify(0);
  }
}

} // namespace janus
