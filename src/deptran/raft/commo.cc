
#include "commo.h"
#include "../rcc/graph.h"
#include "../rcc/graph_marshaler.h"
#include "../command.h"
#include "../procedure.h"
#include "../command_marshaler.h"
#include "../rcc_rpc.h"
#include "macros.h"

namespace janus {

RaftCommo::RaftCommo(PollMgr* poll) : Communicator(poll) {
//  verify(poll != nullptr);
}

shared_ptr<IntEvent>
RaftCommo::SendAppendEntries2(siteid_t site_id,
                             parid_t par_id,
                             slotid_t slot_id,
                             ballot_t ballot,
                             bool isLeader,
                             siteid_t leader_site_id,
                             uint64_t currentTerm,
                             uint64_t prevLogIndex,
                             uint64_t prevLogTerm,
                             uint64_t commitIndex,
                             shared_ptr<Marshallable> cmd,
                             uint64_t cmdLogTerm,
                             uint64_t* ret_status,
                             uint64_t* ret_term,
                             uint64_t* ret_last_log_index
                             ) {
  // verify(par_id == 0);                          
  auto ret = Reactor::CreateSpEvent<IntEvent>();
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
	WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first != site_id)
        continue;
		auto follower_id = p.first;
    auto proxy = (RaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [ret,ret_status,ret_term,ret_last_log_index](Future* fu) {
      if (fu->get_error_code() != 0) {
        Log_debug("AppendEntries reply error code: %d", fu->get_error_code());
        // Must still Set the event so the caller's Wait() returns —
        // otherwise pipelined spawned coros that get error replies at
        // shutdown block until their 60s timeout, multiplied by 8000
        // in-flight, can hang the binary's worker.WaitForShutdown phase
        // long enough that the binary exits without dumping CSV. Leave
        // ret_status/term/last_log_index at their zero defaults so the
        // existing "ret_status == 0 && ret_term == 0 && ret_last_log_index == 0"
        // branch in HeartbeatLoop handles it as a no-op.
        ret->Set(1);
        return;
      }
      fu->get_reply() >> *ret_status >> *ret_term >> *ret_last_log_index;
      ret->Set(1);
    };

    if (cmd == nullptr) {
      // send a heartbeat AppendEntries
      Log_debug("Heartbeat AppendEntries to site %d prevLogIndex=%ld", site_id, prevLogIndex);
      Call_Async(proxy, EmptyAppendEntries, slot_id,
                                            ballot,
                                            currentTerm,
                                            leader_site_id,
                                            prevLogIndex,
                                            prevLogTerm,
                                            commitIndex,
                                            fuattr);
    } else {
      // send a regular AppendEntries
      MarshallDeputy md(cmd);
      verify(md.sp_data_ != nullptr);

      Log_debug("AppendEntries to site %d for log index %d", site_id, prevLogIndex + 1);
      Call_Async(proxy, AppendEntries, slot_id,
                                       ballot,
                                       currentTerm,
                                       leader_site_id,
                                       prevLogIndex,
                                       prevLogTerm,
                                       commitIndex,
                                       md,
                                       cmdLogTerm,
                                       fuattr);
    }
  }
  return ret;
}

shared_ptr<SendAppendEntriesResults>
RaftCommo::SendAppendEntries(siteid_t site_id,
                             parid_t par_id,
                             slotid_t slot_id,
                             ballot_t ballot,
                             bool isLeader,
                             siteid_t leader_site_id,
                             uint64_t currentTerm,
                             uint64_t prevLogIndex,
                             uint64_t prevLogTerm,
                             uint64_t commitIndex,
                             shared_ptr<Marshallable> cmd,
                             uint64_t cmdLogTerm) {
  // verify(par_id == 0);                          
  auto res = std::make_shared<SendAppendEntriesResults>();
  auto proxies = rpc_par_proxies_[par_id];
  vector<Future*> fus;
	WAN_WAIT;
  for (auto& p : proxies) {
    if (p.first != site_id)
        continue;
		auto follower_id = p.first;
    auto proxy = (RaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [res, cmd](Future* fu) {
      if (fu->get_error_code() != 0) {
        Log_info("Get a error message in reply");
        return;
      }
      // std::lock_guard<std::recursive_mutex> lk(res->mtx);
      fu->get_reply() >> res->ok;
      fu->get_reply() >> res->followerTerm;
      fu->get_reply() >> res->followerLastLogIndex;
      res->empty = (cmd == nullptr);
      // false, 0, 0 is the return value reserved to simulate a lost RPC.
      // only set res->done if it's not a lost RPC
      if (res->ok == false && res->followerTerm == 0 && res->followerLastLogIndex == 0) {
        res->done = false;
      } else {
        res->done = true;
      }
    };

    if (cmd == nullptr) {
      // send a heartbeat AppendEntries
      Log_debug("Heartbeat AppendEntries to site %d prevLogIndex=%ld", site_id, prevLogIndex);
      Call_Async(proxy, EmptyAppendEntries, slot_id,
                                            ballot,
                                            currentTerm,
                                            leader_site_id,
                                            prevLogIndex,
                                            prevLogTerm,
                                            commitIndex,
                                            fuattr);
    } else {
      // send a regular AppendEntries
      MarshallDeputy md(cmd);
      verify(md.sp_data_ != nullptr);

      Log_debug("AppendEntries to site %d for log index %d", site_id, prevLogIndex + 1);
      Call_Async(proxy, AppendEntries, slot_id,
                                       ballot,
                                       currentTerm,
                                       leader_site_id,
                                       prevLogIndex,
                                       prevLogTerm,
                                       commitIndex,
                                       md,
                                       cmdLogTerm,
                                       fuattr);
    }
  }
  return res;
}

shared_ptr<RaftVoteQuorumEvent>
RaftCommo::BroadcastVote(parid_t par_id,
                         slotid_t lst_log_idx,
                         ballot_t lst_log_term,
                         siteid_t self_id,
                         ballot_t cur_term ) {
  int n = Config::GetConfig()->GetPartitionSize(par_id);
  auto e = Reactor::CreateSpEvent<RaftVoteQuorumEvent>(n, n/2);
  auto proxies = rpc_par_proxies_[par_id];
  WAN_WAIT;
  for (auto& p : proxies) {
    auto site_id = p.first;
    if (site_id == self_id) {
      continue;
    }
    auto proxy = (RaftProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      if (fu->get_error_code() != 0) {
        Log_info("Get a error message in reply");
        return;
      }
      ballot_t term = 0;
      bool_t vote = false ;
      fu->get_reply() >> term;
      fu->get_reply() >> vote ;
      e->FeedResponse(vote, term);
      // TODO add max accepted value.
    };
    Call_Async(proxy, Vote, lst_log_idx, lst_log_term, self_id, cur_term, fuattr);
  }
  return e;
}

} // namespace janus
