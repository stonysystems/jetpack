#include "commo.h"
#include "../config.h"
#include "../command_marshaler.h"

namespace janus {

void SwiftPaxosCommo::BroadcastPropose(parid_t par_id,
                                        const shared_ptr<Marshallable>& cmd,
                                        const std::function<void(int, int, bool)>& cb) {
  auto config = Config::GetConfig();
  auto n = config->GetPartitionSize(par_id);
  auto proxies = rpc_par_proxies_[par_id];

  // Track acks across all replicas
  auto fast_acks = std::make_shared<int>(0);
  auto slow_acks = std::make_shared<int>(0);
  auto leader_acked = std::make_shared<bool>(false);
  auto replies_received = std::make_shared<int>(0);
  auto total_expected = std::make_shared<int>(proxies.size());

  for (auto& p : proxies) {
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    MarshallDeputy md(cmd);
    auto fu = proxy->async_SwiftPropose(md);

    Future::safe_release(fu);
    // For now, we count all proposals as fast acks
    // The actual ack collection happens at the server level
    (*fast_acks)++;
  }

  // In the current single-process model, all replicas see the propose
  // synchronously through the RPC handler. The callback is invoked
  // when the local server commits.
  // TODO: proper async ack collection (Phase 2.4 full implementation)
}

void SwiftPaxosCommo::BroadcastFastAck(parid_t par_id,
                                        siteid_t replica,
                                        ballot_t ballot,
                                        int64_t cmd_id,
                                        key_t key,
                                        int64_t seqnum) {
  auto proxies = rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    auto fu = proxy->async_SwiftFastAck(replica, ballot, cmd_id,
                                         (int32_t)key, seqnum);
    Future::safe_release(fu);
  }
}

} // namespace janus
