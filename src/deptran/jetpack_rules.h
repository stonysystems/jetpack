#pragma once

// Pure Jetpack recovery rules: replica guards, unique ballots, the choice of
// the recovery value, the coordinator takeover timer and the amnesia
// rule of restarted replicas. Header-only and free of rrr/deptran
// dependencies so the rules can be unit-tested without linking deptran. The
// std headers must come before constants.h, which #defines key_t, ballot_t
// and epoch_t.
#include <algorithm>
#include <cstdint>
#include <limits>
#include <map>
#include <set>
#include <tuple>
#include <utility>
#include <vector>

#include "constants.h"

namespace janus {
namespace jp {

// Ballot layout: (view << 32) | (counter << 8) | loc. The recovery view sits in
// the high bits, so a ballot of a newer view beats every ballot of an older
// one; (counter, loc) make ballots unique per coordinator attempt.
constexpr uint64_t kBallotViewLimit = (1ull << 31);
constexpr uint32_t kBallotCounterLimit = (1u << 24);
constexpr uint32_t kBallotLocLimit = (1u << 8);

inline bool BallotArgsOk(epoch_t v, uint32_t counter, uint32_t loc) {
  return (uint64_t) v < kBallotViewLimit && counter < kBallotCounterLimit &&
         loc < kBallotLocLimit;
}

// Callers check BallotArgsOk() first. Out-of-range fields are masked so they
// can never bleed into the view bits.
inline ballot_t MakeBallot(epoch_t v, uint32_t counter, uint32_t loc) {
  return ((int64_t) (v & 0x7FFFFFFFu) << 32) |
         ((int64_t) (counter & 0xFFFFFFu) << 8) |
         (int64_t) (loc & 0xFFu);
}
inline epoch_t BallotView(ballot_t b) { return b < 0 ? 0 : (epoch_t) (b >> 32); }
inline uint32_t BallotCounter(ballot_t b) {
  return b < 0 ? 0 : (uint32_t) ((b >> 8) & 0xFFFFFF);
}
inline uint32_t BallotLoc(ballot_t b) { return b < 0 ? 0 : (uint32_t) (b & 0xFF); }

enum class BallotRule { kStrict, kAtLeast, kIgnore };

// A recovery message for view v passes only if v is newer than the
// installed fast-path view, not older than the newest joined view, and the
// ballot clears the promise.
inline bool RecoveryMsgAllowed(epoch_t view_id, epoch_t vid, ballot_t promised,
                               epoch_t v, ballot_t b, BallotRule r) {
  if (!(v > view_id) || !(v >= vid)) return false;
  if (r == BallotRule::kStrict) return b > promised;
  if (r == BallotRule::kAtLeast) return b >= promised;
  return true;
}

// Accept(v, vn, b): also requires the instance vn to be older than v and not
// older than the replica's installed view (accepted[vn] with vn < view.id can
// never be read again).
inline bool AcceptAllowed(epoch_t view_id, epoch_t vid, ballot_t promised,
                          epoch_t v, epoch_t vn, ballot_t b) {
  return RecoveryMsgAllowed(view_id, vid, promised, v, b, BallotRule::kAtLeast) &&
         vn < v && vn >= view_id;
}

// FinishRecovery(u) installs view u only if u is not older than the newest
// joined view and strictly newer than the installed one.
inline bool FinishAllowed(epoch_t view_id, epoch_t vid, epoch_t u) {
  return u >= vid && u > view_id;
}

// A fast-path ack only in READY and only in the request's view.
inline bool AckAllowed(bool ready, epoch_t view_id, epoch_t req_view) {
  return ready && req_view == view_id;
}

inline int MaxFailures(int n) { return (n - 1) / 2; }
// ceil(f/2) + 1 of the Pull quorum must report a command.
inline int RecoveryThreshold(int n) {
  int f = MaxFailures(n);
  return (f + 3) / 2;
}
// f + ceil(f/2) + 1, as SimpleRWCommand::RuleSuperMajority.
inline int FastQuorum(int n) {
  int f = MaxFailures(n);
  return f + (f + 1) / 2 + 1;
}
inline int Majority(int n) { return n / 2 + 1; }

template <class Body>
struct Entry {
  key_t key;
  uint64_t cmd_id;
  Body body;
};

template <class Body>
struct PullOk {
  epoch_t view_id = 0;                // the replier's installed view (view.id)
  std::vector<Entry<Body>> acked;     // acked, not yet GC'd entries of view_id
  // accepted[vn] = (ballot, value) of the replier's acceptor state
  std::map<epoch_t, std::pair<ballot_t, std::vector<Entry<Body>>>> accepted;
};

template <class Body>
struct Choice {
  epoch_t vn = 0;
  bool adopted = false;
  ballot_t adopted_ballot = -1;
  std::vector<Entry<Body>> value;
};

template <class Body>
inline void SortEntries(std::vector<Entry<Body>>* v) {
  std::stable_sort(v->begin(), v->end(),
                   [](const Entry<Body>& a, const Entry<Body>& b) {
                     return std::make_pair(a.key, a.cmd_id) <
                            std::make_pair(b.key, b.cmd_id);
                   });
  v->erase(std::unique(v->begin(), v->end(),
                       [](const Entry<Body>& a, const Entry<Body>& b) {
                         return a.key == b.key && a.cmd_id == b.cmd_id;
                       }),
           v->end());
}

// The recovery value of a Pull quorum (ok replies only):
//  - vn = the highest installed view among the replies;
//  - if some reply carries accepted[vn], adopt the one with the highest ballot
//    (an accepted empty set is a value, too);
//  - otherwise include every (key, cmd_id) reported by >= threshold replies
//    whose view is vn; replies from lower views count as empty.
// The result is sorted by (key, cmd_id).
template <class Body>
Choice<Body> ChooseRecoveryValue(const std::vector<PullOk<Body>>& ok, int threshold) {
  Choice<Body> c;
  for (const auto& r : ok) {
    c.vn = std::max(c.vn, r.view_id);
  }
  const std::vector<Entry<Body>>* best = nullptr;
  ballot_t best_ballot = -1;
  for (const auto& r : ok) {
    auto it = r.accepted.find(c.vn);
    if (it == r.accepted.end()) continue;
    if (best == nullptr || it->second.first > best_ballot) {
      best = &it->second.second;
      best_ballot = it->second.first;
    }
  }
  if (best != nullptr) {
    c.adopted = true;
    c.adopted_ballot = best_ballot;
    c.value = *best;
    SortEntries(&c.value);
    return c;
  }
  // (key, cmd_id) -> (count, index of the first reply/entry that listed it)
  std::map<std::pair<key_t, uint64_t>, std::tuple<int, size_t, size_t>> counts;
  for (size_t i = 0; i < ok.size(); i++) {
    const auto& r = ok[i];
    if (r.view_id != c.vn) continue;
    std::set<std::pair<key_t, uint64_t>> seen;
    for (size_t j = 0; j < r.acked.size(); j++) {
      auto k = std::make_pair(r.acked[j].key, r.acked[j].cmd_id);
      if (!seen.insert(k).second) continue;
      auto it = counts.find(k);
      if (it == counts.end()) {
        counts.emplace(k, std::make_tuple(1, i, j));
      } else {
        std::get<0>(it->second)++;
      }
    }
  }
  for (const auto& kv : counts) {
    if (std::get<0>(kv.second) < threshold) continue;
    const auto& src = ok[std::get<1>(kv.second)].acked[std::get<2>(kv.second)];
    c.value.push_back(Entry<Body>{kv.first.first, kv.first.second, src.body});
  }
  return c;
}

// ---- Coordinator takeover (etcd / MongoDB / ZooKeeper; Raft relies on its
// own elections). A replica frozen in a recovery (vid > view.id) that sees no
// recovery progress there (a passed Pull/Accept, an applied FinishRecovery)
// for TakeoverDelayUs(rank) re-runs the recovery of the same view vid with its
// own ballot. rank = loc_id, so frozen replicas time out one after another
// (10 s, 15 s, 20 s, ...) and the first takeover's Pull resets the others'
// timers. The live coordinator re-sends its Accept every kKeepaliveEveryUs
// while it resubmits, so a live recovery is not taken over.
constexpr int64_t kTakeoverBaseUs = 10LL * 1000 * 1000;
constexpr int64_t kTakeoverRankStepUs = 5LL * 1000 * 1000;
// Repeated takeovers of one view by one replica back off: x1, x2, x4, x8.
constexpr int kTakeoverMaxBackoffShift = 3;
constexpr int64_t kKeepaliveEveryUs = 2LL * 1000 * 1000;

inline int64_t TakeoverDelayUs(uint32_t rank, int attempts) {
  const int shift = std::max(0, std::min(attempts, kTakeoverMaxBackoffShift));
  return (kTakeoverBaseUs + (int64_t) rank * kTakeoverRankStepUs) << shift;
}

// The takeover timer's decision, one Tick per timer wake-up; the caller
// supplies the clock. Returns the view to take over, or 0.
//  - frozen: vid > view.id here; busy: the local recovery driver runs or has
//    a published target (so one node never runs two takeovers at once);
//  - last_progress_us: this replica's newest recovery progress;
//  - the deadline counts from the newest of that progress, the moment this
//    clock first saw the replica frozen in vid and its own previous takeover
//    of vid; it backs off with every takeover of the same vid and resets when
//    the replica unfreezes or joins another view.
class TakeoverClock {
 public:
  explicit TakeoverClock(uint32_t rank = 0) : rank_(rank) {}

