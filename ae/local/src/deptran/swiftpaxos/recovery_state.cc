#include "recovery_state.h"

namespace janus {

// Register the new MarshallDeputy kind so MarshallDeputy::CreateActualObjectFrom
// can instantiate a SwiftRecoveryState during deserialization.
static int volatile swift_recovery_state_init_x =
    MarshallDeputy::RegInitializer(MarshallDeputy::CMD_SWIFT_RECOVERY_STATE,
                                   []() -> Marshallable* {
                                     return new SwiftRecoveryState;
                                   });

Marshal& SwiftRecoveryState::ToMarshal(Marshal& m) const {
  m << cmd_ids;
  m << phases;
  m << keys;
  m << deps;
  m << cmds;
  return m;
}

Marshal& SwiftRecoveryState::FromMarshal(Marshal& m) {
  m >> cmd_ids;
  m >> phases;
  m >> keys;
  m >> deps;
  m >> cmds;
  return m;
}

}  // namespace janus
