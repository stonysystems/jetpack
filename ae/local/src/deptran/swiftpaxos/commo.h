#pragma once

#include "../__dep__.h"
#include "../communicator.h"
#include "../rcc_rpc.h"
#include "server.h"

namespace janus {

// SwiftPaxos uses the inherited Communicator's rpc_par_proxies_ directly
// from OnPropose to broadcast SwiftPropose + SwiftFastAck. No protocol-
// specific helper methods are needed here.
class SwiftPaxosCommo : public Communicator {
 public:
  SwiftPaxosCommo(PollMgr* poll = nullptr) : Communicator(poll) {}
};

} // namespace janus
