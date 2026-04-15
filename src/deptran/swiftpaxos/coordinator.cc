#include "../__dep__.h"
#include "../constants.h"
#include "coordinator.h"
#include "commo.h"
#include "server.h"
#include "../config.h"

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
  // TODO: implement fast-path broadcast + FQ/SQ tracking (Phase 2.4)
  // For now, just call the commit callback to avoid hanging
  commit_callback_ = func;
  GotoNextPhase();
}

void SwiftPaxosCoordinator::GotoNextPhase() {
  // TODO: implement phase state machine (Phase 2.4)
  // For now, just complete immediately
  if (commit_callback_) {
    commit_callback_();
  }
}

} // namespace janus
