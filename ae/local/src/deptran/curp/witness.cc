#include "witness.h"

namespace janus {

void CurpWitness::WitnessSlot::record_in_flight(
    uint64_t cmd_id,
    const std::shared_ptr<Marshallable>& cmd,
    bool is_write) {
  in_flight_[cmd_id] = WitnessEntry{cmd, is_write};
  if (writer_count_ == 0 && is_write) {
    leader_recover_id_ = cmd_id;
  }
  writer_count_ += is_write ? 1u : 0u;
  seen_[cmd_id] = true;
}

int CurpWitness::WitnessSlot::clear_in_flight(uint64_t cmd_id) {
  auto it = in_flight_.find(cmd_id);
  if (it == in_flight_.end()) {
    return 0;
  }
  const bool was_writer = it->second.is_write;
  if (was_writer) {
    if (writer_count_ == 1 && leader_recover_id_ == cmd_id) {
      leader_recover_id_ = kNoRecoverId;
    }
    --writer_count_;
  }
  in_flight_.erase(it);
  return 1;
}

bool CurpWitness::decode(const std::shared_ptr<Marshallable>& cmd,
                         key_t* key,
                         uint64_t* cmd_id,
                         bool* is_write) {
  return SimpleRWCommand::ExtractPoolKeys(cmd, key, cmd_id, is_write);
}

bool CurpWitness::record_attempt(const std::shared_ptr<Marshallable>& cmd) {
  key_t key;
  uint64_t cmd_id;
  bool is_write;
  if (!decode(cmd, &key, &cmd_id, &is_write)) {
    // Workload doesn't expose per-key view; let the caller treat this
    // as no conflict.
    return true;
  }
  auto& slot = slots_[key];
  // CURP no-conflict rule (matches READ_NOT_CONFLICT_OPTIMIZATION used
  // elsewhere): no conflict iff the slot has no in-flight writer at
  // arrival time. The attempt is recorded regardless.
  const bool no_conflict = (slot.writer_count() == 0);
  slot.record_in_flight(cmd_id, cmd, is_write);
  ++attempt_count_;
  return no_conflict;
}

int CurpWitness::clear_attempt(const std::shared_ptr<Marshallable>& cmd) {
  key_t key;
  uint64_t cmd_id;
  bool is_write;
  if (!decode(cmd, &key, &cmd_id, &is_write)) {
    return 0;
  }
  auto it = slots_.find(key);
  if (it == slots_.end()) return 0;
  const int removed = it->second.clear_in_flight(cmd_id);
  if (removed > 0) {
    if (attempt_count_ > 0) --attempt_count_;
    if (it->second.empty()) {
      slots_.erase(it);
    }
  }
  return removed;
}

void CurpWitness::reset() {
  slots_.clear();
  attempt_count_ = 0;
}

}  // namespace janus
