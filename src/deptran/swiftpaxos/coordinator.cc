#include "../__dep__.h"
#include "../constants.h"
#include "coordinator.h"
#include "commo.h"
#include "server.h"
#include "../config.h"
#include "../command_marshaler.h"
#include "../RW_command.h"

namespace janus {

SwiftPaxosCoordinator::SwiftPaxosCoordinator(uint32_t coo_id,
                                             int32_t benchmark,
                                             ClientControlServiceImpl* ccsi,
                                             uint32_t thread_id)
    : Coordinator(coo_id, benchmark, ccsi, thread_id) {
}

void SwiftPaxosCoordinator::Submit(shared_ptr<Marshallable>& cmd,
                                   const function<void()>& func,
                                   const function<void()>& exe_callback) {
  committed_ = false;
  commit_callback_ = func;

  auto cmd_id = SimpleRWCommand::GetCombinedCmdID(cmd);

  // Diagnostic: log first 5 submits per coordinator to confirm path.
  static thread_local int submit_log_count = 0;
  if (submit_log_count < 5) {
    Log_info("[SP-COORD-SUBMIT] coo_id=%d loc_id=%d cmd_id=%llu",
             (int)coo_id_, (int)loc_id_, (unsigned long long)cmd_id);
    submit_log_count++;
  }

  // Register commit callback on the local server's descriptor.
  // The local server will commit once it receives enough FastAcks/SlowAcks
  // from the other replicas (real inter-replica ack exchange).
  auto& desc = svr_->cmd_descs_[cmd_id];
  desc.commit_callback = [this]() {
    committed_ = true;
    if (commit_callback_) {
      commit_callback_();
    }
  };

  // Broadcast SwiftPropose to all replicas. Each replica's service handler
  // will call OnPropose, which triggers its own conflict check and
  // broadcasts its own FastAck/SlowAck to all other replicas.
  auto commo = (SwiftPaxosCommo*)commo_;
  auto& proxies = commo->rpc_par_proxies_[par_id_];
  for (auto& p : proxies) {
    auto proxy = (SwiftPaxosServiceProxy*)p.second;
    MarshallDeputy md(cmd);
    auto fu = proxy->async_SwiftPropose(md);
    Future::safe_release(fu);
  }
  // The coordinator's job ends here. Commit happens asynchronously when
  // the local server's ack counter reaches the fast quorum (FQ) or slow
  // quorum (SQ) via acks received from other replicas.
}

} // namespace janus
