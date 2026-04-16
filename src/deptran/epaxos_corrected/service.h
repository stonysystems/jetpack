#pragma once

#include "../__dep__.h"
#include "../constants.h"
#include "../rcc_rpc.h"
#include "../RW_command.h"
#include "server.h"

namespace janus {

class EPaxosCServiceImplC : public EPaxosCServiceService {
 public:
  EPaxosCServer* svr_;
  EPaxosCServiceImplC(TxLogServer* sched)
      : svr_(dynamic_cast<EPaxosCServer*>(sched)) {}

  void EPaxosCPreAccept(const siteid_t& leader,
                        const siteid_t& replica,
                        const rrr::i64& instance,
                        const ballot_t& ballot,
                        const MarshallDeputy& cmd,
                        const rrr::i32& seq,
                        const MarshallDeputy& deps,
                        rrr::i32* reply_status,
                        ballot_t* reply_ballot,
                        rrr::i32* reply_seq,
                        MarshallDeputy* reply_deps,
                        rrr::DeferredReply* defer) override {
    Coroutine::CreateRun([=, &cmd, &deps]() {
      auto sp_cmd = const_cast<MarshallDeputy&>(cmd).sp_data_;
      vector<int32_t> in_deps;  // TODO: deserialize deps
      vector<int32_t> out_deps;
      svr_->OnPreAccept(leader, replica, instance, ballot, sp_cmd,
                         seq, in_deps, reply_status, reply_ballot,
                         reply_seq, &out_deps);
      // TODO: serialize out_deps into reply_deps
      defer->reply();
    });
  }

  void EPaxosCAccept(const siteid_t& leader,
                     const siteid_t& replica,
                     const rrr::i64& instance,
                     const ballot_t& ballot,
                     const rrr::i32& seq,
                     const MarshallDeputy& deps,
                     rrr::i32* reply_status,
                     ballot_t* reply_ballot,
                     rrr::DeferredReply* defer) override {
    Coroutine::CreateRun([=, &deps]() {
      vector<int32_t> in_deps;  // TODO: deserialize
      svr_->OnAccept(leader, replica, instance, ballot, seq, in_deps,
                      reply_status, reply_ballot);
      defer->reply();
    });
  }

  void EPaxosCCommit(const siteid_t& leader,
                     const siteid_t& replica,
                     const rrr::i64& instance,
                     const ballot_t& ballot,
                     const MarshallDeputy& cmd,
                     const rrr::i32& seq,
                     const MarshallDeputy& deps,
                     rrr::DeferredReply* defer) override {
    Coroutine::CreateRun([=, &cmd, &deps]() {
      auto sp_cmd = const_cast<MarshallDeputy&>(cmd).sp_data_;
      vector<int32_t> in_deps;  // TODO: deserialize
      svr_->OnCommit(leader, replica, instance, ballot, sp_cmd, seq, in_deps);
      defer->reply();
    });
  }

  void EPaxosCPrepare(const siteid_t& leader,
                      const siteid_t& replica,
                      const rrr::i64& instance,
                      const ballot_t& ballot,
                      rrr::i32* reply_status,
                      ballot_t* reply_ballot,
                      ballot_t* reply_vbal,
                      MarshallDeputy* reply_cmd,
                      rrr::i32* reply_seq,
                      MarshallDeputy* reply_deps,
                      rrr::DeferredReply* defer) override {
    // TODO: recovery (Phase 3.5)
    *reply_status = 0;
    *reply_ballot = 0;
    *reply_vbal = 0;
    *reply_seq = 0;
    defer->reply();
  }

  void EPaxosCTryPreAccept(const siteid_t& leader,
                           const siteid_t& replica,
                           const rrr::i64& instance,
                           const ballot_t& ballot,
                           const MarshallDeputy& cmd,
                           const rrr::i32& seq,
                           const MarshallDeputy& deps,
                           rrr::i32* reply_status,
                           ballot_t* reply_ballot,
                           ballot_t* reply_vbal,
                           siteid_t* conflict_replica,
                           rrr::i64* conflict_instance,
                           rrr::i32* conflict_status,
                           rrr::DeferredReply* defer) override {
    // TODO: recovery (Phase 3.5)
    *reply_status = 0;
    *reply_ballot = 0;
    *reply_vbal = 0;
    *conflict_replica = 0;
    *conflict_instance = 0;
    *conflict_status = 0;
    defer->reply();
  }
};

} // namespace janus
