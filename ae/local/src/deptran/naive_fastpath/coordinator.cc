#include "../__dep__.h"
#include "../constants.h"
#include "service.h"
#include "../config.h"
#include "../RW_command.h"
#include "../client_worker.h"
#include "coordinator.h"
#include "commo.h"

namespace janus {

void CoordinatorNaiveFastpath::GotoNextPhase() {
  int n_phase = 2;
  bool latency_window = dispatch_duration_3_times_ > Config::GetConfig()->duration_ * 1000 &&
                        dispatch_duration_3_times_ < Config::GetConfig()->duration_ * 2 * 1000;
  bool skip_latency = latency_window && aborted_;
  switch (phase_++ % n_phase) {
    case Phase::INIT_END: {
      verify(phase_ % n_phase == Phase::DISPATCH);
      dispatch_time_ = SimpleRWCommand::GetCurrentMsTime();
      dispatch_duration_3_times_ = (dispatch_time_ - clientworker_creation_time_) * 3;
      client_worker_->dispatch_time_distribution_.append(
          dispatch_time_ - clientworker_creation_time_);

      auto cmds_by_par = ((TxData*) cmd_)->GetReadyPiecesData(100);
      int phase_saved = phase_;
      for (auto& pair : cmds_by_par) {
        auto& cmds = pair.second;
        // Wire cmd_is_write_ for the mid-10s R/W split (set 2026-05-05).
        // Free to do here since cmds_by_par was just fetched and the
        // pieces are still in hand; mirrors rule::Coordinator's pattern.
        if (cmds.size() > 0)
          cmd_is_write_ = SimpleRWCommand(cmds[0]).IsWrite();
        auto sp_vec_piece = std::make_shared<vector<shared_ptr<TxPieceData>>>();
        for (auto c : cmds) {
          c->id_ = next_pie_id();
          sp_vec_piece->push_back(c);
          client_worker_->frequency_.append(SimpleRWCommand::GetKey(c));
        }
        n_dispatch_ += cmds.size();
        auto e = ((CommunicatorNaiveFastpath*) commo())
                     ->BroadcastDispatchToAll(sp_vec_piece);
        e->Wait();
      }
      if (phase_ != phase_saved) return;
      GotoNextPhase();
      break;
    }
    case Phase::DISPATCH:
      committed_ = true;
      verify(phase_ % n_phase == Phase::INIT_END);
      if (latency_window && !skip_latency) {
        client_worker_->cli2cli_[3].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        client_worker_->cli2cli_[4].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        client_worker_->cli2cli_[5].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
        // Mid-10s R/W split (set 2026-05-05).
        client_worker_->cli2cli_[10 + cmd_is_write_].append(SimpleRWCommand::GetCurrentMsTime() - dispatch_time_);
      }
      if (!aborted_) {
        client_worker_->commit_time_.push_back(
            std::make_pair(dispatch_time_,
                           SimpleRWCommand::GetCurrentMsTime() - dispatch_time_));
      }
      End();
      break;
    default:
      verify(0);
  }
}

} // namespace janus
