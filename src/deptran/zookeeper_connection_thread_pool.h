#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <inttypes.h>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>

#include "constants.h"
#include "zookeeper_kv_table_handler.h"
#include "RW_command.h"

namespace janus {

// 2026-05-19: refactor — ported from
// MongodbConnectionThreadPool. The previous impl had:
//   * one shared `handler_` for all requests
//   * `ZookeeperRequest()` called handler_->Write()/Read() INLINE in the
//     caller's thread (the server coroutine)
// → all ZK requests serialised through one libzookeeper-mt session, even
// though libzookeeper-mt supports many independent sessions per process.
// Plus the caller's thread blocked for the full ZAB-majority-commit RTT
// (~150 ms) on every request, so concurrent submissions queued sequentially.
//
// This refactor matches mongodb_connection_thread_pool.h:
//   * N long-lived worker threads (N = thread_num passed in by the server)
//   * Per-worker CommandQueue (std::queue + mutex + cv)
//   * Per-worker ZookeeperKVTableHandler (own libzookeeper-mt session)
//   * ZookeeperRequest() is round-robin push(cmd) — no inline blocking
//   * Worker loop blocks on pop(), runs sync handler->Write/Read, signals
//     zookeeper_finished->Set(1).
// libzookeeper-mt is documented thread-safe per session; multiple
// independent sessions to the same ensemble are fine (each is its own
// TCP connection).

class ZookeeperConnectionThreadPool {

  struct ZookeeperMetrics {
#ifdef ZOOKEEPER_STATISTICS
    std::mutex mu;
    Distribution queue_wait_ms;
    Distribution queue_depth;
    Distribution zk_service_ms;
    Distribution end_to_end_ms;
    uint64_t total_commands{0};
#endif

    void RecordQueueDepth(double depth) {
#ifdef ZOOKEEPER_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      queue_depth.append(depth);
#endif
    }

    void RecordQueueWait(double wait_ms) {
#ifdef ZOOKEEPER_STATISTICS
      if (wait_ms < 0) return;
      std::lock_guard<std::mutex> lock(mu);
      queue_wait_ms.append(wait_ms);
#endif
    }

    void RecordService(double service_ms, double queue_wait_ms_value) {
#ifdef ZOOKEEPER_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      zk_service_ms.append(service_ms);
      end_to_end_ms.append(service_ms + queue_wait_ms_value);
      total_commands++;
#endif
    }

    void Dump(const char* tag) {
#ifdef ZOOKEEPER_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      Log_info("[ZOOKEEPER][%s] total_commands=%" PRIu64, tag, total_commands);
      auto log_or_empty = [&](const char* label, Distribution& dist, const char* unit) {
        if (dist.count() == 0) {
          Log_info("[ZOOKEEPER][%s] %s no samples", tag, label);
        } else {
          auto stats = dist.statistics();
          Log_info("[ZOOKEEPER][%s] %s %s (%s)", tag, label, stats.c_str(), unit);
        }
      };
      log_or_empty("QUEUE_WAIT_MS", queue_wait_ms, "ms");
      log_or_empty("QUEUE_DEPTH", queue_depth, "commands");
      log_or_empty("ZK_LAT_MS", zk_service_ms, "ms");
      log_or_empty("ZK_END_TO_END_MS", end_to_end_ms, "ms");
#else
      (void)tag;
#endif
    }
  };

