#include "frame.h"
#include "coordinator.h"
#include "server.h"
#include "commo.h"
#include "service.h"

namespace janus {

REG_FRAME(MODE_ZOOKEEPER, vector<string>({"zookeeper"}), ZookeeperFrame);

ZookeeperFrame::ZookeeperFrame(int mode) : Frame(mode) {
}

Coordinator *ZookeeperFrame::CreateCoordinator(cooid_t coo_id,
                                                Config *config,
                                                int benchmark,
                                                ClientControlServiceImpl *ccsi,
                                                uint32_t id,
                                                shared_ptr<TxnRegistry> txn_reg) {
  verify(config != nullptr);
  CoordinatorZookeeper *coo;
  coo = new CoordinatorZookeeper(coo_id,
                                  benchmark,
                                  ccsi,
                                  id);
  coo->frame_ = this;
  verify(commo_ != nullptr);
  coo->commo_ = commo_;
  coo->loc_id_ = this->site_info_->locale_id;
  Log_debug("create new zookeeper coord, coo_id: %d", (int) coo->coo_id_);
  return coo;
}

TxLogServer *ZookeeperFrame::CreateScheduler() {
  TxLogServer *sch = nullptr;
  sch = new ZookeeperServer();
  sch->frame_ = this;
  return sch;
}

Communicator *ZookeeperFrame::CreateCommo(PollMgr *poll) {
  if (commo_ == nullptr) {
    commo_ = new ZookeeperCommo(poll);
  }
  return commo_;
}

vector<rrr::Service *>
ZookeeperFrame::CreateRpcServices(uint32_t site_id,
                                   TxLogServer *rep_sched,
                                   rrr::PollMgr *poll_mgr,
                                   ServerControlServiceImpl *scsi) {
  auto config = Config::GetConfig();
  auto result = std::vector<Service *>();
  switch (config->replica_proto_) {
    case MODE_ZOOKEEPER:result.push_back(new ZookeeperServiceImpl(rep_sched));
    default:break;
  }
  return result;
}


}
