#include "../__dep__.h"
#include "../constants.h"
#include "frame.h"
#include "coordinator.h"
#include "server.h"
#include "service.h"
#include "commo.h"

namespace janus {

REG_FRAME(MODE_EPAXOS_CORRECTED, vector<string>({"epaxos_corrected"}), EPaxosCFrame);

Executor* EPaxosCFrame::CreateExecutor(cmdid_t cmd_id, TxLogServer* sched) {
  return nullptr;  // EPaxos uses SCC-based execution, not standard Executor
}

Coordinator* EPaxosCFrame::CreateCoordinator(cooid_t coo_id,
                                              Config* config,
                                              int benchmark,
                                              ClientControlServiceImpl* ccsi,
                                              uint32_t id,
                                              shared_ptr<TxnRegistry> txn_reg) {
  verify(config != nullptr);
  auto* coo = new EPaxosCCoordinator(coo_id, benchmark, ccsi, id);
  coo->frame_ = this;
  verify(commo_ != nullptr);
  coo->commo_ = commo_;
  verify(svr_ != nullptr);
  coo->svr_ = this->svr_;
  coo->n_replica_ = config->GetPartitionSize(site_info_->partition_id_);
  coo->loc_id_ = this->site_info_->locale_id;
  verify(coo->n_replica_ != 0);
  Log_debug("create new EPaxos coordinator, coo_id: %d", (int)coo->coo_id_);
  return coo;
}

TxLogServer* EPaxosCFrame::CreateScheduler() {
  if (svr_ == nullptr) {
    svr_ = new EPaxosCServer(this);
  } else {
    verify(0);
  }
  Log_debug("create new EPaxos server loc: %d", this->site_info_->locale_id);
  return svr_;
}

Communicator* EPaxosCFrame::CreateCommo(PollMgr* poll) {
  if (commo_ == nullptr) {
    commo_ = new EPaxosCCommo(poll);
  }
  return commo_;
}

vector<rrr::Service*>
EPaxosCFrame::CreateRpcServices(uint32_t site_id,
                                 TxLogServer* rep_sched,
                                 rrr::PollMgr* poll_mgr,
                                 ServerControlServiceImpl* scsi) {
  auto result = std::vector<rrr::Service*>();
  result.push_back(new EPaxosCServiceImplC(rep_sched));
  return result;
}

} // namespace janus
