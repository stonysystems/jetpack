#pragma once

#include "../__dep__.h"
#include "../command.h"
#include "../RW_command.h"

namespace janus {

// CurpWitness — per-replica record of optimistic (fast-path) attempts that
// have been admitted but not yet replicated.
//
// CURP fault tolerance requires that at any point in time the witnesses can
// surface enough information for a recovering leader to reconstruct the set
// of in-flight optimistic attempts on a key. To support that, each per-key
// slot retains:
//   * a map keyed by cmd_id of every currently in-flight attempt, holding
//     the original cmd shared_ptr so the attempt is replayable;
//   * a separate "seen" map that records every cmd_id that ever entered
//     the slot, regardless of whether it has since been cleared, so a
//     leader recovering from a duplicated witness ack can dedup;
//   * a running writer count and the cmd_id of the first writer to enter
//     the slot, both used by the leader's recover-rule to decide whether
//     a witness saw a conflicting writer.
//
// Conflict semantics (matches the existing READ_NOT_CONFLICT_OPTIMIZATION
// shape used elsewhere in the system): an attempt sees no conflict iff
// the slot currently has zero in-flight writers. Two pure reads on the
// same key do not conflict.
//
// Single-threaded coroutine reactor: no internal synchronization.
class CurpWitness {
 public:
  // A single in-flight attempt held by a slot, retained for the duration
  // it is uncommitted so a recovery path can replay it.
  struct WitnessEntry {
    std::shared_ptr<Marshallable> cmd;
    bool is_write;
  };

  // Per-key bucket of in-flight attempts plus the recovery-side metadata
  // a future CURP recovery path will consume.
  class WitnessSlot {
   public:
    // record_in_flight inserts an attempt; the slot's prior writer count
    // is what determines whether a CALLER reports the attempt as
    // conflict-free, so callers should query writer_count() before this
    // call. After the call, writer_count() and the seen-set reflect the
    // newly inserted attempt.
    void record_in_flight(uint64_t cmd_id,
                          const std::shared_ptr<Marshallable>& cmd,
                          bool is_write);

    // clear_in_flight removes an attempt by cmd_id from the in-flight
    // map. The seen-set is intentionally not erased: a later recovery
    // duplicate ack on the same cmd_id must still be dedup-able.
    // Returns the number of in-flight entries removed (0 on miss).
    int clear_in_flight(uint64_t cmd_id);

    bool empty() const { return in_flight_.empty(); }
    uint32_t writer_count() const { return writer_count_; }
    size_t size() const { return in_flight_.size(); }

    // Recovery surface — exposed for a future CURP recovery path to walk.
    const std::unordered_map<uint64_t, WitnessEntry>& in_flight() const {
      return in_flight_;
    }
    bool has_seen(uint64_t cmd_id) const {
      return seen_.find(cmd_id) != seen_.end();
    }
    uint64_t leader_recover_id() const { return leader_recover_id_; }

   private:
    static constexpr uint64_t kNoRecoverId = static_cast<uint64_t>(-1);

    std::unordered_map<uint64_t /*cmd_id*/, WitnessEntry> in_flight_;
    // dedup-only: every cmd_id that has ever entered this slot, never
    // erased. Bounded by the number of distinct attempts on this key
    // for the lifetime of the witness; reset() clears it.
    std::unordered_map<uint64_t /*cmd_id*/, bool> seen_;
    uint32_t writer_count_ = 0;
    uint64_t leader_recover_id_ = kNoRecoverId;
  };

  CurpWitness() = default;
  ~CurpWitness() = default;

  // record_attempt: returns true iff no in-flight writer was already on
  // this key when the attempt arrived (CURP no-conflict rule). The
  // attempt is recorded regardless so subsequent attempts on the same
  // key see it as a witness.
  bool record_attempt(const std::shared_ptr<Marshallable>& cmd);

  // clear_attempt removes the attempt for cmd from this witness once
  // the cmd has been replicated and applied. Returns the number of
  // in-flight entries cleared (0 on a replica that never witnessed it).
  int clear_attempt(const std::shared_ptr<Marshallable>& cmd);

  // reset drops all witness state. Used when the replica leaves the
  // optimistic region.
  void reset();

  size_t key_count() const { return slots_.size(); }
  size_t attempt_count() const { return attempt_count_; }

  // Surface for a future recovery path to walk the witness contents.
  const std::unordered_map<key_t, WitnessSlot>& slots() const {
    return slots_;
  }

 private:
  std::unordered_map<key_t, WitnessSlot> slots_;
  size_t attempt_count_ = 0;

  static bool decode(const std::shared_ptr<Marshallable>& cmd,
                     key_t* key,
                     uint64_t* cmd_id,
                     bool* is_write);
};

}  // namespace janus
