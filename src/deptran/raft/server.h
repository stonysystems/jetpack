#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../scheduler.h"
#include "../classic/tpc_command.h"
#include "commo.h"
#include <unordered_map>

namespace janus {
class Command;
class CmdData;

#define INVALID_SITEID  ((siteid_t)-1)
#define NUM_BATCH_TIMER_RESET  (100)
#define SEC_BATCH_TIMER_RESET  (1)

struct RaftData {
  ballot_t max_ballot_seen_ = 0;
  ballot_t max_ballot_accepted_ = 0;
  shared_ptr<Marshallable> accepted_cmd_{nullptr};
  shared_ptr<Marshallable> committed_cmd_{nullptr};

  ballot_t term;
  shared_ptr<Marshallable> log_{nullptr};

	//for retries
	ballot_t prevTerm;
	slotid_t slot_id;
	ballot_t ballot;
};

struct KeyValue {
	int key;
	i32 value;
};

#ifdef RAFT_TEST_CORO
#define HEARTBEAT_INTERVAL 100000
#else
#define HEARTBEAT_INTERVAL 5000
#endif

class RaftServer : public TxLogServer {
 private:
  std::map<siteid_t, uint64_t> match_index_{};
  std::map<siteid_t, uint64_t> next_index_{};
#ifdef RAFT_PIPELINE_OPTIMIZATION
  // Per-follower in-flight tracking for pipelined AppendEntries.
  // sent_index_[f]    = highest log index sent to f (optimistic send watermark;
  //                     advances ahead of next_index_ until the AE is acked).
  // in_flight_count_[f] = AEs sent to f for which we have not yet
  //                       processed a reply. Capped at kMaxInFlightPerFollower
  //                       to bound memory under follower stalls.
  std::map<siteid_t, uint64_t> sent_index_{};
  std::map<siteid_t, uint64_t> in_flight_count_{};
  // Bandwidth-delay product ceiling: cap >= offered_load * RTT. Sized
  // for AWS-WAN at 20k req/s with 200ms RTT (real round-trip), giving
  // 4000 + 2x headroom = 8000. The cap is a max, not a preallocation;
  // memory is only used when slots are actually filled.
  static constexpr uint64_t kMaxInFlightPerFollower = 8000;
#endif
  std::vector<std::thread> timer_threads_ = {};
  void timer_thread(bool *vote) ;
  Timer *timer_;
  uint64_t last_heartbeat_time_ = 0;
  void LogTermChange(const char* reason, uint64_t old_term, uint64_t new_term, siteid_t source = INVALID_SITEID);
  bool stop_ = false ;
  siteid_t vote_for_ = INVALID_SITEID ;
  bool init_ = false ;
  bool is_leader_ = false ;
  slotid_t snapidx_ = 0 ;
  ballot_t snapterm_ = 0 ;
  int32_t wait_int_ = 100000 ;
  bool disconnected_ = false;
  bool req_voting_ = false ;
  bool in_applying_logs_ = false ;
#ifdef RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH
  bool init_election_done_ = false;
  bool post_failure_election_done_ = false;
  bool failure_triggered_seen_ = false;
#endif
#ifdef RAFT_TEST_CORO
  bool failover_{true} ;
#else
  bool failover_{true} ;
#endif
  atomic<int64_t> counter_{0};
  const char *filename = "/db/data.txt";

  bool looping_ = false;
  bool heartbeat_ = true;
  bool heartbeat_setup_ = false;
	enum { STOPPED, RUNNING } status_;
  std::shared_ptr<IntEvent> jetpack_recovery_event_{nullptr};
  std::recursive_mutex jetpack_recovery_event_mtx_;
  int jetpack_recovery_pending_{0};
  bool jetpack_recovery_loop_started_{false};
  
	bool RequestVote() ;

	void Setup();
  void StartJetpackRecoveryLoop();
  void JetpackRecoveryLoop();
  void TriggerJetpackRecovery(const char* reason);
	void HeartbeatLoop(siteid_t follower_site_id);
  std::shared_ptr<IntEvent> CreateReplicationEvent(siteid_t follower_site_id);
  RaftCommo* commo() {
    return (RaftCommo*) commo_;
  }

