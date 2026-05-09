#include "../__dep__.h"
#include "../constants.h"
#include "coordinator.h"
#include "commo.h"
#include "server.h"
#include "../config.h"

namespace janus {

EPaxosCCoordinator::EPaxosCCoordinator(uint32_t coo_id,
                                       int32_t benchmark,
                                       ClientControlServiceImpl* ccsi,
                                       uint32_t thread_id)
    : Coordinator(coo_id, benchmark, ccsi, thread_id) {
}

void EPaxosCCoordinator::Submit(shared_ptr<Marshallable>& cmd,
                                 const function<void()>& func,
                                 const function<void()>& exe_callback) {
  committed_ = false;
  commit_callback_ = func;

  // EPaxos: any replica can propose. The local server proposes the command.
  // In the simplified single-process model, OnPropose handles the full
  // PreAccept → fast/slow commit → execute flow internally.
  svr_->OnPropose(cmd, [this]() {
    committed_ = true;
    if (commit_callback_) {
      commit_callback_();
    }
  });
}

} // namespace janus
