#include "../config.h"
#include "../multi_value.h"
#include "../procedure.h"
#include "../txn_reg.h"
#include "scheduler.h"
#include "../rcc_rpc.h"
#include "../raft/server.h"
#include "../RW_command.h"

namespace janus {
int32_t SchedulerNone::Dispatch(cmdid_t cmd_id, shared_ptr<Marshallable> cmd,
								TxnOutput& ret_output, std::shared_ptr<ViewData>& view_data) {
	auto sp_tx = dynamic_pointer_cast<TxClassic>(GetOrCreateTx(cmd_id));
	DepId di;
	di.str = "dep";
	di.id = 0;
	SchedulerClassic::Dispatch(cmd_id, di, cmd, ret_output);
	sp_tx->fully_dispatched_->Wait();

	// Raft read-lease fast-path. The read piece has already been executed
	// against the local mdb in SchedulerClassic::Dispatch above and the
	// result is in ret_output. If the leader currently holds a valid
	// lease, no other replica can have been elected since the lease
	// anchor, so the local read is linearizable and we can skip the
	// OnCommit Raft replication round-trip. Single-key, read-only
	// requests are eligible; everything else falls through to the
	// existing replicated path.
	if (Config::GetConfig()->IsRaftReadLease() && rep_sched_ != nullptr) {
		key_t k; uint64_t cid; bool is_write = true;
		if (SimpleRWCommand::ExtractPoolKeys(cmd, &k, &cid, &is_write) && !is_write) {
			auto* raft_svr = dynamic_cast<RaftServer*>(rep_sched_);
			if (raft_svr != nullptr && raft_svr->HasReadLease()) {
				view_data = sp_tx->sp_view_data_;
				return SUCCESS;
			}
		}
	}

	int ret = OnCommit(cmd_id, di, SUCCESS);  // it waits for the command to be executed
	// if (ret == WRONG_LEADER) {
	// 	Log_info("[DISPATCH_FLOW] SchedulerNone::Dispatch got WRONG_LEADER for cmd_id: 0x%lx", cmd_id);
	// }
	view_data = sp_tx->sp_view_data_;

	return ret;
}

} // namespace janus
