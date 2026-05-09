#include "../__dep__.h"
#include "../constants.h"
#include "service.h"
#include "../RW_command.h"
#include "commo.h"

namespace janus {

shared_ptr<QuorumEvent>
CommunicatorNaiveFastpath::BroadcastDispatchToAll(
    shared_ptr<vector<shared_ptr<TxPieceData>>> sp_vec_piece) {
  verify(!sp_vec_piece->empty());
  auto par_id = sp_vec_piece->at(0)->PartitionId();
  cmdid_t cmd_id = sp_vec_piece->at(0)->root_id_;

  auto sp_vpd = std::make_shared<VecPieceData>();
  sp_vpd->sp_vec_piece_data_ = sp_vec_piece;
  sp_vpd->time_sent_from_client_ = SimpleRWCommand::GetCurrentMsTime();
  MarshallDeputy md(sp_vpd);

  int n = rpc_par_proxies_[par_id].size();
  int quorum = SimpleRWCommand::RuleSuperMajority(n);  // 4 of 5 for n=5
  auto e = Reactor::CreateSpEvent<QuorumEvent>(n, quorum);

  DepId di;
  di.str = "dep";
  di.id = Communicator::global_id++;

  WAN_WAIT;
  for (auto& pair : rpc_par_proxies_[par_id]) {
    rrr::FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      if (fu->get_error_code() != 0) {
        // Missing a reply still lets the quorum complete once 4/5 arrive,
        // so just drop; don't vote.
        return;
      }
      // Drain the reply to keep marshaller state coherent.
      int32_t ret;
      TxnOutput outputs;
      uint64_t coro_id = 0;
      MarshallDeputy view_md;
      fu->get_reply() >> ret >> outputs >> coro_id >> view_md;
      // WAN_WAIT on reply path to mirror the one-way WAN delay that other
      // protocols' DispatchAck also applies (see CoordinatorClassic::DispatchAck).
      // Without this, naive_fastpath would measure 1x WAN RTT (20ms) instead
      // of the 2x the other protocols see (40ms), making comparison unfair.
      WAN_WAIT;
      e->VoteYes();
    };
    auto proxy = pair.second;
    auto future = proxy->async_Dispatch(cmd_id, di, md, fuattr);
    Future::safe_release(future);
  }
  return e;
}

} // namespace janus
