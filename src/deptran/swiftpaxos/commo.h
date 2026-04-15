#pragma once

#include "../__dep__.h"
#include "../communicator.h"

namespace janus {

class SwiftPaxosCommo : public Communicator {
 public:
  SwiftPaxosCommo(PollMgr* poll = nullptr) : Communicator(poll) {}

  // TODO: broadcast methods for fast ack, slow ack, etc. (Phase 2.3/2.4)
};

} // namespace janus
