#pragma once

#include "server.h"

namespace janus {

class ZookeeperServiceImpl: public ZookeeperService {
 public:
  ZookeeperServer* sched_;
  ZookeeperServiceImpl(TxLogServer* sched);

  void Commit(const MarshallDeputy& md_cmd,
              rrr::DeferredReply* defer) override;

};

} // namespace janus
