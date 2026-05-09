#pragma once

#include "../communicator.h"

namespace janus {

class CommunicatorNaiveFastpath : public Communicator {
 public:
  using Communicator::Communicator;

  // Broadcast a Dispatch to all replicas in the partition. Returns a
  // QuorumEvent that is_ready() on 4/5 replies (RuleSuperMajority for
  // n=5 replicas, f=2). The caller should e->Wait() in a coroutine to
  // block until quorum; the 5th (and any later) reply is discarded
  // by the event's completion semantics.
  shared_ptr<QuorumEvent>
  BroadcastDispatchToAll(shared_ptr<vector<shared_ptr<TxPieceData>>> sp_vec_piece);
};

} // namespace janus