  epoch_t Tick(int64_t now_us, bool frozen, epoch_t vid, int64_t last_progress_us, bool busy) {
    if (!frozen || vid == 0) {
      vid_ = 0;
      attempts_ = 0;
      since_us_ = 0;
      fired_us_ = 0;
      deadline_us_ = 0;
      return 0;
    }
    if (vid != vid_) {
      vid_ = vid;
      attempts_ = 0;
      since_us_ = now_us;
      fired_us_ = 0;
    }
    const int64_t base = std::max(std::max(last_progress_us, since_us_), fired_us_);
    deadline_us_ = base + TakeoverDelayUs(rank_, attempts_);
    if (busy || now_us < deadline_us_) return 0;
    attempts_++;
    fired_us_ = now_us;
    return vid;
  }

  uint32_t rank() const { return rank_; }
  epoch_t vid() const { return vid_; }
  int attempts() const { return attempts_; }
  int64_t deadline_us() const { return deadline_us_; }

 private:
  uint32_t rank_;
  epoch_t vid_ = 0;
  int attempts_ = 0;
  int64_t since_us_ = 0;
  int64_t fired_us_ = 0;
  int64_t deadline_us_ = 0;
};

// The first ballot counter of a coordinator of view v: at least the counter
// of the same-view promise it has seen, so its first ballot (counter + 1)
// beats a stalled coordinator's. A promise of an older view needs no bump.
inline uint32_t CounterAbovePromise(uint32_t counter, epoch_t v, ballot_t promised) {
  if (BallotView(promised) != v) return counter;
  return std::max(counter, BallotCounter(promised));
}

// A reply to the running coordinator's keepalive Accept(v, vn, b). It stops
// resubmitting if a replica joined a newer view (superseded), installed v or
// newer (another coordinator of v finished) or promised a higher ballot of v
// (another coordinator took v over: it adopts the same chosen value).
enum class KeepaliveVerdict { kContinue, kSuperseded, kFinishedElsewhere, kTakenOver };
inline KeepaliveVerdict ClassifyKeepaliveReply(epoch_t v, ballot_t b, epoch_t view_id,
                                               epoch_t vid, ballot_t promised) {
  if (vid > v) return KeepaliveVerdict::kSuperseded;
  if (view_id >= v) return KeepaliveVerdict::kFinishedElsewhere;
  if (BallotView(promised) == v && promised > b) return KeepaliveVerdict::kTakenOver;
  return KeepaliveVerdict::kContinue;
}

// One leader per view id where a takeover can give view v several
// coordinators. A replica installs a view once (FinishAllowed: u > view.id).
// A coordinator installs v at its own replica, and so starts leading v, only
// after n/2 OTHER replicas installed v from its FinishRecovery: with its own
// replica that is a majority. Two coordinators of v would need
// 2 * (n/2 + 1) > n distinct replicas, so at most one replica leads view v.
// A FinishRecovery reply says "installed" iff the replica is in view u with
// the FinishRecovery's leader (now or from an earlier copy), which makes the
// count robust against dropped replies.
inline bool SelfInstallAllowed(int n, int others_installed_ours) {
  return others_installed_ours >= n / 2;
}
// Fewer than n/2 other replicas are left that could still install ours.
inline bool SelfInstallImpossible(int n, int others_installed_foreign) {
  return n - 1 - others_installed_foreign < n / 2;
}
inline bool FinishReplyInstalled(bool applied_now, epoch_t installed_view, int installed_leader,
                                 epoch_t u, int fr_leader) {
  return applied_now || (installed_view == u && fr_leader >= 0 && installed_leader == fr_leader);
}

// One agreed leader per view (liveness): the rules above allow at most one
// leader, but two same-view coordinators whose FinishRecovery messages cross
// (each one's own replica installs the other's view before it installs its
// own) leave view v with none, READY everywhere, and nothing repairs that
// without a newer backend term. So a FinishRecovery(v) carries the ballot b
// at which its coordinator's Accept chose the value, and a frozen replica
// installs it only if b is at least its FinishRecovery level for v
// (FinishBallotOk): the highest same-view ballot it has taken part in
// (TxLogServer::JpFinishLevel), raised at the coordinator's own replica to
// the coordinator's ballot as soon as its Accept succeeded. The coordinator
// with the highest ballot that reached FinishRecovery therefore never
// installs a lower one's view and is never outnumbered by them, so it leads
// v. Once a coordinator leads v (it installed v after n/2 others did) the
// leader is decided and its later copies carry kChosenBallot, which every
// level admits; so does its own install.
const ballot_t kChosenBallot = std::numeric_limits<ballot_t>::max();
inline bool FinishBallotOk(ballot_t level, ballot_t b) {
  return b >= level;
}

// ---- Amnesia (rejoin) rule. A replica restarted with JETPACK_REJOIN=1 starts
// with an empty pool, no promise and no accepted values (nothing is persisted).
// While amnesiac it answers no Pull/Accept (no side effect) and acks no
// fast-path request, and it installs only a view that did not exist before
// its restart ("fresh"). Views are backend terms, which only grow, so every
// view >= fresh_from is fresh, where fresh_from is
//  - T_rejoin + 1, T_rejoin = the backend term learned after the restart
//    (every view id created before the restart is <= it), and
//  - a view this replica coordinates after its restart from its own trigger
//    (its own backend node won that term after the restart),
// whichever is lower; unknown (0) until one of them is learned. Installing a
// fresh view ends the amnesia: there the pool, promise and accepted values of
// every replica start empty, and older views cannot be joined after that.
class RejoinState {
 public:
  RejoinState() = default;
  explicit RejoinState(bool amnesiac) : amnesiac_(amnesiac) {}

