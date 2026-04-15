#pragma once

#include "../__dep__.h"
#include "../communicator.h"
#include "../rcc_rpc.h"
#include "server.h"

namespace janus {

class SwiftPaxosCommo : public Communicator {
 public:
  SwiftPaxosCommo(PollMgr* poll = nullptr) : Communicator(poll) {}

  // Broadcast a propose to all replicas in the partition
  void BroadcastPropose(parid_t par_id,
                        const shared_ptr<Marshallable>& cmd,
                        const std::function<void(int fast_acks, int slow_acks, bool leader_acked)>& cb);

  // Broadcast fast ack to all replicas
  void BroadcastFastAck(parid_t par_id,
                        siteid_t replica,
                        ballot_t ballot,
                        int64_t cmd_id,
                        key_t key,
                        int64_t seqnum);
};

} // namespace janus
