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
      auto cmd_id = SimpleRWCommand::GetCombinedCmdID(sp_cmd);
      auto key = SimpleRWCommand::GetKey(sp_cmd);
      bool has_conflict = svr_->HasConflict(key, cmd_id);
      svr_->OnPropose(sp_cmd, nullptr);
      *res = has_conflict ? 1 : 0;  // 0=fast ack, 1=slow ack
      defer->reply();
    });
  }

  void SwiftFastAck(const siteid_t& replica,
                    const ballot_t& ballot,
                    const rrr::i64& cmd_id,
                    const MarshallDeputy& dep,
                    const MarshallDeputy& checksum,
                    const rrr::i64& seqnum,
                    rrr::i32* res,
                    rrr::DeferredReply* defer) override {
    SwiftAck ack;
    ack.replica = replica;
    ack.ballot = ballot;
    ack.cmd_id = cmd_id;
    ack.seqnum = seqnum;
    ack.is_slow = false;
    svr_->OnFastAck(ack);
    *res = 0;
    defer->reply();
  }

  void SwiftSlowAck(const siteid_t& replica,
                     const ballot_t& ballot,
                     const rrr::i64& cmd_id,
                     rrr::i32* res,
                     rrr::DeferredReply* defer) override {
    SwiftAck ack;
    ack.replica = replica;
    ack.ballot = ballot;
    ack.cmd_id = cmd_id;
    ack.is_slow = true;
    svr_->OnSlowAck(ack);
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
    svr_->OnNewLeaderAckRecv(replica, ballot, cballot);
    *res = 0;
    defer->reply();
  }

  void SwiftSync(const siteid_t& replica,
                 const ballot_t& ballot,
                 const MarshallDeputy& cmd_states,
                 rrr::i32* res,
                 rrr::DeferredReply* defer) override {
    svr_->OnSyncRecv(replica, ballot);
    *res = 0;
    defer->reply();
  }
};

} // namespace janus