  void doVote(const slotid_t& lst_log_idx,
              const ballot_t& lst_log_term,
              const siteid_t& can_id,
              const ballot_t& can_term,
              ballot_t *reply_term,
              bool_t *vote_granted,
              bool_t vote,
              const function<void()> &cb) {
      *vote_granted = vote ;
      *reply_term = currentTerm ;
#ifdef RAFT_LEADER_ELECTION_DEBUG
      siteid_t prev_vote_for = vote_for_;
      Log_info("[RAFT_VOTE] server %d (loc %d) vote=%d candidate=%d can_term=%lu cur_term=%lu prev_vote_for=%d is_leader=%d lst_idx=%lu lst_term=%lu",
               site_id_, loc_id_, vote, can_id, can_term, currentTerm, prev_vote_for, is_leader_, lst_log_idx, lst_log_term);
#endif
                    
      if( can_term > currentTerm)
      {
          // is_leader_ = false ;  // TODO recheck
          auto prev_term = currentTerm;
          currentTerm = can_term ;
          LogTermChange("vote request carried newer term", prev_term, currentTerm, can_id);
      }

      if(vote)
      {
          setIsLeader(false) ;
          vote_for_ = can_id ;
#ifdef RAFT_LEADER_ELECTION_DEBUG
          Log_info("[RAFT_VOTE] server %d recorded vote_for=%d at term=%lu", site_id_, vote_for_, currentTerm);
#endif
          //reset timeout
          resetTimer("granted vote");
      }
      n_vote_++ ;
      cb() ;
  }

  void applyLogs();

  void resetTimerBatch()
  {
    // Log_info("!!!!!!! if (!failover_)");
    if (!failover_) return ;
    auto cur_count = counter_++;
    if (cur_count > NUM_BATCH_TIMER_RESET ) {
      if (timer_->elapsed() > SEC_BATCH_TIMER_RESET) {
        resetTimer("batch timer adjustment");
      }
      counter_.store(0);
    }
  }
  void OnJetpackPullCmd(const epoch_t& jepoch,
                        const epoch_t& oepoch,
                        const std::vector<key_t>& keys,
                        bool_t* ok,
                        epoch_t* reply_jepoch,
                        epoch_t* reply_oepoch,
                        MarshallDeputy* reply_old_view,
                        MarshallDeputy* reply_new_view,
                        shared_ptr<KeyCmdBatchData>& batch) override;
  void OnJetpackPullRecovery(const MarshallDeputy& old_view,
                             const MarshallDeputy& new_view,
                             const epoch_t& jepoch,
                             const epoch_t& oepoch,
                             bool_t* ok,
                             epoch_t* reply_jepoch,
                             epoch_t* reply_oepoch,
                             MarshallDeputy* reply_old_view,
                             MarshallDeputy* reply_new_view,
                             shared_ptr<KeyCmdIdBatchData>& batch) override;
  void OnJetpackPrepare(const epoch_t& jepoch,
                        const epoch_t& oepoch,
                        const ballot_t& max_seen_ballot,
                        bool_t* ok,
                        epoch_t* reply_jepoch,
                        epoch_t* reply_oepoch,
                        MarshallDeputy* reply_old_view,
                        MarshallDeputy* reply_new_view,
                        ballot_t* reply_max_seen_ballot,
                        ballot_t* accepted_ballot,
                        int32_t* replied_sid) override;
  void OnJetpackAccept(const epoch_t& jepoch,
                       const epoch_t& oepoch,
                       const ballot_t& max_seen_ballot,
                       const int32_t& sid,
                       bool_t* ok,
                       epoch_t* reply_jepoch,
                       epoch_t* reply_oepoch,
                       MarshallDeputy* reply_old_view,
                       MarshallDeputy* reply_new_view,
                       ballot_t* reply_max_seen_ballot) override;
  void OnJetpackCommit(const epoch_t& jepoch,
                       const epoch_t& oepoch,
                       const int32_t& sid) override;

  void resetTimer(const char* reason = "unspecified") {
    const char* why = reason ? reason : "unspecified";
    // Log_info("[RAFT_TIMER] server %d (loc %d) reset election timer (%s) failover=%d is_leader=%d",
    //          site_id_, loc_id_, why, failover_, IsLeader());
    last_heartbeat_time_ = Time::now();
    // Log_info("!!!!!!! if (failover_)");
    if (failover_) {
      timer_->start() ;
    }
  }

