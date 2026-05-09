#include "coordinator.h"
#include "../RW_command.h"
#include "../bench/rw/workload.h"
#include "server.h"

namespace janus {

ZookeeperServer* CoordinatorZookeeper::Server() {
  return (ZookeeperServer*)(commo_->rep_sched_);
}

void CoordinatorZookeeper::Submit(shared_ptr<Marshallable>& cmd,
                                   const function<void()>& func,
                                   const function<void()>& exe_callback) {
  Server()->Submit(cmd);
  commo()->BroadcastCommit(par_id_, cmd);
  func();
  exe_callback();
}


}
