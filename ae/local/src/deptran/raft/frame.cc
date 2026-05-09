#include "../__dep__.h"
#include "../constants.h"
#include "frame.h"
#include "exec.h"
#include "coordinator.h"
#include "server.h"
#include "service.h"
#include "commo.h"
#include "config.h"
#include "test.h"
// #include "../kv/server.h"

namespace janus {

REG_FRAME(MODE_RAFT, vector<string>({"raft"}), RaftFrame);

/*
template<typename D>
struct automatic_register {
 private:
  struct exec_register {
    exec_register() {
      D::do_it();
    }
  };
  // will force instantiation of definition of static member
  template<exec_register&> struct ref_it { };

  static exec_register register_object;
  static ref_it<register_object> referrer;
};

template<typename D> typename automatic_register<D>::exec_register
    automatic_register<D>::register_object;

struct foo : automatic_register<foo> {
  static void do_it() {
    REG_FRAME(MODE_FPGA_RAFT, vector<string>({"fpga_raft"}), RaftFrame);
  }
};*/

RaftFrame::RaftFrame(int mode) : Frame(mode) {
  
}

#ifdef RAFT_TEST_CORO
std::mutex RaftFrame::raft_test_mutex_;
std::shared_ptr<Coroutine> RaftFrame::raft_test_coro_ = nullptr;
uint16_t RaftFrame::n_replicas_ = 0;
map<siteid_t, RaftFrame*> RaftFrame::frames_ = {};
bool RaftFrame::all_sites_created_s = false;
bool RaftFrame::tests_done_ = false;
uint16_t RaftFrame::n_commo_created_ = 0;
#endif



Executor *RaftFrame::CreateExecutor(cmdid_t cmd_id, TxLogServer *sched) {
  Executor *exec = new RaftExecutor(cmd_id, sched);
  return exec;
}

Coordinator *RaftFrame::CreateCoordinator(cooid_t coo_id,
                                                Config *config,
                                                int benchmark,
                                                ClientControlServiceImpl *ccsi,
                                                uint32_t id,
                                                shared_ptr<TxnRegistry> txn_reg) {
  verify(config != nullptr);
  CoordinatorRaft *coo;
  coo = new CoordinatorRaft(coo_id,
                                  benchmark,
                                  ccsi,
                                  id);
  coo->frame_ = this;
  verify(commo_ != nullptr);
  coo->commo_ = commo_;
  /* TODO: remove when have a class for common data */
  verify(svr_ != nullptr);
  coo->svr_ = this->svr_;
  coo->slot_hint_ = &slot_hint_;
  coo->slot_id_ = slot_hint_++;
  coo->n_replica_ = config->GetPartitionSize(site_info_->partition_id_);
  coo->loc_id_ = this->site_info_->locale_id;
  verify(coo->n_replica_ != 0); // TODO
  Log_debug("create new fpga raft coord, coo_id: %d", (int) coo->coo_id_);
  return coo;
}

TxLogServer *RaftFrame::CreateScheduler() {
  if(svr_ == nullptr)
  {
    svr_ = new RaftServer(this);
  }
  else
  {
    verify(0) ;
  }
  Log_debug("create new fpga raft sched loc: %d", this->site_info_->locale_id);

#ifdef RAFT_TEST_CORO
  raft_test_mutex_.lock();
  verify(n_replicas_ < 5);
  frames_[this->site_info_->locale_id] = this;
  n_replicas_++;
  raft_test_mutex_.unlock();
#endif

  return svr_ ;
}


// Make = sure that this function is a coroutine function
// and it is called from a coroutine context.
Communicator *RaftFrame::CreateCommo(PollMgr *poll) {
  // We only have 1 instance of RaftFrame object that is returned from
  // GetFrame method. RaftCommo currently seems ok to share among the
  // clients of this method.
  Log_info("CreateCommo: Thread ID = %lu", std::this_thread::get_id());
  Log_info("CreateCommo: sp_running_coro_th_ = %p", Reactor::sp_running_coro_th_.get());
  if (commo_ == nullptr) {
    Log_info("CreateCommo: Creating new RaftCommo");
    commo_ = new RaftCommo(poll);
  }

  #ifdef RAFT_TEST_CORO
  Log_info("CreateCommo: RAFT_TEST_CORO enabled");
  raft_test_mutex_.lock();
  Log_info("CreateCommo: n_replicas_ = %d, n_commo_ = %d", n_replicas_, n_commo_created_);
  
  // Simple verification: ensure all 5 schedulers are created
  verify(n_replicas_ == 5);
  
  // Simple counter increment: track communicator creation
  // Find this frame in the map and increment counter
  bool found = false;
  for (const auto& pair : frames_) {
    if (pair.second == this) {
      found = true;
      break;
    }
  }
  verify(found); // This frame should exist in frames_
  
  // Use a simple counter approach like lab solution
  n_commo_created_++;
  Log_info("CreateCommo: n_commo_ now = %d", n_commo_created_);
  raft_test_mutex_.unlock();

  // Only site 0 creates and manages the test coroutine
  if (site_info_->locale_id == 0) {
    Log_info("CreateCommo: About to create test coroutine");
    verify(raft_test_coro_.get() == nullptr);
    Log_info("Creating Raft test coroutine");
    
    raft_test_coro_ = Coroutine::CreateRun([this] () {
      Log_info("Test coroutine: Starting execution");
      Log_info("Test coroutine: Thread ID = %lu", std::this_thread::get_id());
      Log_info("Test coroutine: sp_running_coro_th_ = %p", Reactor::sp_running_coro_th_.get());
      
      // Yield until all 5 communicators are initialized
      Log_info("Test coroutine: About to yield");
      Coroutine::CurrentCoroutine()->Yield();
      Log_info("Test coroutine: Resumed after yield");
      
      // Run tests
      verify(n_replicas_ == 5);
      auto testconfig = new RaftTestConfig(frames_);
      RaftLabTest test(testconfig);
      test.Run();
      test.Cleanup();
      Log_info("Test coroutine: Tests completed, turning off reactor loop");
      // Turn off Reactor loop
      Reactor::GetReactor()->looping_ = false;
      return;
    });
    Log_info("raft_test_coro_ id=%d", raft_test_coro_->id);
    
    // wait until n_commo_created_ == 5, then resume the coroutine
    raft_test_mutex_.lock();
    while (n_commo_created_ < 5) {
      raft_test_mutex_.unlock();
      sleep(0.1);
      raft_test_mutex_.lock();
    }
    raft_test_mutex_.unlock();
    Reactor::GetReactor()->ContinueCoro(raft_test_coro_);
  }
  #endif

  Log_info("CreateCommo: Returning commo_ = %p", commo_);
  return commo_;
}

vector<rrr::Service *>
RaftFrame::CreateRpcServices(uint32_t site_id,
                                   TxLogServer *rep_sched,
                                   rrr::PollMgr *poll_mgr,
                                   ServerControlServiceImpl *scsi) {
  auto config = Config::GetConfig();
  auto result = std::vector<Service *>();
  switch (config->replica_proto_) {
    case MODE_RAFT:result.push_back(new RaftServiceImpl(rep_sched));
    default:break;
  }
  return result;
}

} // namespace janus;