  bool amnesiac() const { return amnesiac_; }
  bool term_known() const { return term_known_; }
  uint64_t term() const { return term_; }
  uint64_t fresh_from() const { return fresh_from_; }

  // T_rejoin; the first learned term counts. Returns true if it was taken.
  bool LearnTerm(uint64_t t) {
    if (!amnesiac_ || term_known_) return false;
    term_known_ = true;
    term_ = t;
    Fresh(t + 1);
    return true;
  }
  // This replica's own post-restart trigger joined view v.
  void NoteOwnTrigger(epoch_t v) {
    if (amnesiac_ && v > 0) Fresh(v);
  }
  bool RecoveryMsgAllowed() const { return !amnesiac_; }
  bool AckAllowed() const { return !amnesiac_; }
  // On top of FinishAllowed(view.id, vid, u).
  bool FinishAllowed(epoch_t u) const {
    return !amnesiac_ || (fresh_from_ != 0 && (uint64_t) u >= fresh_from_);
  }
  // View u was installed; returns true if that ended the amnesia.
  bool OnInstalled(epoch_t u) {
    if (!amnesiac_ || !FinishAllowed(u)) return false;
    amnesiac_ = false;
    return true;
  }

 private:
  void Fresh(uint64_t f) {
    if (fresh_from_ == 0 || f < fresh_from_) fresh_from_ = f;
  }
  bool amnesiac_ = false;
  bool term_known_ = false;
  uint64_t term_ = 0;
  uint64_t fresh_from_ = 0;
};

}  // namespace jp
}  // namespace janus
