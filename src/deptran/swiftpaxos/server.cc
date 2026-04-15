#include "server.h"
#include "../config.h"

namespace janus {

SwiftPaxosServer::SwiftPaxosServer(Frame* frame)
    : TxLogServer() {
  auto config = Config::GetConfig();
  n_replica_ = config->GetPartitionSize(0);  // assume partition 0
  Log_info("[SwiftPaxos] Server created, n_replica=%d, loc_id=%d", n_replica_, loc_id_);
}

SwiftPaxosServer::~SwiftPaxosServer() {}

vector<uint64_t> SwiftPaxosServer::GetDeps(const shared_ptr<Marshallable>& cmd, uint64_t cmd_id) {
  // TODO: implement per-key dependency computation (Phase 2.3)
  return {};
}

void SwiftPaxosServer::OnPropose(const shared_ptr<Marshallable>& cmd) {
  // TODO: implement proposal handling (Phase 2.3)
}

void SwiftPaxosServer::OnFastAck(siteid_t replica, ballot_t ballot, int64_t cmd_id,
                                  const vector<uint64_t>& dep, int64_t seqnum) {
  // TODO: implement fast ack handling (Phase 2.3)
}

void SwiftPaxosServer::OnSlowAck(siteid_t replica, ballot_t ballot, int64_t cmd_id) {
  // TODO: implement slow ack handling (Phase 2.3)
}

void SwiftPaxosServer::OnNewLeader(siteid_t replica, ballot_t ballot) {
  // TODO: implement recovery (Phase 2.5)
}

void SwiftPaxosServer::OnSync(siteid_t replica, ballot_t ballot) {
  // TODO: implement recovery (Phase 2.5)
}

} // namespace janus
