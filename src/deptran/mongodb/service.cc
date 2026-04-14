#include "service.h"

namespace janus {

MongodbServiceImpl::MongodbServiceImpl(TxLogServer *sched)
  : sched_((MongodbServer*)sched) {

}

void MongodbServiceImpl::Commit(const MarshallDeputy& md_cmd,
                                rrr::DeferredReply* defer) {
  sched_->RuleCommandPoolGC(const_cast<MarshallDeputy&>(md_cmd).sp_data_);
  defer->reply();
}

} // namespace janus;