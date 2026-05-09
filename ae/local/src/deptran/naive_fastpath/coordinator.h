#pragma once

#include "../classic/coordinator.h"

namespace janus {

// Client coordinator for naive_fastpath. Two-phase state machine:
//   INIT_END: broadcast Dispatch to all 5 replicas, await 4/5 replies.
//   DISPATCH: mark committed, record latency, End().
class CoordinatorNaiveFastpath : public CoordinatorClassic {
 public:
  using CoordinatorClassic::CoordinatorClassic;
  void GotoNextPhase() override;
};

} // namespace janus
