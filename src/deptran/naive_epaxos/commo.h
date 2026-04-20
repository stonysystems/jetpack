#pragma once

#include "../__dep__.h"
#include "../constants.h"

namespace janus {

class Communicator;
class MarshallDeputy;
class QuorumEvent;

// naive_epaxos leader-side broadcast. Unlike naive_raft, *every* server is
// a leader for its own co-located clients — so this is called from any
// server's Dispatch handler. Fires async Dispatch RPCs to the 4 other
// replicas with dep_id.str "ne_replicate" (followers use the marker to
// skip re-broadcasting). Returns immediately with a QuorumEvent the
// caller should Wait() on for 2/4 follower replies (3/5 simple majority
// counting self); late replies are drained and ignored by the event.
shared_ptr<QuorumEvent>
NaiveEpaxosStartReplicate(Communicator* commo,
                          parid_t par_id,
                          locid_t leader_loc_id,
                          int64_t cmd_id,
                          const MarshallDeputy& md);

} // namespace janus
