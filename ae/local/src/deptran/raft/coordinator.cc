
#include "../__dep__.h"
#include "../constants.h"
#include "coordinator.h"
#include "commo.h"
#include "../classic/tpc_command.h"
#include "../procedure.h"
#include "../config.h"

#include "server.h"

namespace janus {

CoordinatorRaft::CoordinatorRaft(uint32_t coo_id,
                                             int32_t benchmark,
                                             ClientControlServiceImpl* ccsi,
                                             uint32_t thread_id)
    : Coordinator(coo_id, benchmark, ccsi, thread_id) {
}

bool CoordinatorRaft::IsLeader() {
   return this->svr_->IsLeader() ;
}

bool CoordinatorRaft::IsFPGALeader() {
   return this->svr_->IsFPGALeader() ;
}

void CoordinatorRaft::Submit(shared_ptr<Marshallable>& cmd,
                                   const function<void()>& func,
                                   const function<void()>& exe_callback) {
  if (this->svr_->paused_) { // [Jetpack] Bad fix for failure recovery. I don't know why server can still receive commands even if Client is paused_
    return;
  }
  auto reject_as_wrong_leader = [&](const char* reason_tag) {
    auto config = Config::GetConfig();
#ifdef JETPACK_WRONG_LEADER_DEBUG
    const auto& site = config->SiteById(svr_->site_id_);
    Log_info("[WRONG_LEADER] %s | server=%d loc=%d partition=%d term=%lu commitIndex=%lu lastLogIndex=%lu host=%s locale=%d",
             reason_tag,
             svr_->site_id_,
             loc_id_,
             site.partition_id_,
             svr_->currentTerm,
             svr_->commitIndex,
             svr_->lastLogIndex,
             site.host.c_str(),
             site.locale_id);
#endif

    if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT) {
      auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
      if (tpc_cmd) {
        tpc_cmd->ret_ = WRONG_LEADER;
        View current_view = svr_->new_view_;
#ifdef JETPACK_WRONG_LEADER_DEBUG
        Log_info("[WRONG_LEADER] Server %d using view: %s",
                 svr_->site_id_, current_view.ToString().c_str());
#endif
        if (current_view.IsEmpty()) {
          int n_replicas = config->GetPartitionSize(par_id_);
          current_view = View(n_replicas, -1, svr_->currentTerm);
#ifdef JETPACK_WRONG_LEADER_DEBUG
          Log_info("[WRONG_LEADER] Constructed placeholder view: %s",
                   current_view.ToString().c_str());
#endif
        }
        tpc_cmd->sp_view_data_ = std::make_shared<ViewData>(current_view, par_id_);
#ifdef JETPACK_WRONG_LEADER_DEBUG
        Log_info("[WRONG_LEADER] Attached view data for partition %d: %s",
                 par_id_, tpc_cmd->sp_view_data_->ToString().c_str());
#endif
      }
    }

    func();
    svr_->app_next_(*cmd);
  };

  if (!IsLeader()) {
    reject_as_wrong_leader("Submit to server that is not leader");
    return;
  }

  bool is_recovery_cmd = SimpleRWCommand(cmd).IsRecoveryCommand();

  if (!is_recovery_cmd
      && !Config::GetConfig()->IsCurpMode()
      && svr_->jetpack_status_ == TxLogServer::JetpackStatus::RECOVERY) {
#ifdef JETPACK_WRONG_LEADER_DEBUG
    Log_info("[JETPACK-RECOVERY] Server %d rejecting Submit because Jetpack is in RECOVERY",
             svr_->site_id_);
#endif
    reject_as_wrong_leader("Jetpack recovery in progress");
    return;
  }
  // else {
  //   Log_info("[YYYYY] Submit to loc_id %d, which is leader. Command kind=%d, is_recovery=%d", 
  //            loc_id_, cmd ? cmd->kind_ : -1, SimpleRWCommand(cmd).IsRecoveryCommand());
  // }
	std::lock_guard<std::recursive_mutex> lock(mtx_);

  verify(!in_submission_);
  verify(cmd_ == nullptr);
//  verify(cmd.self_cmd_ != nullptr);
  in_submission_ = true;
  cmd_ = cmd;
  verify(cmd_->kind_ != MarshallDeputy::UNKNOWN);
  commit_callback_ = func;
  GotoNextPhase();
}

void CoordinatorRaft::AppendEntries() {
    std::lock_guard<std::recursive_mutex> lock(mtx_);
    verify(!in_append_entries);
    // verify(this->svr_->IsLeader()); TODO del it yidawu
    in_append_entries = true;
    uint64_t index, term;
    bool ok = this->svr_->Start(cmd_, &index, &term); // slot_id_, curr_ballot_);
    verify(ok);
    svr_->NotifyReplicationEvents();

    while (this->svr_->commitIndex < index) {
      Reactor::CreateSpEvent<TimeoutEvent>(1000)->Wait();
      if (this->svr_->currentTerm != term) {
        Log_debug("Term changed during AppendEntries: expected %lu, got %lu. Leader changed.", 
                 term, this->svr_->currentTerm);
        // The command may or may not be committed by the new leader
        // Mark as not committed and let higher layers retry
        committed_ = false;
        in_append_entries = false;
        return;
      }
    }
    
    
    
    committed_ = true;
}

// void CoordinatorRaft::AppendEntries() {
//     std::lock_guard<std::recursive_mutex> lock(mtx_);
//     verify(!in_append_entries);
//     // verify(this->svr_->IsLeader()); TODO del it yidawu
//     in_append_entries = true;
//     Log_debug("fpga-raft coordinator broadcasts append entries, "
//                   "par_id_: %lx, slot_id: %llx, lastLogIndex: %d",
//               par_id_, slot_id_, this->svr_->lastLogIndex);
//     /* Should we use slot_id instead of lastLogIndex and balot instead of term? */
//     uint64_t prevLogIndex = this->svr_->lastLogIndex;

