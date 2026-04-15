#include "../__dep__.h"
#include "../constants.h"
#include "frame.h"
#include "coordinator.h"
#include "server.h"
#include "service.h"
#include "commo.h"

namespace janus {

REG_FRAME(MODE_SWIFTPAXOS, vector<string>({"swiftpaxos"}), SwiftPaxosFrame);

Executor* SwiftPaxosFrame::CreateExecutor(cmdid_t cmd_id, TxLogServer* sched) {
  // SwiftPaxos uses its own execution model, not the standard Executor
  // For now, return nullptr — commands are executed directly by the server
  return nullptr;
}

Coordinator* SwiftPaxosFrame::CreateCoordinator(cooid_t coo_id,
                                                Config* config,
                                                int benchmark,
                                                ClientControlServiceImpl* ccsi,
                                                uint32_t id,
                                                shared_ptr<TxnRegistry> txn_reg) {
  verify(config != nullptr);
  auto* coo = new SwiftPaxosCoordinator(coo_id, benchmark, ccsi, id);
  coo->frame_ = this;
  verify(commo_ != nullptr);
  coo->commo_ = commo_;
  verify(svr_ != nullptr);
  coo->svr_ = this->svr_;
  coo->n_replica_ = config->GetPartitionSize(site_info_->partition_id_);
  coo->loc_id_ = this->site_info_->locale_id;
  verify(coo->n_replica_ != 0);
  Log_debug("create new SwiftPaxos coordinator, coo_id: %d", (int)coo->coo_id_);
  return coo;
}

TxLogServer* SwiftPaxosFrame::CreateScheduler() {
  if (svr_ == nullptr) {
    svr_ = new SwiftPaxosServer(this);
  } else {
    verify(0);
  }
  Log_debug("create new SwiftPaxos server loc: %d", this->site_info_->locale_id);
  return svr_;
}

Communicator* SwiftPaxosFrame::CreateCommo(PollMgr* poll) {
  if (commo_ == nullptr) {
    commo_ = new SwiftPaxosCommo(poll);
  }
  return commo_;
}

vector<rrr::Service*>
SwiftPaxosFrame::CreateRpcServices(uint32_t site_id,
                                   TxLogServer* rep_sched,
                                   rrr::PollMgr* poll_mgr,
                                   ServerControlServiceImpl* scsi) {
  auto result = std::vector<rrr::Service*>();
  result.push_back(new SwiftPaxosServiceImplC(rep_sched));
  return result;
}

} // namespace janus
