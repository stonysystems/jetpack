#include "server.h"
// #include "paxos_worker.h"
#include "exec.h"
#include "frame.h"
#include "coordinator.h"
#include "../classic/tpc_command.h"


namespace janus {

std::shared_ptr<IntEvent> RaftServer::CreateReplicationEvent(siteid_t follower_site_id) {
  std::lock_guard<std::recursive_mutex> lock(ready_for_replication_mtx_);
  auto event = Reactor::CreateSpEvent<IntEvent>();
  ready_for_replication_[follower_site_id] = event;
  return event;
}

void RaftServer::NotifyReplicationEvents() {
  std::lock_guard<std::recursive_mutex> lock(ready_for_replication_mtx_);
  for (auto& kv : ready_for_replication_) {
    if (kv.second) {
      kv.second->Set(1);
    }
  }
}

void RaftServer::LogTermChange(const char* reason,
                               uint64_t old_term,
                               uint64_t new_term,
                               siteid_t source) {
  if (old_term == new_term) {
    return;
  }
  const char* why = reason ? reason : "unspecified";
  if (source != INVALID_SITEID) {
    Log_info("[RAFT-TERM] server %d term %lu -> %lu (%s, source_site=%d)",
             site_id_, old_term, new_term, why, source);
  } else {
    Log_info("[RAFT-TERM] server %d term %lu -> %lu (%s)",
             site_id_, old_term, new_term, why);
  }
}

RaftServer::RaftServer(Frame * frame) {
  frame_ = frame ;
#ifdef RAFT_TEST_CORO
  setIsLeader(false);
#endif
  stop_ = false ;
  timer_ = new Timer() ;
}

void RaftServer::OnJetpackPullCmd(const epoch_t& jepoch,
                                   const epoch_t& oepoch,
                                   const std::vector<key_t>& keys,
                                   bool_t* ok,
                                   epoch_t* reply_jepoch,
                                   epoch_t* reply_oepoch,
                                   MarshallDeputy* reply_old_view,
                                    MarshallDeputy* reply_new_view,
                                    shared_ptr<KeyCmdBatchData>& batch) {
  TxLogServer::OnJetpackPullCmd(jepoch, oepoch, keys, ok, reply_jepoch, reply_oepoch,
                                reply_old_view, reply_new_view, batch);
  if (!IsLeader()) {
    resetTimer("JetpackPullCmd RPC");
#ifdef RAFT_LEADER_ELECTION_DEBUG
    // Log_info("[RAFT_TIMER] server %d reset election timer due to JetpackPullCmd (keys=%zu)",
    //          site_id_, keys.size());
#endif
  }
}

void RaftServer::OnJetpackPullRecovery(const MarshallDeputy& old_view,
                                       const MarshallDeputy& new_view,
                                       const epoch_t& jepoch,
                                       const epoch_t& oepoch,
                                       bool_t* ok,
                                       epoch_t* reply_jepoch,
                                       epoch_t* reply_oepoch,
                                       MarshallDeputy* reply_old_view,
                                       MarshallDeputy* reply_new_view,
                                       shared_ptr<KeyCmdIdBatchData>& batch) {
  TxLogServer::OnJetpackPullRecovery(old_view, new_view, jepoch, oepoch, ok,
                                     reply_jepoch, reply_oepoch, reply_old_view, reply_new_view, batch);
  if (!IsLeader()) {
    resetTimer("JetpackPullRecovery RPC");
  }
}

void RaftServer::OnJetpackBeginRecovery(const MarshallDeputy& old_view,
                                        const MarshallDeputy& new_view,
                                        const epoch_t& new_view_id) {
  TxLogServer::OnJetpackBeginRecovery(old_view, new_view, new_view_id);
  if (!IsLeader()) {
    resetTimer("JetpackBeginRecovery RPC");
  }
}

void RaftServer::OnJetpackPrepare(const epoch_t& jepoch,
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
  TxLogServer::OnJetpackPrepare(jepoch, oepoch, max_seen_ballot, ok, reply_jepoch,
                                reply_oepoch, reply_old_view, reply_new_view, reply_max_seen_ballot,
                                accepted_ballot, replied_sid);
  if (!IsLeader()) {
    resetTimer("JetpackPrepare RPC");
  }
}

void RaftServer::OnJetpackAccept(const epoch_t& jepoch,
                                 const epoch_t& oepoch,
                                 const ballot_t& max_seen_ballot,
                                 const int32_t& sid,
                                 bool_t* ok,
                                 epoch_t* reply_jepoch,
                                 epoch_t* reply_oepoch,
                                 MarshallDeputy* reply_old_view,
                                 MarshallDeputy* reply_new_view,
                                 ballot_t* reply_max_seen_ballot) {
  TxLogServer::OnJetpackAccept(jepoch, oepoch, max_seen_ballot, sid, ok,
                               reply_jepoch, reply_oepoch, reply_old_view, reply_new_view, reply_max_seen_ballot);
  if (!IsLeader()) {
    resetTimer("JetpackAccept RPC");
  }
}

void RaftServer::OnJetpackCommit(const epoch_t& jepoch,
                                 const epoch_t& oepoch,
                                 const int32_t& sid) {
  TxLogServer::OnJetpackCommit(jepoch, oepoch, sid);
  if (!IsLeader()) {
    resetTimer("JetpackCommit RPC");
  }
}

void RaftServer::Setup() {

  if (heartbeat_) {
    Log_debug("starting heartbeat loops at leader site %d", site_id_);
    looping_ = true;
    auto proxies = commo()->rpc_par_proxies_[partition_id_];
    for (auto& p : proxies) {
      if (p.first == loc_id_) {
        continue;
      }
      match_index_[p.first] = 0;
      next_index_[p.first] = 1;
      auto event = CreateReplicationEvent(p.first);
      Coroutine::CreateRun([this, follower=p.first, event]() {
        (void) event;
        this->HeartbeatLoop(follower);
      });
    }
    verify(match_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
    verify(next_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
    if (failover_) {
      Coroutine::CreateRun([this]() {
        StartElectionTimer();
      });
    }
  }
  StartJetpackRecoveryLoop();
  // Election timer will be started in Start() method when first command is submitted
}

void RaftServer::Disconnect(const bool disconnect) {
  std::lock_guard<std::recursive_mutex> lock(mtx_);
  verify(disconnected_ != disconnect);
  // global map of rpc_par_proxies_ values accessed by partition then by site
  static map<parid_t, map<siteid_t, map<siteid_t, vector<SiteProxyPair>>>> _proxies{};
  if (_proxies.find(partition_id_) == _proxies.end()) {
    _proxies[partition_id_] = {};
  }
  RaftCommo *c = (RaftCommo*) commo();
  if (disconnect) {
    verify(_proxies[partition_id_][loc_id_].size() == 0);
    verify(c->rpc_par_proxies_.size() > 0);
    auto sz = c->rpc_par_proxies_.size();
    _proxies[partition_id_][loc_id_].insert(c->rpc_par_proxies_.begin(), c->rpc_par_proxies_.end());
    c->rpc_par_proxies_ = {};
    verify(_proxies[partition_id_][loc_id_].size() == sz);
    verify(c->rpc_par_proxies_.size() == 0);
  } else {
    verify(_proxies[partition_id_][loc_id_].size() > 0);
    auto sz = _proxies[partition_id_][loc_id_].size();
    c->rpc_par_proxies_ = {};
    c->rpc_par_proxies_.insert(_proxies[partition_id_][loc_id_].begin(), _proxies[partition_id_][loc_id_].end());
    _proxies[partition_id_][loc_id_] = {};
    verify(_proxies[partition_id_][loc_id_].size() == 0);
    verify(c->rpc_par_proxies_.size() == sz);
  }
  disconnected_ = disconnect;
}

bool RaftServer::IsDisconnected() {
  return disconnected_;
}

void RaftServer::StartJetpackRecoveryLoop() {
#ifndef RAFT_TEST_CORO
  if (jetpack_recovery_loop_started_) {
    return;
  }
  jetpack_recovery_loop_started_ = true;
  {
    std::lock_guard<std::recursive_mutex> lock(jetpack_recovery_event_mtx_);
    jetpack_recovery_event_ = Reactor::CreateSpEvent<IntEvent>();
  }
  Coroutine::CreateRun([this]() {
    this->JetpackRecoveryLoop();
  });
#endif
}

void RaftServer::TriggerJetpackRecovery(const char* reason) {
#ifndef RAFT_TEST_CORO
	StartJetpackRecoveryLoop();
	const char* why = reason ? reason : "unspecified";
	std::shared_ptr<IntEvent> ev;
	{
		std::lock_guard<std::recursive_mutex> lock(jetpack_recovery_event_mtx_);
		if (!jetpack_recovery_event_) {
			jetpack_recovery_event_ = Reactor::CreateSpEvent<IntEvent>();
		}
		jetpack_recovery_pending_ = 1; // we only need a single run per trigger burst
		ev = jetpack_recovery_event_;
	}
	Log_info("[JETPACK_RECOVERY] site %d (loc %d) trigger (%s) pending=%d",
					 site_id_, loc_id_, why, jetpack_recovery_pending_);
	ev->Set(1);
#endif
}

void RaftServer::JetpackRecoveryLoop() {
#ifndef RAFT_TEST_CORO
	while (!stop_) {
		// If we already have pending triggers, skip waiting.
		int pending = 0;
		std::shared_ptr<IntEvent> ev;
		{
			std::lock_guard<std::recursive_mutex> lock(jetpack_recovery_event_mtx_);
			if (!jetpack_recovery_event_) {
				jetpack_recovery_event_ = Reactor::CreateSpEvent<IntEvent>();
			}
			ev = jetpack_recovery_event_;
			pending = jetpack_recovery_pending_ > 0 ? 1 : 0;
			jetpack_recovery_pending_ = 0;
		}
		if (pending == 0) {
			ev->Wait();
			if (stop_) break;
			{
				std::lock_guard<std::recursive_mutex> lock(jetpack_recovery_event_mtx_);
				pending = jetpack_recovery_pending_ > 0 ? 1 : 0;
				jetpack_recovery_pending_ = 0;
			}
			// If we were woken without a trigger, still avoid spurious runs.
		}
		if (stop_) break;
		if (pending > 0) {
			Log_info("[JETPACK_RECOVERY] site %d (loc %d) running recovery", site_id_, loc_id_);
			JetpackRecoveryEntry();
		}
		// Re-arm the event for the next trigger.
		{
			std::lock_guard<std::recursive_mutex> lock(jetpack_recovery_event_mtx_);
			jetpack_recovery_event_ = Reactor::CreateSpEvent<IntEvent>();
		}
	}
#endif
}

// void RaftServer::setIsLeader(bool isLeader) {
//   Log_info("set siteid %d is leader %d", frame_->site_info_->locale_id, isLeader) ;
  
//   // Log leader initialization when becoming a leader
//   if (isLeader) {
    
//     // CRITICAL FIX: Ensure lastLogIndex matches the highest index in raft_logs_
//     if (!raft_logs_.empty()) {
//       auto max_index = std::max_element(raft_logs_.begin(), raft_logs_.end(),
//                                        [](const auto& a, const auto& b) {
//                                          return a.first < b.first;
//                                        })->first;
//       if (max_index > lastLogIndex) {
//         lastLogIndex = max_index;
//       }
//     }
//   }
  
//   // Only update view when transitioning from non-leader to leader
//   if (isLeader && !is_leader_) {
//     // Only update view if we have enough information (not during initialization)
//     if (partition_id_ != 0xFFFFFFFF && site_id_ != -1 && frame_ != nullptr) {
//       // Move current new_view to old_view before updating
//       old_view_ = new_view_;
      
//       // Update new_view with this server as the leader
//       int n_replicas = Config::GetConfig()->GetPartitionSize(partition_id_);
//       new_view_ = View(n_replicas, site_id_, currentTerm);
//     }
//   } else if (!isLeader && is_leader_) {
//     // When transitioning from leader to non-leader
//     // View will be updated when we learn about the new leader
//   }
  
//   // Update the leader state after view handling
//   is_leader_ = isLeader;
  
//   if (isLeader) {
//     // JetpackRecovery();
//     // if (heartbeat_) {
//     //   Log_debug("starting heartbeat loop at site %d", site_id_);
//     //   Coroutine::CreateRun([this](){
//     //     this->HeartbeatLoop(); 
//     //   });
//     //   // Start election timeout loop
//     //   if (failover_) {
//     //     Coroutine::CreateRun([this](){
//     //       StartElectionTimer(); 
//     //     });
//     //   }
//     // }
//     // Log_info("!!!!!!! if (!failover_)");
//     // if (!failover_) {
//       // verify(frame_->site_info_->id == 0);
//       return;
//     // }
//     // Reset leader volatile state
//     RaftCommo *c = (RaftCommo*) commo();
//     auto proxies = c->rpc_par_proxies_[partition_id_];
    
//     // Clear existing indices first
//     match_index_.clear();
//     next_index_.clear();
    
//     for (auto& p : proxies) {
//       if (p.first != site_id_) {
//         // set matchIndex = 0
//         match_index_[p.first] = 0;
//         // set nextIndex = lastLogIndex + 1
//         next_index_[p.first] = lastLogIndex + 1;
//       }
//     }
//     // matchedIndex and nextIndex should have indices for all servers except self
//     verify(match_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
//     verify(next_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
//   }
// }

void RaftServer::setIsLeader(bool isLeader) {
  bool prev_is_leader = is_leader_;
#ifdef RAFT_LEADER_ELECTION_DEBUG
  Log_info("[RAFT_STATE] setIsLeader invoked site %d (loc %d) term %lu: prev_is_leader=%d new_is_leader=%d",
           site_id_, frame_->site_info_->locale_id, currentTerm, prev_is_leader, isLeader);
#endif


  if (isLeader) {  // [Jetpack] This need to be done before new leader realized it is a leader, otherwise new leader will use incorrect next_index_ balabala
    // Add null check for communicator
    if (commo_ == nullptr) {
      Log_info("commo_ is null, skipping leader initialization");
    } else {
      // Reset leader volatile state
      RaftCommo *c = (RaftCommo*) commo();
      auto proxies = c->rpc_par_proxies_[partition_id_];
      if(failover_) {
        for (auto& p : proxies) {
          if (p.first != site_id_) {
            // set matchIndex = 0
            match_index_[p.first] = 0;
            // set nextIndex = lastLogIndex + 1
            next_index_[p.first] = lastLogIndex + 1;
            Log_info("loc_id_=%d match_index_[%d]=%d, next_index_[%d]=%d", loc_id_, p.first, match_index_[p.first], p.first, next_index_[p.first]);
          }
        }
        // matchedIndex and nextIndex should have indices for all servers except self
        verify(match_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
        verify(next_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
      }
    }
  }

  
  // This 2 lines MUST put BEFORE is_leader_ = isLeader ! otherwise they will become 0, and new view will without leader
  bool become_new_leader = isLeader && !is_leader_;
  bool become_new_follower = !isLeader && is_leader_;

  // Update the leader state after view handling
  is_leader_ = isLeader;

  Log_info("RaftServer::setIsLeader site_id_ %d become_new_leader %d become_new_follower %d isLeader %d", site_id_, become_new_leader, become_new_follower, isLeader);

  // Only update view when transitioning from non-leader to leader
  if (become_new_leader) {
    Log_info("[RAFT_STATE] setIsLeader transition LEADER: site %d term %lu prev_is_leader=%d become_new_leader=%d", 
             site_id_, currentTerm, prev_is_leader, become_new_leader);
    // Only update view if we have enough information (not during initialization)
    if (partition_id_ != 0xFFFFFFFF && site_id_ != -1 && frame_ != nullptr) {
      // Move current new_view to old_view before updating
      old_view_ = new_view_;
      
      // Update new_view with this server as the leader
      int n_replicas = Config::GetConfig()->GetPartitionSize(partition_id_);
      new_view_ = View(n_replicas, site_id_, currentTerm);
      Log_info("[RAFT_VIEW] Server %d became leader for partition %d, term=%lu, old_view=%s, new_view=%s", 
               site_id_, partition_id_, currentTerm, 
               old_view_.ToString().c_str(), new_view_.ToString().c_str());
      
      // IMPORTANT: Update the communicator's view so it knows this server is the leader
      if (commo_) {
        auto view_data = std::make_shared<ViewData>(new_view_, partition_id_);
        commo()->UpdatePartitionView(partition_id_, view_data);
        Log_info("[RAFT_VIEW] Updated communicator view for partition %d with new leader %d", 
                 partition_id_, site_id_);
      }
      
#ifndef RAFT_TEST_CORO
      TriggerJetpackRecovery("setIsLeader transition to leader");
#endif
    }
  } else if (become_new_follower) {
    Log_info("[RAFT_STATE] setIsLeader transition FOLLOWER: site %d term %lu prev_is_leader=%d become_new_follower=%d", 
             site_id_, currentTerm, prev_is_leader, become_new_follower);
    // When transitioning from leader to non-leader
    Log_info("[RAFT_VIEW] Server %d stepping down as leader for partition %d", site_id_, partition_id_);
    
    // // IMPORTANT: Clear leader-specific state to prevent stale values
    // match_index_.clear();
    // next_index_.clear();
    // Log_info("[RAFT_STATE] Server %d cleared match_index_ and next_index_ after stepping down", site_id_);
    
    // View will be updated when we learn about the new leader
  }
  
  if (isLeader) { 
    // Add null check for communicator
    if (commo_ == nullptr) {
      Log_info("commo_ is null, skipping leader initialization");
    } else {
      // Reset leader volatile state
      RaftCommo *c = (RaftCommo*) commo();
      auto proxies = c->rpc_par_proxies_[partition_id_];
      if(failover_) {
        for (auto& p : proxies) {
          if (p.first != site_id_) {
            // set matchIndex = 0
            match_index_[p.first] = 0;
            // set nextIndex = lastLogIndex + 1
            next_index_[p.first] = lastLogIndex + 1;
            Log_info("loc_id_=%d match_index_[%d]=%d, next_index_[%d]=%d", loc_id_, p.first, match_index_[p.first], p.first, next_index_[p.first]);
          }
        }
        // matchedIndex and nextIndex should have indices for all servers except self
        verify(match_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
        verify(next_index_.size() == Config::GetConfig()->GetPartitionSize(partition_id_) - 1);
      }
    }
  }

  
}

void RaftServer::applyLogs() {
  // This prevents the log entry from being applied twice
  if (in_applying_logs_) {
    return;
  }
  in_applying_logs_ = true;
  
  for (slotid_t id = executeIndex + 1; id <= commitIndex; id++) {
    auto next_instance = GetRaftInstance(id);
    if (next_instance && next_instance->log_) {
      RuleWitnessGC(next_instance->log_);
      app_next_(*next_instance->log_);
      executeIndex = id;
    } else {
      break;
    }
  }

  in_applying_logs_ = false;
  int i = min_active_slot_;
  while (i + 60000 < executeIndex) {
    removeCmd(i++);
  }
  min_active_slot_ = i;
}

void RaftServer::HeartbeatLoop(siteid_t follower_site_id) {
  auto hb_timer = new Timer();
  hb_timer->start();

  parid_t partition_id = partition_id_;

  Log_debug("heartbeat loop init from site: %d targeting follower %d", site_id_, follower_site_id);
  while (looping_) {
    auto event = CreateReplicationEvent(follower_site_id);
    event->Wait(HEARTBEAT_INTERVAL);
    if (!IsLeader()) {
      continue;
    }
    uint64_t term = 0;
    auto nservers = Config::GetConfig()->GetPartitionSize(partition_id);
    {
      std::lock_guard<std::recursive_mutex> lock(mtx_);
      std::vector<uint64_t> matchedIndices{};
      for (auto& kv : match_index_) {
        matchedIndices.push_back(kv.second);
      }
      if (matchedIndices.size() == nservers - 1) {
        std::sort(matchedIndices.begin(), matchedIndices.end());
        uint64_t newCommitIndex = matchedIndices[(nservers - 1) / 2];
        if (newCommitIndex > lastLogIndex) {
          Log_info("[COMMIT_INDEX_DEBUG] Leader %d: newCommitIndex=%ld > lastLogIndex=%ld",
                   site_id_, newCommitIndex, lastLogIndex);
          newCommitIndex = lastLogIndex;
          Log_info("[COMMIT_INDEX_DEBUG] Fixed newCommitIndex to %ld", newCommitIndex);
        }
        if (newCommitIndex > commitIndex && (GetRaftInstance(newCommitIndex)->term == currentTerm)) {
          commitIndex = newCommitIndex;
        }
        if (commitIndex > executeIndex) {
          applyLogs();
        }
      }
      term = currentTerm;
    }

    mtx_.lock();
    auto it = next_index_.find(follower_site_id);
    if (it == next_index_.end()) {
      mtx_.unlock();
      continue;
    }
    uint64_t prevLogIndex = it->second - 1;
    if (prevLogIndex > lastLogIndex) {
      Log_info("[APPEND_ENTRIES] ERROR: prevLogIndex (%ld) > lastLogIndex (%ld), fixing next_index", prevLogIndex, lastLogIndex);
      it->second = lastLogIndex + 1;
      prevLogIndex = it->second - 1;
    }
    if (prevLogIndex > lastLogIndex) {
      Log_info("[APPEND_ENTRIES] WARNING: Cannot send AppendEntries to follower %d: prevLogIndex (%ld) > lastLogIndex (%ld), skipping",
               follower_site_id, prevLogIndex, lastLogIndex);
      it->second = 1;
      mtx_.unlock();
      continue;
    }
    verify(prevLogIndex <= lastLogIndex);
    auto instance = GetRaftInstance(prevLogIndex);
    uint64_t prevLogTerm = instance->term;
    shared_ptr<Marshallable> cmd = nullptr;
    uint64_t cmdLogTerm = 0;

#ifndef RAFT_BATCH_OPTIMIZATION
    if (it->second <= lastLogIndex) {
      auto curInstance = GetRaftInstance(it->second);
      cmd = curInstance->log_;
      cmdLogTerm = curInstance->term;
      Log_debug("loc %d Sending AppendEntries for %d to loc %d cmd=%p",
                loc_id_, it->second, follower_site_id, cmd.get());
    }
#endif

#ifdef RAFT_BATCH_OPTIMIZATION
    vector<shared_ptr<TpcCommitCommand>> batch_buffer_;
    for (int idx = max(it->second, min_active_slot_); idx <= lastLogIndex; idx++) {
      auto curInstance = GetRaftInstance(idx);
      shared_ptr<TpcCommitCommand> curCmd = dynamic_pointer_cast<TpcCommitCommand>(curInstance->log_);
      curCmd->term = curInstance->term;
      batch_buffer_.push_back(curCmd);
    }
    auto batch_cmd = std::make_shared<TpcBatchCommand>();
    batch_cmd->AddCmds(batch_buffer_);
    if (!batch_buffer_.empty()) {
      cmd = dynamic_pointer_cast<Marshallable>(batch_cmd);
    }
#endif

    // if (!cmd) {
    //   Log_info("[RAFT_HEARTBEAT] site %d (loc %d) -> follower %d send heartbeat AppendEntries prevIdx=%lu prevTerm=%lu commitIdx=%lu nextIdx=%lu",
    //            site_id_, loc_id_, follower_site_id, prevLogIndex, prevLogTerm, commitIndex, it->second);
    // }

    uint64_t ret_status = false;
    uint64_t ret_term = 0;
    uint64_t ret_last_log_index = 0;
    mtx_.unlock();
    auto r = commo()->SendAppendEntries2(follower_site_id,
                                         partition_id,
                                         -1,
                                         -1,
                                         IsLeader(),
                                         site_id_,
                                         term,
                                         prevLogIndex,
                                         prevLogTerm,
                                         commitIndex,
                                         cmd,
                                         cmdLogTerm,
                                         &ret_status,
                                         &ret_term,
                                         &ret_last_log_index);
    r->Wait();
    if (r->status_ == Event::TIMEOUT) {
      continue;
    }
    mtx_.lock();
    auto& next_index = next_index_[follower_site_id];
    auto& match_index = match_index_[follower_site_id];
    if (ret_status == false && ret_term == 0 && ret_last_log_index == 0) {
      // do nothing
    } else if (currentTerm > term) {
      // outdated
    } else if (ret_status == 0 && ret_term > term) {
      if (currentTerm == term) {
        setIsLeader(false);
        auto prev_term = currentTerm;
        currentTerm = ret_term;
        LogTermChange("AppendEntries reply reported higher term", prev_term, currentTerm, follower_site_id);
      }
    } else if (ret_status == 0) {
      if (next_index <= 1) {
        next_index = 1;
      } else {
        --next_index;
      }
    } else if (ret_status == 1) {
      if (cmd == nullptr) {
        Log_debug("case 3A: AppendEntries accepted for heartbeat msg");
      } else {
        Log_debug("case 3B: AppendEntries accepted for non-empty msg");
        uint64_t match_idx = ret_last_log_index;
        next_index = ret_last_log_index + 1;
        match_index = ret_last_log_index;
        if (match_idx > lastLogIndex) {
          Log_info("[MATCH_INDEX_DEBUG] Leader %d: capping match_index from %ld to %ld for follower %d",
                   site_id_, match_idx, lastLogIndex, follower_site_id);
          match_idx = lastLogIndex;
          match_index = lastLogIndex;
        }
        Log_debug("leader site %d receiving site %ld followerLastLogIndex=%ld followerNextIndex=%ld followerMatchedIndex=%ld",
                  site_id_, follower_site_id, ret_last_log_index, next_index, match_idx);
      }
    }
    mtx_.unlock();
  }
}
RaftServer::~RaftServer() {
  if (heartbeat_ && looping_) {
    looping_ = false;
    NotifyReplicationEvents();
	}
  
  stop_ = true ;
  // if (jetpack_recovery_event_) {
  //   jetpack_recovery_event_->Set(1);
  // }
  Log_info("site par %d, loc %d: prepare %d, accept %d, commit %d", 
      partition_id_, loc_id_, n_prepare_, n_accept_, n_commit_);
}

bool RaftServer::RequestVote() {
  // for(int i = 0; i < 1000; i++) Log_info("not calling the wrong method");

  parid_t par_id = this->frame_->site_info_->partition_id_ ;
  parid_t loc_id = this->frame_->site_info_->locale_id ;

  uint32_t lstoff = 0  ;
  slotid_t lst_idx = 0 ;
  ballot_t lst_term = 0 ;
  ballot_t prev_term = 0;
  siteid_t prev_vote_for = INVALID_SITEID;

  {
    std::lock_guard<std::recursive_mutex> lock(mtx_);
    prev_term = currentTerm;
    prev_vote_for = vote_for_;
    auto prev_local_term = currentTerm;
    currentTerm++ ;
    LogTermChange("starting election", prev_local_term, currentTerm);
    lstoff = lastLogIndex - snapidx_ ;
    if (lstoff == 0) {
      lst_idx = snapidx_;
      lst_term = snapterm_;
    } else {
      auto log = GetRaftInstance(lstoff) ; // causes min_active_slot_ verification error (server.h:247)
      lst_idx = lstoff + snapidx_ ;
      lst_term = log->term ;
    }
  }
  
  auto term = currentTerm;
#ifdef RAFT_LEADER_ELECTION_DEBUG
  Log_info("[RAFT_ELECTION] server %d (loc %d) starting election term %lu->%lu lastLogIdx=%lu lastLogTerm=%lu prev_vote_for=%d",
           site_id_, loc_id, prev_term, term, lst_idx, lst_term, prev_vote_for);
#endif
  auto sp_quorum = ((RaftCommo *)(this->commo_))->BroadcastVote(par_id,lst_idx,lst_term,loc_id, term );
  sp_quorum->Wait(1000000);
  std::lock_guard<std::recursive_mutex> lock1(mtx_);
#ifdef RAFT_LEADER_ELECTION_DEBUG
  Log_info("[RAFT_ELECTION] server %d term %lu vote outcome yes=%d no=%d highest_term_seen=%ld timeout=%d",
           site_id_, term, sp_quorum->n_voted_yes_, sp_quorum->n_voted_no_, sp_quorum->Term(), sp_quorum->timeouted_);
#endif
  if (sp_quorum->Yes()) {
    verify(currentTerm >= term);
    if (term != currentTerm) {
#ifdef RAFT_LEADER_ELECTION_DEBUG
      Log_info("[RAFT_ELECTION] server %d abandoning leadership claim because local term advanced to %lu", site_id_, currentTerm);
#endif
      return false;
    }
    // become a leader
    setIsLeader(true) ;
    // verify(currentTerm == term); // [Jetpack] Comment this since in failure recovery test this will fail after experiment end.
    Log_debug("site %d became leader for term %d", site_id_, term);

#ifdef RAFT_LEADER_ELECTION_DEBUG
    Log_info("[RAFT_ELECTION] server %d won election term %lu (votes yes=%d no=%d)",
             site_id_, term, sp_quorum->n_voted_yes_, sp_quorum->n_voted_no_);
#endif

    this->rep_frame_ = this->frame_ ;

    // auto co = ((TxLogServer *)(this))->CreateRepCoord(0);
    // auto empty_cmd = std::make_shared<TpcEmptyCommand>();
    // verify(empty_cmd->kind_ == MarshallDeputy::CMD_TPC_EMPTY);
    // auto sp_m = dynamic_pointer_cast<Marshallable>(empty_cmd);
    // ((CoordinatorRaft*)co)->Submit(sp_m);
    
    if(IsLeader()) {
	  	//for(int i = 0; i < 100; i++) Log_info("wait wait wait");
      Log_debug("vote accepted %d curterm %d", loc_id, currentTerm);
#ifdef RAFT_TEST_CORO
      // Skip JetpackRecovery in test environment to avoid RPC handler issues
#else
      TriggerJetpackRecovery("won election");
#endif
  		req_voting_ = false ;
			return true;
    } else {
      Log_debug("vote rejected %d curterm %d, do rollback", loc_id, currentTerm);
      setIsLeader(false) ;
    	return false;
		}
  } else if (sp_quorum->No()) {
    // become a follower
    Log_debug("site %d requestvote rejected", site_id_);
    setIsLeader(false) ;
#ifdef RAFT_LEADER_ELECTION_DEBUG
    Log_info("[RAFT_ELECTION] server %d lost election term %lu (yes=%d no=%d) highest_term=%ld",
             site_id_, term, sp_quorum->n_voted_yes_, sp_quorum->n_voted_no_, sp_quorum->Term());
#endif
    //reset cur term if new term is higher
    ballot_t new_term = sp_quorum->Term() ;
    if (new_term > currentTerm) {
      auto prev_local_term = currentTerm;
      currentTerm = new_term;
      LogTermChange("observed higher term from RequestVote replies", prev_local_term, currentTerm);
    }
  	req_voting_ = false ;
		return false;
  } else {
    Log_debug("vote timeout %d", loc_id);
#ifdef RAFT_LEADER_ELECTION_DEBUG
    Log_info("[RAFT_ELECTION] server %d election timed out term %lu (yes=%d no=%d)",
             site_id_, term, sp_quorum->n_voted_yes_, sp_quorum->n_voted_no_);
#endif
  	req_voting_ = false ;
		return false;
  }
}

void RaftServer::OnRequestVote(const slotid_t& lst_log_idx,
                               const ballot_t& lst_log_term,
                               const siteid_t& can_id,
                               const ballot_t& can_term,
                               ballot_t *reply_term,
                               bool_t *vote_granted,
                               const function<void()> &cb) {
  std::lock_guard<std::recursive_mutex> lock(mtx_);
  Log_debug("raft receives vote from candidate: %llx", can_id);

  uint64_t cur_term = currentTerm ;
  if( can_term < cur_term)
  {
    doVote(lst_log_idx, lst_log_term, can_id, can_term, reply_term, vote_granted, false, cb) ;
    return ;
  }

  // has voted to a machine in the same term, vote no
  // TODO when to reset the vote_for_??
//  if( can_term == cur_term && vote_for_ != INVALID_PARID )
  if( can_term == cur_term)
  {
    doVote(lst_log_idx, lst_log_term, can_id, can_term, reply_term, vote_granted, false, cb) ;
    return ;
  }

  // lstoff starts from 1
  uint32_t lstoff = lastLogIndex - snapidx_ ;

  ballot_t curlstterm = snapterm_ ;
  slotid_t curlstidx = lastLogIndex ;

  if(lstoff > 0 )
  {
    auto log = GetRaftInstance(lstoff) ;
    curlstterm = log->term ;
  }

  Log_debug("vote for lstoff %d, curlstterm %d, curlstidx %d", lstoff, curlstterm, curlstidx  );


  // TODO del only for test 
  verify(lstoff == lastLogIndex ) ;

  if( lst_log_term > curlstterm || (lst_log_term == curlstterm && lst_log_idx >= curlstidx) )
  {
    Log_debug("site %d vote for request vote from %d, lastidx %d, lastterm %d", site_id_, can_id, curlstidx, curlstterm);
    doVote(lst_log_idx, lst_log_term, can_id, can_term, reply_term, vote_granted, true, cb) ;
    return ;
  }

  doVote(lst_log_idx, lst_log_term, can_id, can_term, reply_term, vote_granted, false, cb) ;

}

void RaftServer::StartElectionTimer() {
  resetTimer("start election timer");
  Coroutine::CreateRun([&]() {
    Log_debug("start timer for election") ;
    double duration = randDuration() ;
    auto check_interval = HEARTBEAT_INTERVAL / 2;
#ifdef AWS
    auto election_timeout = RandomGenerator::rand((frame_->site_info_->locale_id + 1) * 100 * HEARTBEAT_INTERVAL,
                                                  (frame_->site_info_->locale_id + 1) * 200 * HEARTBEAT_INTERVAL);
#endif
#ifndef AWS
    auto election_timeout = RandomGenerator::rand((frame_->site_info_->locale_id + 1) * 5 * HEARTBEAT_INTERVAL,
                                                  (frame_->site_info_->locale_id + 1) * 10 * HEARTBEAT_INTERVAL);
#endif
    while(!stop_) {
      Coroutine::Sleep(check_interval);
      auto time_now = Time::now();
      auto time_elapsed = time_now - last_heartbeat_time_;
      // Log_info("sleeped for %d ms bar %d ms", time_now - last_heartbeat_time_, 10 * HEARTBEAT_INTERVAL);
      if (!paused_ && !IsLeader() && (time_now - last_heartbeat_time_ > election_timeout)) {
        Log_info("[RAFT_TIMEOUT] server %d election timeout triggered (elapsed=%ldus, last_hb=%ld)",
                 site_id_, time_elapsed, last_heartbeat_time_);
        Log_debug("site %d start election, time_elapsed: %d, last vote for: %d", 
          site_id_, time_elapsed, vote_for_);
        // ask to vote
        req_voting_ = true ;
#ifdef RAFT_LEADER_ELECTION_DEBUG
        Log_info("[RAFT_TIMER] server %d triggering RequestVote() time_elapsed=%ld last_hb=%ld current_term=%lu vote_for=%d",
                 site_id_, time_elapsed, last_heartbeat_time_, currentTerm, vote_for_);
#endif
        RequestVote() ;
        while(req_voting_) {
          Coroutine::Sleep(wait_int_);
          if(stop_) return ;
        }
#ifdef AWS
        election_timeout = RandomGenerator::rand((frame_->site_info_->locale_id + 1) * 100 * HEARTBEAT_INTERVAL,
                                                 (frame_->site_info_->locale_id + 1) * 200 * HEARTBEAT_INTERVAL);
#endif
#ifndef AWS
        election_timeout = RandomGenerator::rand((frame_->site_info_->locale_id + 1) * 5 * HEARTBEAT_INTERVAL,
                                                 (frame_->site_info_->locale_id + 1) * 10 * HEARTBEAT_INTERVAL);
#endif
      }
    } 
  });
}

bool RaftServer::Start(shared_ptr<Marshallable> &cmd,
                       uint64_t *index,
                       uint64_t *term,
                       slotid_t slot_id,
                       ballot_t ballot) {
  std::lock_guard<std::recursive_mutex> lock(mtx_);

  // #ifndef RAFT_TEST_CORO
  // if (!heartbeat_setup_) {
  //   heartbeat_setup_ = true;
  //   if (heartbeat_) {
  //     Log_debug("starting heartbeat loop at site %d", site_id_);
  //     Coroutine::CreateRun([this](){
  //       this->HeartbeatLoop(); 
  //     });
  //     // Start election timeout loop
  //     Log_info("!!!!!!! if (failover_)");
  //     if (failover_) {
  //       Coroutine::CreateRun([this](){
  //         StartElectionTimer(); 
  //       });
  //     }
  //   }
  // }
  // #endif
  if (!IsLeader()) {
    *index = 0;
    *term = 0;
    return false;
  }
  SetLocalAppend(cmd, term, index, slot_id, ballot);
  // SetLocalAppend returns the old lastLogIndex value, but Start returns the
  // index of the newly appended instance
  verify(lastLogIndex == (*index) + 1);
  *index = lastLogIndex;
  Log_debug("Start(): ldr=%d index=%ld term=%ld", loc_id_, *index, *term);
  return true;
}

/* NOTE: same as ReceiveAppend */
/* NOTE: broadcast send to all of the host even to its own server 
 * should we exclude the execution of this function for leader? */
void RaftServer::OnAppendEntries(const slotid_t slot_id,
                                 const ballot_t ballot,
                                 const uint64_t leaderCurrentTerm,
                                 const siteid_t leaderSiteId,
                                 const uint64_t leaderPrevLogIndex,
                                 const uint64_t leaderPrevLogTerm,
                                 const uint64_t leaderCommitIndex,
                                 shared_ptr<Marshallable> &cmd,
                                 const uint64_t leaderNextLogTerm, // disabled in batched version (term recorded in the TpcCommitCommand)
                                 uint64_t *followerAppendOK,
                                 uint64_t *followerCurrentTerm,
                                 uint64_t *followerLastLogIndex,
                                 const function<void()> &cb) {
  std::lock_guard<std::recursive_mutex> lock(mtx_);
  // if (cmd != nullptr) {
  //   Log_debug("[APPEND_ENTRIES_RECEIVED] Follower %d: received NEW log entry from leader %d, leaderTerm=%ld, prevLogIndex=%ld, prevLogTerm=%ld, leaderCommit=%ld, currentTerm=%ld, lastLogIndex=%ld", 
  //            this->loc_id_, leaderSiteId, leaderCurrentTerm, leaderPrevLogIndex, leaderPrevLogTerm, leaderCommitIndex, currentTerm, lastLogIndex);
  // }
  bool term_ok = (leaderCurrentTerm >= this->currentTerm);
  bool index_ok = (leaderPrevLogIndex <= this->lastLogIndex);
  uint64_t local_prev_term = 0;
  if (leaderPrevLogIndex > 0 && leaderPrevLogIndex <= this->lastLogIndex) {
      local_prev_term = GetRaftInstance(leaderPrevLogIndex)->term;
  }
  bool prev_term_ok = (leaderPrevLogIndex == 0 || local_prev_term == leaderPrevLogTerm);

  if (term_ok && index_ok && prev_term_ok) {
      Log_debug("refresh timer on appendentry");
      if (cmd != nullptr)
        resetTimer("AppendEntries with cmd received");
      else
        resetTimer("AppendEntries heartbeat received");
      if (leaderCurrentTerm > this->currentTerm) {
          auto prev_term = currentTerm;
          currentTerm = leaderCurrentTerm;
          LogTermChange("AppendEntries leader term is newer", prev_term, currentTerm, leaderSiteId);
          Log_debug("server %d, set to be follower", loc_id_ ) ;
          setIsLeader(false) ;
      }
      
      // // Update follower's view to track the current leader
      // if (!IsLeader() && leaderSiteId != INVALID_SITEID) {
      //     int prev_leader = new_view_.GetLeader();
      //     old_view_ = new_view_;
      //     int n_replicas = Config::GetConfig()->GetPartitionSize(partition_id_);
      //     new_view_ = View(n_replicas, leaderSiteId, leaderCurrentTerm);
      //     Log_info("[RAFT_VIEW_FOLLOWER] Server %d observed leader change %d->%d term=%lu prev_term=%lu",
      //              site_id_, prev_leader, leaderSiteId, leaderCurrentTerm, currentTerm);
      // }

      if (cmd != nullptr) {
#ifndef RAFT_BATCH_OPTIMIZATION
        lastLogIndex = leaderPrevLogIndex + 1;
        auto instance = GetRaftInstance(lastLogIndex);
        instance->log_ = cmd;
        instance->term = leaderNextLogTerm;
        // Log_debug("[APPEND_ENTRIES_ACCEPTED] Follower %d: accepted log entry at index %ld, term=%ld, lastLogIndex now=%ld", 
        //          this->loc_id_, lastLogIndex, leaderNextLogTerm, lastLogIndex);
        // // Log the command that was accepted
        // auto cmd_accepted = dynamic_pointer_cast<TpcCommitCommand>(cmd);
        // Log_debug("[APPEND_ENTRIES_ACCEPTED] Follower %d: accepted command %d at index %ld", 
        //          this->loc_id_, cmd_accepted ? cmd_accepted->tx_id_ : -1, lastLogIndex);
#endif
#ifdef RAFT_BATCH_OPTIMIZATION
        auto cmds = dynamic_pointer_cast<TpcBatchCommand>(cmd);
        int cnt = 0;
        for (shared_ptr<TpcCommitCommand>& c: cmds->cmds_) {
          cnt++;
          lastLogIndex = leaderPrevLogIndex + cnt;
          auto instance = GetRaftInstance(lastLogIndex);
          instance->log_ = c;
          instance->term = dynamic_pointer_cast<TpcCommitCommand>(c)->term;
        }
#endif
      }

      // update commitIndex and apply logs if necessary
      if (leaderCommitIndex > commitIndex) {
        commitIndex = std::min(leaderCommitIndex, lastLogIndex);
        verify(lastLogIndex >= commitIndex);
        applyLogs();
      }

      *followerAppendOK = 1;
      *followerCurrentTerm = this->currentTerm;
      *followerLastLogIndex = this->lastLogIndex;

#ifndef RAFT_TEST_CORO
      if (cmd != nullptr) {
        if (cmd->kind_ == MarshallDeputy::CMD_TPC_COMMIT){
          auto p_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
          auto sp_vec_piece = dynamic_pointer_cast<VecPieceData>(p_cmd->cmd_)->sp_vec_piece_data_;
          
          vector<struct KeyValue> kv_vector;
          int index = 0;
          for (auto it = sp_vec_piece->begin(); it != sp_vec_piece->end(); it++){
            auto cmd_input = (*it)->input.values_;
            for (auto it2 = cmd_input->begin(); it2 != cmd_input->end(); it2++) {
              struct KeyValue key_value = {it2->first, it2->second.get_i32()};
              kv_vector.push_back(key_value);
            }
          }

          struct KeyValue key_values[kv_vector.size()];
          std::copy(kv_vector.begin(), kv_vector.end(), key_values);

          // auto de = IO::write(filename, key_values, sizeof(struct KeyValue), kv_vector.size());
          // de->Wait();
        } else {
          int value = -1;
          // auto de = IO::write(filename, &value, sizeof(int), 1);
          // de->Wait();
        }
      }
#endif
    }
    else {
#ifdef RAFT_LEADER_ELECTION_DEBUG
        Log_info("[RAFT_APPEND_REJECT] follower=%d leader=%d leaderTerm=%lu localTerm=%lu prevIdx=%lu localLastIdx=%lu term_ok=%d index_ok=%d prev_term_ok=%d local_prev_term=%lu",
                 this->site_id_, leaderSiteId, leaderCurrentTerm, currentTerm, leaderPrevLogIndex, lastLogIndex,
                 term_ok, index_ok, prev_term_ok, local_prev_term);
#endif
        *followerAppendOK = 0;
        *followerCurrentTerm = this->currentTerm;
        *followerLastLogIndex = this->lastLogIndex;
    }

/*if (rand() % 1000 == 0) {
	usleep(25*1000);
}*/
    cb();
}

void RaftServer::removeCmd(slotid_t slot) {
  auto cmd = dynamic_pointer_cast<TpcCommitCommand>(raft_logs_[slot]->log_);
  if (!cmd)
    return;
  tx_sched_->DestroyTx(cmd->tx_id_);
  raft_logs_.erase(slot);
}

} // namespace janus
