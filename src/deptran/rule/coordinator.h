#pragma once

#include "deptran/classic/coordinator.h"
#include "commo.h"

namespace janus {

// This Coordinator should be on Client Side

class CoordinatorRule : public CoordinatorClassic {
 public:
  enum Phase {INIT_END=0, DISPATCHED=1, WAITING_ORIGIN=2};
  bool fast_path_success_{false};
  bool coordinator_success_{false};
  // FIX 2 (2026-05-19): per-tx flag — when true, the rule coord skips
  // the bookkeeping (sp_vec_piece_by_par_, frequency_, cli2cli, bandit)
  // that's only useful when fast-path actually fires. Set in INIT_END
  // after the throttle decision; consumed in DISPATCHED. Scope is gated
  // on KV-backend protocols (MODE_MONGODB/ETCD/ZOOKEEPER) to keep zero
  // impact on raft/copilot/mencius which rely on the full rule machinery.
  bool rule_short_circuit_{false};
  shared_ptr<VecPieceData> sp_vpd_; // cmd

  // CommunicatorRule* commo_;
  // double margin_success_rate_;

  value_t result_;

  CoordinatorRule(uint32_t coo_id,
                  int32_t benchmark,
                  ClientControlServiceImpl *ccsi,
                  uint32_t thread_id);
  ~CoordinatorRule() {
  }
  // CommunicatorRule* commo();
  void GotoNextPhase() override;
  void BroadcastRuleSpeculativeExecute(int cmd_ver);
  void DispatchAsync(bool fastpath_broadcast_mode);
  // Fused path: sends one DispatchWithRuleSpec RPC to the leader and
  // RuleSpeculativeExecute to the N-1 followers. Replaces the separate
  // DispatchAsync + BroadcastRuleSpeculativeExecute pair when the merge
  // flag is on and the protocol has a single leader.
  void DispatchAndSpeculativeExecuteFused(int cmd_ver);
};

} // namespace janus
