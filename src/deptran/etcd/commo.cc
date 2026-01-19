#include "commo.h"

namespace janus {

EtcdCommo::EtcdCommo(PollMgr* poll) : Communicator(poll) {
}

void EtcdCommo::BroadcastCommit(const parid_t par_id,
                                const shared_ptr<Marshallable> cmd) {
  auto proxies = rpc_par_proxies_[par_id];
  for (auto& p : proxies) {
    auto proxy = (EtcdProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [](Future* fu) {};
    MarshallDeputy md(cmd);
    auto f = proxy->async_Commit(md, fuattr);
    Future::safe_release(f);
  }
}

} // namespace janus
