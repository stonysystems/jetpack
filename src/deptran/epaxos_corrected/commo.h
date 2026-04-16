#pragma once

#include "../__dep__.h"
#include "../communicator.h"
#include "../rcc_rpc.h"

namespace janus {

class EPaxosCCommo : public Communicator {
 public:
  EPaxosCCommo(PollMgr* poll = nullptr) : Communicator(poll) {}

  // TODO: broadcast methods for PreAccept, Accept, Commit (Phase 3.3)
};

} // namespace janus
