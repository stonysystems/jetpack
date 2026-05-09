#pragma once

#include "../__dep__.h"
#include "../coordinator.h"

namespace janus {

class EPaxosCCommo;
class EPaxosCServer;

class EPaxosCCoordinator : public Coordinator {
 public:
  EPaxosCServer* svr_ = nullptr;
  uint32_t n_replica_ = 0;
  bool committed_ = false;

  EPaxosCCoordinator(uint32_t coo_id,
                     int32_t benchmark,
                     ClientControlServiceImpl* ccsi,
                     uint32_t thread_id);

  void DoTxAsync(TxRequest& req) override {}

  void Submit(shared_ptr<Marshallable>& cmd,
              const std::function<void()>& func = []() {},
              const std::function<void()>& exe_callback = []() {}) override;

  void Reset() override {}
  void Restart() override { verify(0); }
};

} // namespace janus