  class CommandQueue {
    struct QueuedCommand {
      std::shared_ptr<Marshallable> cmd;
#ifdef ZOOKEEPER_STATISTICS
      std::chrono::steady_clock::time_point enqueue_time;
      bool record_stats{true};
#endif
    };
   private:
    std::queue<QueuedCommand> queue;
    std::mutex mutex;
    std::condition_variable cond_var;
#ifdef ZOOKEEPER_STATISTICS
    std::shared_ptr<ZookeeperMetrics> metrics_;
#endif
   public:
    CommandQueue() = default;
    explicit CommandQueue(const std::shared_ptr<ZookeeperMetrics>& metrics)
#ifdef ZOOKEEPER_STATISTICS
        : metrics_(metrics) {}
#else
        { (void) metrics; }
#endif
   public:
    size_t push(const shared_ptr<Marshallable>& cmd, bool record_stats = true) {
      std::lock_guard<std::mutex> lock(mutex);
      queue.push(
#ifdef ZOOKEEPER_STATISTICS
          QueuedCommand{cmd, std::chrono::steady_clock::now(), record_stats}
#else
          QueuedCommand{cmd}
#endif
      );
#ifdef ZOOKEEPER_STATISTICS
      if (record_stats && metrics_) {
        metrics_->RecordQueueDepth(static_cast<double>(queue.size()));
      }
#else
      (void)record_stats;
#endif
      cond_var.notify_one();
      return queue.size();
    }
    shared_ptr<Marshallable> pop(double* wait_ms = nullptr) {
      std::unique_lock<std::mutex> lock(mutex);
      cond_var.wait(lock, [this]{ return !queue.empty(); });
      auto queued = queue.front();
      queue.pop();
#ifdef ZOOKEEPER_STATISTICS
      double wait_value = 0.0;
      bool has_wait_value = false;
      if (queued.record_stats && metrics_ && queued.cmd != nullptr) {
        auto now = std::chrono::steady_clock::now();
        wait_value = std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(now - queued.enqueue_time).count();
        metrics_->RecordQueueWait(wait_value);
        has_wait_value = true;
      }
      lock.unlock();
      if (wait_ms != nullptr) {
        *wait_ms = has_wait_value ? wait_value : 0.0;
      }
#else
      lock.unlock();
      if (wait_ms != nullptr) {
        *wait_ms = 0.0;
      }
#endif
      return queued.cmd;
    }
    bool empty() {
      std::lock_guard<std::mutex> lock(mutex);
      return queue.empty();
    }
    void close() {
      push(nullptr, false);
    }
  };

  int thread_num_;
  int round_robin_ = 0;
  std::string uri_;

  std::vector<std::thread> threads_;
  // 10000 slots — sized to accommodate the AWS zk_connection_=2500 path
  // plus headroom (mirrors mongodb_connection_thread_pool.h sizing).
  std::vector<std::shared_ptr<ZookeeperKVTableHandler>> zk_handlers_{10000};
  std::vector<std::shared_ptr<CommandQueue>> request_queues_;
  std::shared_ptr<ZookeeperMetrics> metrics_;

 public:

  void ZookeeperHandler(int thread_id) {
    while (true) {
#ifdef ZOOKEEPER_STATISTICS
      double queue_wait_ms = 0.0;
#endif
      shared_ptr<Marshallable> cmd =
          request_queues_[thread_id]->pop(
#ifdef ZOOKEEPER_STATISTICS
              &queue_wait_ms
#else
              nullptr
#endif
          );

      if (cmd == nullptr)
        break;

      SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);

#ifdef ZOOKEEPER_STATISTICS
      auto start_time = std::chrono::high_resolution_clock::now();
#endif

      // Sync ZooKeeper API: blocks this worker thread until the leader has
      // committed via ZAB (majority quorum). The 2026-05-03 sync-API change
      // (vs zoo_aset / zoo_aget) is retained for apples-to-apples fairness
      // with the leader-replies-after-commit rule.
      if (parsed_cmd.IsRead())
        (void)zk_handlers_[thread_id]->Read(parsed_cmd.key_);
      else if (parsed_cmd.IsWrite())
        (void)zk_handlers_[thread_id]->Write(parsed_cmd.key_, parsed_cmd.value_);
      else
        break;

#ifdef ZOOKEEPER_STATISTICS
      auto end_time = std::chrono::high_resolution_clock::now();
      auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
      if (metrics_) {
        metrics_->RecordService(duration.count(), queue_wait_ms);
      }
#endif

      shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
#ifdef ZOOKEEPER_DEBUG
      Log_info("Before cmd_content->zookeeper_finished->Set(1);");
#endif
      if (cmd_content && cmd_content->zookeeper_finished) {
        cmd_content->zookeeper_finished->Set(1);
      }
#ifdef ZOOKEEPER_DEBUG
      Log_info("After cmd_content->zookeeper_finished->Set(1);");
#endif
    }
  }