  double randDuration() 
  {
    // election timeout between 0.4 and 0.7 seconds
    return RandomGenerator::rand_double(0.4, 0.7) ;
  }
#ifdef RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH
  void RefreshElectionSignalsLocked();
  void MarkElectionDoneLocked(bool after_failure);
#endif
 public:
  void NotifyReplicationEvents();
  slotid_t min_active_slot_ = 1; // anything before (lt) this slot is freed
  slotid_t max_executed_slot_ = 0;
  slotid_t max_committed_slot_ = 0;
  map<slotid_t, shared_ptr<RaftData>> logs_{};
  int n_vote_ = 0;
  int n_prepare_ = 0;
  int n_accept_ = 0;
  int n_commit_ = 0;

  /* NOTE: I think I should move these to the RaftData class */
  /* TODO: talk to Shuai about it */
  uint64_t lastLogIndex = 0;
  uint64_t currentTerm = 0;
  uint64_t commitIndex = 0;
  uint64_t executeIndex = 0;
  map<slotid_t, shared_ptr<RaftData>> raft_logs_{};
//  vector<shared_ptr<RaftData>> raft_logs_{};

  // Ready signals per follower for replication coroutines.
  std::recursive_mutex ready_for_replication_mtx_{};
  std::unordered_map<siteid_t, shared_ptr<IntEvent>> ready_for_replication_;

  // Read-lease state. Single-shard, leader-only. The lease is a
  // monotonic-clock deadline: while now < lease_expires_us_ AND
  // now >= leader_warmup_until_us_, the leader can serve linearizable
  // reads from its own state machine without a Raft round-trip.
  //
  // The lease anchor for a heartbeat round is the moment the leader sent
  // the AppendEntries to that follower; the conservative upper bound
  // for the lease is anchor + min_election_timeout - skew_budget. We
  // track per-follower send timestamps and pick the (n-1)/2-th most
  // recent (i.e. the time at which a quorum of followers have
  // definitely seen our heartbeat).
  std::unordered_map<siteid_t, int64_t> last_ae_send_us_;
  int64_t lease_expires_us_ = 0;
  int64_t leader_warmup_until_us_ = 0;
  // Read-lease duration. Must be larger than the per-AE round-trip so
  // that the lease window measured at lease-stamp time (which is
  // RTT after the anchor SEND) still has positive remaining
  // validity. Must also be smaller than the smallest follower election
  // timeout minus a clock-skew budget so that no follower can have
  // started an election by the time the leader is still serving lease
  // reads.
  //
  // Sized for AWS WAN: 2nd-fastest follower from California is
  // Frankfurt at ~154ms RTT. We need duration > commit-RTT for the
  // lease window to have positive overlap with the present after the
  // anchor's quorum-acks return. 250ms gives ~96ms of useful lease
  // window per refresh, while staying safely below the 500ms min
  // election timeout. (Old value 100ms was tuned for the zoo cluster
  // at ~40ms RTT and produced zero-width windows on AWS, making
  // HasReadLease() always false → V3-lease degraded to V1-raw.)
  static constexpr int64_t kReadLeaseDurationUs = 250000;
  static int64_t MonotonicNowUs();
  void RecomputeLeaseLocked();   // call with mtx_ held; updates lease_expires_us_
  // True iff the leader currently holds a valid read lease — i.e. the
  // warm-up window has elapsed since this server became leader, AND the
  // most recent quorum-confirmed heartbeat round's anchor + lease
  // duration has not yet expired. While true, the leader is the
  // unique leader of the partition (no other replica can have been
  // elected since the lease anchor), so a read served from local state
  // is linearizable.
  bool HasReadLease();

  void StartElectionTimer() ;
#ifdef RAFT_ELECTION_ONLY_INIT_AND_POST_FAILURE_ONCE_PATCH
  void Pause() override;
#endif

  bool IsLeader()
  {
    return is_leader_ ;
  }
  
  // Made public to allow Jetpack recovery to restore leader state
  void setIsLeader(bool isLeader);

