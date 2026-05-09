#pragma once

#include "__dep__.h"
#include "constants.h"
#include "server.h"
#include "commo.h"
#include "../coordinator.h"
#include "../zookeeper_kv_table_handler.h"

namespace janus {

class CoordinatorZookeeper : public Coordinator {

 public:
  CoordinatorZookeeper(uint32_t coo_id,
                       int32_t benchmark,
                       ClientControlServiceImpl *ccsi,
                       uint32_t thread_id)
      : Coordinator(coo_id, benchmark, ccsi, thread_id) {}
  ~CoordinatorZookeeper() {}
  ZookeeperCommo *commo() {
    verify(commo_ != nullptr);
    return (ZookeeperCommo *) commo_;
  }
  void DoTxAsync(TxRequest &req) override {}
  void Submit(shared_ptr<Marshallable> &cmd,
              const std::function<void()> &func = []() {},
              const std::function<void()> &exe_callback = []() {}) override;
  void Reset() override {}
  void Restart() override { verify(0); }
  ZookeeperServer* Server();
};

}