  void static createHandlers(int i,
                             const std::string uri,
                             std::vector<std::shared_ptr<janus::ZookeeperKVTableHandler>>& handlers) {
    handlers[i] = std::make_shared<janus::ZookeeperKVTableHandler>(uri);
    handlers[i]->Setup();
  }

  ZookeeperConnectionThreadPool(int thread_num, const std::string& uri)
      : thread_num_(thread_num), uri_(uri) {
#ifdef ZOOKEEPER_STATISTICS
    Log_info("[ZOOKEEPER][POOL] init threads=%d uri=%s", thread_num_, uri_.c_str());
#endif
    metrics_ = std::make_shared<ZookeeperMetrics>();
    if (thread_num_ == 0) {
      // loc_id != 0 path: no worker pool needed on followers.
      return;
    }
    for (int i = 0; i < thread_num_; i++) {
      request_queues_.push_back(std::make_shared<CommandQueue>(metrics_));
    }
    std::vector<std::thread> create_connection_threads;
    for (int i = 0; i < thread_num_; i++) {
      create_connection_threads.emplace_back(createHandlers, i, uri_, std::ref(zk_handlers_));
    }
    for (auto& t : create_connection_threads) {
      t.join();
    }
    for (int i = 0; i < thread_num_; i++)
      threads_.push_back(std::thread([this, i]() {
        ZookeeperHandler(i);
      }));
    Log_info("[ZOOKEEPER][POOL] %d workers + queues + handlers initialised "
             "(MongoDB-pattern port)", thread_num_);
  }

  ~ZookeeperConnectionThreadPool() {
  }

  size_t ZookeeperRequest(const shared_ptr<Marshallable>& cmd) {
    if (thread_num_ == 0) {
      Log_warn("[ZOOKEEPER][POOL] thread_num is 0, dropping ZooKeeper request");
      auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
      if (tpc_cmd) {
        auto cmd_content = *(((VecPieceData*)(tpc_cmd->cmd_.get()))->sp_vec_piece_data_->begin());
        if (cmd_content && cmd_content->zookeeper_finished) {
          cmd_content->zookeeper_finished->Set(1);
        }
      }
      return 0;
    }
    auto depth = request_queues_[round_robin_]->push(cmd);
    round_robin_++;
    if (round_robin_ >= thread_num_)
      round_robin_ = 0;
    return depth;
  }

  void DumpStats(const char* tag) {
#ifdef ZOOKEEPER_STATISTICS
    if (metrics_) {
      metrics_->Dump(tag);
    } else {
      Log_info("[ZOOKEEPER][%s] no metrics recorder (thread_num=%d)", tag, thread_num_);
    }
#else
    (void)tag;
#endif
  }

  void Close() {
    if (thread_num_ == 0) {
      DumpStats("FINAL");
      return;
    }
    for (int i = 0; i < thread_num_; i++)
      request_queues_[i]->close();
    for (int i = 0; i < thread_num_; i++) {
      if (threads_[i].joinable()) threads_[i].join();
    }
    DumpStats("FINAL");
  }

  double LatencyMs() {
#ifdef ZOOKEEPER_STATISTICS
    if (!metrics_) {
      return -1;
    }
    std::lock_guard<std::mutex> lock(metrics_->mu);
    if (metrics_->zk_service_ms.count() == 0)
      return -1;
    return metrics_->zk_service_ms.pct50();
#else
    return -1;
#endif
  }
};


}