  bool Start(shared_ptr<Marshallable> &cmd, uint64_t *index, uint64_t *term, slotid_t slot_id = -1, ballot_t ballot = 1);

  void GetState(bool *is_leader, uint64_t *term) {
    std::lock_guard<std::recursive_mutex> lock(mtx_);
    *is_leader = IsLeader();
    *term = currentTerm;
  }

  void SetLocalAppend(shared_ptr<Marshallable>& cmd, uint64_t* term, uint64_t* index, slotid_t slot_id = -1, ballot_t ballot = 1 ){
    std::lock_guard<std::recursive_mutex> lock(mtx_);
    *index = lastLogIndex ;
    lastLogIndex += 1;
    auto instance = GetRaftInstance(lastLogIndex);
    instance->log_ = cmd;
		instance->prevTerm = currentTerm;
    instance->term = currentTerm;
		instance->slot_id = slot_id;
		instance->ballot = ballot;

#ifndef RAFT_TEST_CORO
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
			
			struct timespec begin, end;
			//clock_gettime(CLOCK_MONOTONIC, &begin);
      // de->Wait();
			//clock_gettime(CLOCK_MONOTONIC, &end);
			//Log_info("Time of Write: %d", end.tv_nsec - begin.tv_nsec);
    } else {
			int value = -1;
			int value_;
			// auto de = IO::write(filename, &value, sizeof(int), 1);
			struct timespec begin, end;
			//clock_gettime(CLOCK_MONOTONIC, &begin);
      // de->Wait();
			//clock_gettime(CLOCK_MONOTONIC, &end);
			//Log_info("Time of Write: %d", end.tv_nsec - begin.tv_nsec);
    }
#endif
    *term = currentTerm ;
  }
  
  shared_ptr<RaftData> GetInstance(slotid_t id) {
    verify(id >= min_active_slot_ || lastLogIndex == 0);
    auto& sp_instance = logs_[id];
    if(!sp_instance)
      sp_instance = std::make_shared<RaftData>();
    return sp_instance;
  }

 /* shared_ptr<RaftData> GetRaftInstance(slotid_t id) {
    if ( id <= raft_logs_.size() )
    {
        return raft_logs_[id-1] ;
    }
    auto sp_instance = std::make_shared<RaftData>();
    raft_logs_.push_back(sp_instance) ;
    return sp_instance;
  }*/
   shared_ptr<RaftData> GetRaftInstance(slotid_t id) {
    verify(id >= min_active_slot_ || id == 0);
     auto& sp_instance = raft_logs_[id];
     if(!sp_instance)
       sp_instance = std::make_shared<RaftData>();
     return sp_instance;
   }


  RaftServer(Frame *frame) ;
  ~RaftServer() ;

  void OnRequestVote(const slotid_t& lst_log_idx,
                     const ballot_t& lst_log_term,
                     const siteid_t& can_id,
                     const ballot_t& can_term,
                     ballot_t *reply_term,
                     bool_t *vote_granted,
                     const function<void()> &cb) ;

  void OnAppendEntries(const slotid_t slot_id,
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
                       const function<void()> &cb);

  // Leader-side override of the Jetpack fast-path conflict check.
  // Iterates the small inflight_original_path_ map (maintained by
  // OriginalPathUnexecutedCmdConflictPlaceHolder / RuleCommandPoolGC)
  // and returns true if any unapplied original-path entry's key
  // conflicts with cmd (same key, at least one writer). Followers
  // fall back to the base no-op impl. Used when the
  // jetpack_skip_pool_for_original_path flag is on, in which case
  // the command pool only tracks fast-path attempts and original-path
  // commands have to be detected via this side-index instead.
  bool ConflictWithOriginalUnexecutedLog(const shared_ptr<Marshallable>& cmd) override;

  void Disconnect(const bool disconnect = true);

  void Reconnect() {
    Disconnect(false);
    resetTimer("reconnect");
  }

  bool IsDisconnected();

  virtual bool HandleConflicts(Tx& dtxn,
                               innid_t inn_id,
                               vector<string>& conflicts) {
    verify(0);
  };

  void removeCmd(slotid_t slot);
};
} // namespace janus
