#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../rcc_rpc.h"
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
      svr_->OnPropose(const_cast<MarshallDeputy&>(cmd).sp_data_);
      *res = 0;
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
    // TODO: deserialize dep, forward to server (Phase 2.3)
    *res = 0;
    defer->reply();
  }

  void SwiftSlowAck(const siteid_t& replica,
                     const ballot_t& ballot,
                     const rrr::i64& cmd_id,
                     rrr::i32* res,
                     rrr::DeferredReply* defer) override {
    // TODO: forward to server (Phase 2.3)
    *res = 0;
    defer->reply();
  }

  void SwiftNewLeader(const siteid_t& replica,
                      const ballot_t& ballot,
                      rrr::i32* res,
                      rrr::DeferredReply* defer) override {
    // TODO: forward to server (Phase 2.5)
    *res = 0;
    defer->reply();
  }

  void SwiftNewLeaderAck(const siteid_t& replica,
                         const ballot_t& ballot,
                         const ballot_t& cballot,
                         const MarshallDeputy& cmd_states,
                         rrr::i32* res,
                         rrr::DeferredReply* defer) override {
    // TODO: forward to server (Phase 2.5)
    *res = 0;
    defer->reply();
  }

  void SwiftSync(const siteid_t& replica,
                 const ballot_t& ballot,
                 const MarshallDeputy& cmd_states,
                 rrr::i32* res,
                 rrr::DeferredReply* defer) override {
    // TODO: forward to server (Phase 2.5)
    *res = 0;
    defer->reply();
  }
};

} // namespace janus
