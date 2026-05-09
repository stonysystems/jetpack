#include "service.h"

namespace janus {

EtcdServiceImpl::EtcdServiceImpl(TxLogServer *sched)
  : sched_((EtcdServer*)sched) {

}

void EtcdServiceImpl::Commit(const MarshallDeputy& md_cmd,
                             rrr::DeferredReply* defer) {
  sched_->RuleCommandPoolGC(const_cast<MarshallDeputy&>(md_cmd).sp_data_);
  defer->reply();
}

} // namespace janus;
