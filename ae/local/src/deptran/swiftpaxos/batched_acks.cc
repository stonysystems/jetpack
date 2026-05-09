#include "batched_acks.h"

namespace janus {

static int volatile swift_batched_acks_init_x =
    MarshallDeputy::RegInitializer(MarshallDeputy::CMD_SWIFT_BATCHED_ACKS,
                                   []() -> Marshallable* {
                                     return new SwiftBatchedAcks;
                                   });

Marshal& SwiftBatchedAcks::ToMarshal(Marshal& m) const {
  m << sender_replica;
  m << fa_ballots;
  m << fa_cmd_ids;
  m << fa_keys;
  m << fa_seqnums;
  m << fa_deps;
  m << sa_ballots;
  m << sa_cmd_ids;
  return m;
}

Marshal& SwiftBatchedAcks::FromMarshal(Marshal& m) {
  m >> sender_replica;
  m >> fa_ballots;
  m >> fa_cmd_ids;
  m >> fa_keys;
  m >> fa_seqnums;
  m >> fa_deps;
  m >> sa_ballots;
  m >> sa_cmd_ids;
  return m;
}

}  // namespace janus
