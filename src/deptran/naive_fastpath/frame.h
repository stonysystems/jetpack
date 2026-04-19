#pragma once

#include "../frame.h"

namespace janus {

// naive_fastpath frame: client broadcasts each Dispatch to all 5 replicas,
// server replies unconditionally, client commits on 4/5 (3f/2+1 for f=2).
//
// No replication, no consensus, no logging. Intended as a distributed-
// work baseline for protocols that rely on a broadcast + quorum (CURP,
// EPaxos, SwiftPaxos) so we can quantify how much of their cost is the
// broadcast pattern itself vs. the consensus bookkeeping layered on top.
class NaiveFastpathFrame : public Frame {
 public:
  NaiveFastpathFrame(int mode = MODE_NAIVE_FASTPATH) : Frame(mode) {}

  Coordinator* CreateCoordinator(cooid_t coo_id,
                                 Config* config,
                                 int benchmark,
                                 ClientControlServiceImpl* ccsi,
                                 uint32_t id,
                                 shared_ptr<TxnRegistry> txn_reg) override;

  TxLogServer* CreateScheduler() override;

  Communicator* CreateCommo(PollMgr* poll) override;

  std::vector<rrr::Service*>
  CreateRpcServices(uint32_t site_id,
                    TxLogServer* rep_sched,
                    rrr::PollMgr* poll_mgr,
                    ServerControlServiceImpl* scsi) override;
};

} // namespace janus