//     /*this->svr_->lastLogIndex += 1;
//     auto instance = this->svr_->GetRaftInstance(this->svr_->lastLogIndex);

//     instance->log_ = cmd_;
//     instance->term = this->svr_->currentTerm;*/

//     /* TODO: get prevLogTerm based on the logs */
//     uint64_t prevLogTerm = this->svr_->GetRaftInstance(prevLogIndex)->term;
// 		this->svr_->SetLocalAppend(cmd_, &prevLogTerm, &prevLogIndex, slot_id_, curr_ballot_) ;
		

//     auto sp_quorum = commo()->BroadcastAppendEntries(par_id_,
//                                                      this->svr_->site_id_,
//                                                      slot_id_,
//                                                      dep_id_,
//                                                      curr_ballot_,
//                                                      this->svr_->IsLeader(),
//                                                      this->svr_->currentTerm,
//                                                      prevLogIndex,
//                                                      prevLogTerm,
//                                                      /* ents, */
//                                                      this->svr_->commitIndex,
//                                                      cmd_);

// 		struct timespec start_;
// 		clock_gettime(CLOCK_MONOTONIC, &start_);
//     sp_quorum->Wait();
// 		struct timespec end_;
// 		clock_gettime(CLOCK_MONOTONIC, &end_);

// 		// quorum_events_.push_back(sp_quorum);
// 		// Log_info("time of Wait(): %d", (end_.tv_sec-start_.tv_sec)*1000000000 + end_.tv_nsec-start_.tv_nsec);
// 		slow_ = sp_quorum->IsSlow();
		
// 		long leader_time;
// 		std::vector<long> follower_times {};

// 		int total_ob = 0;
// 		int avg_ob = 0;
// 		//Log_info("begin_index: %d", commo()->begin_index);
// 		if (commo()->begin_index >= 1000) {
// 			if (commo()->ob_index < 100) {
// 				commo()->outbounds[commo()->ob_index] = commo()->outbound;
// 				commo()->ob_index++;
// 			} else {
// 				for (int i = 0; i < 99; i++) {
// 					commo()->outbounds[i] = commo()->outbounds[i+1];
// 					total_ob += commo()->outbounds[i];
// 				}
// 				commo()->outbounds[99] = commo()->outbound;
// 				total_ob += commo()->outbounds[99];
// 			}
// 			commo()->begin_index = 0;
// 		} else {
// 			commo()->begin_index++;
// 		}
// 		avg_ob = total_ob/100;

// 		for (auto it = commo()->rpc_clients_.begin(); it != commo()->rpc_clients_.end(); it++) {
// 			if (avg_ob > 0 && it->second->time_ > 0) Log_info("time for %d is: %d", it->first, it->second->time_/avg_ob);
// 			if (it->first != loc_id_) {
// 				follower_times.push_back(it->second->time_);
// 			}
// 		}
// 		if (avg_ob > 0 && !slow_) {
// 			Log_debug("number of rpcs: %d", avg_ob);
// 			Log_debug("%d and %d", follower_times[0]/avg_ob, follower_times[1]/avg_ob);
// 			slow_ = follower_times[0]/avg_ob > 80000 && follower_times[1]/avg_ob > 80000;
// 		}

// 		//Log_info("slow?: %d", slow_);
//     if (sp_quorum->Yes()) {
//         minIndex = sp_quorum->minIndex;
// 				//Log_info("%d vs %d", minIndex, this->svr_->commitIndex);
//         verify(minIndex >= this->svr_->commitIndex) ;
//         committed_ = true;
//         Log_debug("fpga-raft append commited loc:%d minindex:%d", loc_id_, minIndex ) ;
//     }
//     else if (sp_quorum->No()) {
//         verify(0);
//         // TODO should become a follower if the term is smaller
//         //if(!IsLeader())
//         {
//             Forward(cmd_,commit_callback_) ;
//             return ;
//         }
//     }
//     else {
//         verify(0);
//     }
// }

void CoordinatorRaft::Commit() {
  verify(0);
  std::lock_guard<std::recursive_mutex> lock(mtx_);
  commit_callback_();
  verify(phase_ == Phase::COMMIT);
  GotoNextPhase();
}

void CoordinatorRaft::LeaderLearn() {
    std::lock_guard<std::recursive_mutex> lock(mtx_);
    commit_callback_();
    verify(phase_ == Phase::COMMIT);
    GotoNextPhase();
}

void CoordinatorRaft::GotoNextPhase() {
  int n_phase = 4;
  int current_phase = phase_ % n_phase;
  phase_++;
  switch (current_phase) {
    case Phase::INIT_END:
      if (IsLeader()) {
        phase_++; // skip prepare phase for "leader"
        verify(phase_ % n_phase == Phase::ACCEPT);
        AppendEntries();
        phase_++;
        verify(phase_ % n_phase == Phase::COMMIT);
      } else {
        // TODO
        verify(0);
        // Forward(cmd_,commit_callback_) ;
        phase_ = Phase::COMMIT;
      }
    case Phase::ACCEPT:
      verify(phase_ % n_phase == Phase::COMMIT);
      if (committed_) {
        LeaderLearn();
      } else {
        // verify(0);
        // Forward(cmd_,commit_callback_) ;
        phase_ = Phase::COMMIT;
      }
      break;
    case Phase::PREPARE:
      verify(phase_ % n_phase == Phase::ACCEPT);
      AppendEntries();
      break;
    case Phase::COMMIT:
      // do nothing.
      break;
    default:
      verify(0);
  }
}

} // namespace janus
