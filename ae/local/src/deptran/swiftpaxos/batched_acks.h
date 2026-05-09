#pragma once

#include "../__dep__.h"
#include "../marshallable.h"
#include <vector>

namespace janus {

// Batched ack payload — coalesces multiple per-cmd FastAcks and LightSlowAcks
// from one sender into a single wire message. Mirrors IMDEA's MAcks
// (heterogeneous batch; defs.go:83-86) without the MOptAcks single-ballot
// special case (Janus has no client-side decode, so the packing complexity
// of IMDEA's `MOptAcks` is unnecessary). All entries share the same sender
// (sender_replica) but ballots may differ, e.g. during a recovery transition.
class SwiftBatchedAcks : public Marshallable {
 public:
  rrr::i32 sender_replica = 0;

  // FastAcks (parallel arrays, length = #FastAcks).
  std::vector<rrr::i64> fa_ballots;
  std::vector<rrr::i64> fa_cmd_ids;
  std::vector<rrr::i32> fa_keys;
  std::vector<rrr::i64> fa_seqnums;
  std::vector<std::vector<rrr::i64>> fa_deps;

  // LightSlowAcks (parallel arrays, length = #LightSlowAcks).
  std::vector<rrr::i64> sa_ballots;
  std::vector<rrr::i64> sa_cmd_ids;

  SwiftBatchedAcks()
      : Marshallable(MarshallDeputy::CMD_SWIFT_BATCHED_ACKS) {}

  Marshal& ToMarshal(Marshal& m) const override;
  Marshal& FromMarshal(Marshal& m) override;

  bool empty() const {
    return fa_cmd_ids.empty() && sa_cmd_ids.empty();
  }
  size_t size() const { return fa_cmd_ids.size() + sa_cmd_ids.size(); }
};

}  // namespace janus
