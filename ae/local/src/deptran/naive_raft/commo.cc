#include "../__dep__.h"
#include "../constants.h"
#include "../communicator.h"
#include "../command_marshaler.h"
#include "../rcc_rpc.h"
#include "../RW_command.h"
#include "../config.h"
#include "commo.h"

namespace janus {

shared_ptr<QuorumEvent>
NaiveRaftStartReplicate(Communicator* commo,
                        parid_t par_id,
                        locid_t leader_loc_id,
                        int64_t cmd_id,
                        const MarshallDeputy& md) {
  verify(commo != nullptr);
  auto it = commo->rpc_par_proxies_.find(par_id);
  verify(it != commo->rpc_par_proxies_.end());
  auto& partition_proxies = it->second;
  auto config = Config::GetConfig();

  // leader counts itself as 1; 3/5 simple majority needs 2 follower acks.
  const int kFollowerQuorum = 2;
  const int kNumFollowers = static_cast<int>(partition_proxies.size()) - 1;
  verify(kNumFollowers >= kFollowerQuorum);

  auto e = Reactor::CreateSpEvent<QuorumEvent>(kNumFollowers, kFollowerQuorum);

  DepId di;
  di.str = "nr_replicate";
  di.id = Communicator::global_id++;

  WAN_WAIT;
  for (auto& pair : partition_proxies) {
    auto& site = config->SiteById(pair.first);
    if ((locid_t) site.locale_id == leader_loc_id) {
      continue;  // skip self
    }
    rrr::FutureAttr fuattr;
    fuattr.callback = [e](Future* fu) {
      if (fu->get_error_code() != 0) {
        return;
      }
      int32_t ret;
      TxnOutput outputs;
      uint64_t coro_id = 0;
      MarshallDeputy view_md;
      fu->get_reply() >> ret >> outputs >> coro_id >> view_md;
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
