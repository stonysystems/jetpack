#pragma once

#include "server.h"

namespace janus {

class EtcdServiceImpl: public EtcdService {
 public:
  EtcdServer* sched_;
  EtcdServiceImpl(TxLogServer* sched);

  void Commit(const MarshallDeputy& md_cmd,
              rrr::DeferredReply* defer) override;

};


} // namespace janus
