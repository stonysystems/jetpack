#include "commo.h"

namespace janus {

MongodbCommo::MongodbCommo(PollMgr* poll) : Communicator(poll) {
//  verify(poll != nullptr);
}

void MongodbCommo::BroadcastCommit(const parid_t par_id,
                                    const shared_ptr<Marshallable> cmd) {
  auto proxies = rpc_par_proxies_[par_id];
  int n = proxies.size();
  
  for (auto& p : proxies) {
    auto proxy = (MongodbProxy*) p.second;
    FutureAttr fuattr;
    fuattr.callback = [](Future* fu) {};
    MarshallDeputy md(cmd);
    auto f = proxy->async_Commit(md, fuattr);
    Future::safe_release(f);
  }
}

}