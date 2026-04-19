#include "../__dep__.h"
#include "../constants.h"
#include "service.h"
#include "../none/scheduler.h"
#include "frame.h"
#include "coordinator.h"
#include "commo.h"

namespace janus {

REG_FRAME(MODE_NAIVE_FASTPATH,
          std::vector<std::string>({"naive_fastpath"}),
          NaiveFastpathFrame);

Coordinator* NaiveFastpathFrame::CreateCoordinator(
    cooid_t coo_id,
    Config* config,
    int benchmark,
    ClientControlServiceImpl* ccsi,
    uint32_t id,
    shared_ptr<TxnRegistry> txn_reg) {
  auto coo = new CoordinatorNaiveFastpath(coo_id, benchmark, ccsi, id);
  coo->frame_ = this;
  coo->txn_reg_ = txn_reg;
  return coo;
}

// Server-side: reuse SchedulerNone. Its Dispatch just executes the R/W
// piece and invokes OnCommit; with replica_proto_ == MODE_NONE,
// IsReplicated() is false so OnCommit just commits locally. That's the
// "reply unconditionally" behavior we want — no consensus checks.
// Must mirror the base Frame::CreateScheduler bookkeeping (sch->frame_ =
// this; svr_ = sch) — without it there's a nullptr deref later in main.
TxLogServer* NaiveFastpathFrame::CreateScheduler() {
  auto s = new SchedulerNone();
  s->frame_ = this;
  verify(svr_ == nullptr);
  svr_ = s;
  return s;
}

Communicator* NaiveFastpathFrame::CreateCommo(PollMgr* poll) {
  if (commo_ == nullptr) {
    commo_ = new CommunicatorNaiveFastpath(poll);
  }
  return commo_;
}

std::vector<rrr::Service*>
NaiveFastpathFrame::CreateRpcServices(uint32_t site_id,
                                      TxLogServer* rep_sched,
                                      rrr::PollMgr* poll_mgr,
                                      ServerControlServiceImpl* scsi) {
  auto result = std::vector<rrr::Service*>();
  result.push_back(new ClassicServiceImpl(rep_sched, poll_mgr, scsi));
  return result;
}

} // namespace janus
