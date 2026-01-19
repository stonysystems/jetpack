#pragma once

#include "../communicator.h"

namespace janus {

class EtcdCommo : public Communicator {
 public:
  EtcdCommo() = delete;
  explicit EtcdCommo(PollMgr*);

  void BroadcastCommit(const parid_t par_id,
                       const shared_ptr<Marshallable> cmd);
};

} // namespace janus
