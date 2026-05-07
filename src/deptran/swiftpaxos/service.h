#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../rcc_rpc.h"
#include "../RW_command.h"
#include "server.h"

namespace janus {

class SwiftPaxosServiceImplC : public SwiftPaxosServiceService {
 public:
  SwiftPaxosServer* svr_;
  SwiftPaxosServiceImplC(TxLogServer* sched)
      : svr_(dynamic_cast<SwiftPaxosServer*>(sched)) {}

  void SwiftPropose(const MarshallDeputy& cmd,
                    rrr::i32* res,
                    rrr::DeferredReply* defer) override {
    Coroutine::CreateRun([this, &cmd, res, defer]() {
      auto sp_cmd = const_cast<MarshallDeputy&>(cmd).sp_data_;
      svr_->OnPropose(sp_cmd, nullptr);
      *res = 0;
      defer->reply();
    });
  }

  void SwiftFastAck(const siteid_t& replica,
                    const ballot_t& ballot,
                    const rrr::i64& cmd_id,
                    const rrr::i32& key,
                    const rrr::i64& seqnum,
                    const std::vector<rrr::i64>& dep,
                    rrr::i32* res,
                    rrr::DeferredReply* defer) override {
    SwiftAck ack;
    ack.replica = replica;
    ack.ballot = ballot;
    ack.cmd_id = cmd_id;
    ack.seqnum = seqnum;
    ack.is_slow = false;
    ack.dep.assign(dep.begin(), dep.end());
    svr_->OnFastAck(ack);
    *res = 0;
    defer->reply();
  }

  // Light slow-ack handler (matches IMDEA's handleLightSlowAck). The wire
  // message carries no dep; the leader's authoritative dep was already set
  // when the leader's SwiftFastAck arrived.
  void SwiftSlowAck(const siteid_t& replica,
                    const ballot_t& ballot,
                    const rrr::i64& cmd_id,
                    rrr::i32* res,
                    rrr::DeferredReply* defer) override {
    svr_->OnLightSlowAck(replica, ballot, cmd_id);
    *res = 0;
    defer->reply();
  }

  void SwiftNewLeader(const siteid_t& replica,
                      const ballot_t& ballot,
                      rrr::i32* res,
                      rrr::DeferredReply* defer) override {
    svr_->OnNewLeaderRecv(replica, ballot);
    *res = 0;
    defer->reply();
  }

  void SwiftNewLeaderAck(const siteid_t& replica,
                         const ballot_t& ballot,
                         const ballot_t& cballot,
                         const MarshallDeputy& cmd_states,
                         rrr::i32* res,
                         rrr::DeferredReply* defer) override {
    auto state = std::dynamic_pointer_cast<SwiftRecoveryState>(
        cmd_states.sp_data_);
    svr_->OnNewLeaderAckRecv(replica, ballot, cballot, state);
    *res = 0;
    defer->reply();
  }

  void SwiftSync(const siteid_t& replica,
                 const ballot_t& ballot,
                 const MarshallDeputy& cmd_states,
                 rrr::i32* res,
                 rrr::DeferredReply* defer) override {
    auto state = std::dynamic_pointer_cast<SwiftRecoveryState>(
        cmd_states.sp_data_);
    svr_->OnSyncRecv(replica, ballot, state);
    *res = 0;
    defer->reply();
  }

  // Phase 4: batched ack handler. Unpacks the SwiftBatchedAcks payload and
  // dispatches each entry through the existing OnFastAck/OnLightSlowAck path
  // so the rest of the server doesn't have to know about batching.
  void SwiftAcks(const MarshallDeputy& batched_acks,
                 rrr::i32* res,
                 rrr::DeferredReply* defer) override {
    auto payload = std::dynamic_pointer_cast<SwiftBatchedAcks>(
        batched_acks.sp_data_);
    svr_->OnBatchedAcks(payload);
    *res = 0;
    defer->reply();
  }
};

} // namespace janus
