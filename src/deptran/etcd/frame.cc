#include "frame.h"
#include "coordinator.h"
#include "server.h"
#include "commo.h"
#include "service.h"

namespace janus {

REG_FRAME(MODE_ETCD, vector<string>({"etcd"}), EtcdFrame);

EtcdFrame::EtcdFrame(int mode) : Frame(mode) {
}

Coordinator *EtcdFrame::CreateCoordinator(cooid_t coo_id,
                                          Config *config,
                                          int benchmark,
                                          ClientControlServiceImpl *ccsi,
                                          uint32_t id,
                                          shared_ptr<TxnRegistry> txn_reg) {
  verify(config != nullptr);
  CoordinatorEtcd *coo;
  coo = new CoordinatorEtcd(coo_id,
                            benchmark,
                            ccsi,
                            id);
  coo->frame_ = this;
  verify(commo_ != nullptr);
  coo->commo_ = commo_;
  coo->loc_id_ = this->site_info_->locale_id;
  Log_debug("create new etcd coord, coo_id: %d", (int) coo->coo_id_);
  return coo;
}

TxLogServer *EtcdFrame::CreateScheduler() {
  TxLogServer *sch = nullptr;
  sch = new EtcdServer();
  sch->frame_ = this;
  return sch;
}

Communicator *EtcdFrame::CreateCommo(PollMgr *poll) {
  if (commo_ == nullptr) {
    commo_ = new EtcdCommo(poll);
  }
  return commo_;
}

vector<rrr::Service *>
EtcdFrame::CreateRpcServices(uint32_t site_id,
                             TxLogServer *rep_sched,
                             rrr::PollMgr *poll_mgr,
                             ServerControlServiceImpl *scsi) {
  auto config = Config::GetConfig();
  auto result = std::vector<Service *>();
  switch (config->replica_proto_) {
    case MODE_ETCD:result.push_back(new EtcdServiceImpl(rep_sched));
    default:break;
  }
  return result;
}


}
