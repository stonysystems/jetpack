#include "service.h"

namespace janus {

ZookeeperServiceImpl::ZookeeperServiceImpl(TxLogServer *sched)
  : sched_((ZookeeperServer*)sched) {

}

void ZookeeperServiceImpl::Commit(const MarshallDeputy& md_cmd,
                                   rrr::DeferredReply* defer) {
  sched_->RuleWitnessGC(const_cast<MarshallDeputy&>(md_cmd).sp_data_);
  defer->reply();
}

} // namespace janus;
