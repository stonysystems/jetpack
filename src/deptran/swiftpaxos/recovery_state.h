#pragma once

#include "../__dep__.h"
#include "../marshallable.h"
#include <vector>
#include <map>

namespace janus {

// Snapshot of one replica's per-command state, sent in SwiftNewLeaderAck
// during recovery and merged by the new leader into a SwiftSync payload.
// Mirrors IMDEA's MNewLeaderAckN.{CmdIds,Phases,Cmds,Deps} (recovery.go:131-145)
// and MSync.{Phases,Cmds,Deps} (defs.go:146-152). cmds[i] is shipped via
// MarshallDeputy because the SMR command is the application-level payload.
class SwiftRecoveryState : public Marshallable {
 public:
  std::vector<rrr::i64> cmd_ids;          // command identifiers
  std::vector<rrr::i32> phases;           // SwiftCmdDesc::Phase (0..3)
  std::vector<rrr::i32> keys;             // application-level key per cmd
  std::vector<std::vector<rrr::i64>> deps; // committed-or-proposed dep set per cmd
  std::vector<MarshallDeputy> cmds;       // command payloads, parallel to cmd_ids

  SwiftRecoveryState()
      : Marshallable(MarshallDeputy::CMD_SWIFT_RECOVERY_STATE) {}

  Marshal& ToMarshal(Marshal& m) const override;
  Marshal& FromMarshal(Marshal& m) override;

  size_t size() const { return cmd_ids.size(); }
  void clear() {
    cmd_ids.clear();
    phases.clear();
    keys.clear();
    deps.clear();
    cmds.clear();
  }
};

}  // namespace janus
