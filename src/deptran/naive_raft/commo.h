#pragma once

#include "../__dep__.h"
#include "../constants.h"

namespace janus {

class Communicator;
class MarshallDeputy;
class QuorumEvent;

// naive_raft leader-side broadcast. Called from ClassicServiceImpl::Dispatch
// when this site is the fixed leader (locale_id=1 / zoo2). Fires async
// Dispatch RPCs to the 4 follower replicas with dep_id.str "nr_replicate"
// (a marker followers use to skip re-broadcasting). Returns immediately
// with a QuorumEvent the caller should Wait() on for 2/4 follower replies
// (3/5 simple majority counting self); late replies are drained and
// ignored by the event's completion semantics.
shared_ptr<QuorumEvent>
NaiveRaftStartReplicate(Communicator* commo,
                        parid_t par_id,
                        locid_t leader_loc_id,
                        int64_t cmd_id,
                        const MarshallDeputy& md);

} // namespace janus
