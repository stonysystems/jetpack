#pragma once

#include "deptran/communicator.h"

namespace janus
{

class CommunicatorRule : public Communicator {
public:
    unordered_map<int, uint32_t> n_pending_rpc_;
    const uint32_t max_pending_rpc_ = 200;
    SharedIntEvent dispatch_quota{};

    map<parid_t, vector<SiteProxyPair>> jetpack_leader_cache_ = {};

    // Jetpack fast-path view cache: the newest fast-path view this
    // worker has learned, per partition (0 until one is learned). It is not
    // Communicator::partition_views_, which is process-wide and also written
    // by co-located servers. One CommunicatorRule per ClientWorker, and all
    // of its callbacks run on that worker's poll thread, so no lock.
    std::unordered_map<parid_t, epoch_t> fp_view_ = {};

    CommunicatorRule(PollMgr* poll_mgr = nullptr)
     :Communicator(poll_mgr) {
        dispatch_quota.value_ = 3 * max_pending_rpc_;
    }

    epoch_t FastPathView(parid_t par_id) const;
    // Raise only: views of a partition never go back.
    void AdoptFastPathView(parid_t par_id, epoch_t view);
    // Also learns the view id of a WRONG_LEADER (base) view, but only where
    // Jetpack recovery runs (TxLogServer::JetpackRecoveryEnabled()). In CURP,
    // Copilot, Mencius etc. the fast-path view stays 0.
    void AdoptBaseViewForFastPath(parid_t par_id,
                                  const shared_ptr<ViewData>& view_data);

    vector<SiteProxyPair> LeaderProxyForPartition(parid_t, int idx=-1) const;

    std::vector<int> LeadersForPartition(parid_t par_id) const;

    // SiteProxyPair FindSiteProxyPair(parid_t par_id, int replica_id) const;

    // std::vector<SiteProxyPair>
    // LeaderProxyForPartition(parid_t par_id) const;

    // Sends the command in this worker's current fast-path view of the
    // partition; a reply counts as a yes only if it was acked in that view.
    shared_ptr<RuleSpeculativeExecuteQuorumEvent>
    BroadcastRuleSpeculativeExecute(shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data);

    // Variant that skips the leader replica (caller sends a fused
    // DispatchWithRuleSpec to the leader instead). The returned event is
    // pre-configured for n_total-1 replicas; the leader's vote is fed by
    // BroadcastDispatchWithRuleSpec when the fused RPC replies. req_view is
    // the fast-path view the caller read once for both legs of the attempt.
    shared_ptr<RuleSpeculativeExecuteQuorumEvent>
    BroadcastRuleSpeculativeExecuteSkipLeader(shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data,
                                              epoch_t req_view);

    void BroadcastDispatch(bool fastpath_broadcast_mode,
                         shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data,
                         Coordinator *coo,
                         const std::function<void(int res, TxnOutput &)> &);

    // Fused leader-side RPC: one round-trip carries both the Dispatch and the
    // RuleSpeculativeExecute payload. The reply feeds the dispatch callback
    // and the spec quorum event.
    void BroadcastDispatchWithRuleSpec(
        shared_ptr<vector<shared_ptr<SimpleCommand>>> vec_piece_data,
        Coordinator *coo,
        shared_ptr<RuleSpeculativeExecuteQuorumEvent> spec_event,
        const std::function<void(int res, TxnOutput &)> &callback,
        epoch_t req_view);
};
    
} // namespace janus
