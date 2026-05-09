#pragma once

#include "../communicator.h"

namespace janus {

class ZookeeperCommo : public Communicator {
 public:
  ZookeeperCommo() = delete;
  ZookeeperCommo(PollMgr*);

  void BroadcastCommit(const parid_t par_id,
                        const shared_ptr<Marshallable> cmd);
};

} // namespace janus
