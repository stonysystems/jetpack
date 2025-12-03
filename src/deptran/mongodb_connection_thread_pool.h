#pragma once

#include <thread>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <chrono>
#include <cmath>
#include <inttypes.h>
#include "constants.h"
#include "mongodb_kv_table_handler.h"
#include "RW_command.h"

namespace janus {

class MongodbConnectionThreadPool {

  struct MongoMetrics {
#ifdef MONGODB_STATISTICS
    std::mutex mu;
    Distribution queue_wait_ms;
    Distribution queue_depth;
    Distribution mongo_service_ms;
    Distribution end_to_end_ms;
    uint64_t total_commands{0};
#endif

    void RecordQueueDepth(double depth) {
#ifdef MONGODB_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      queue_depth.append(depth);
#endif
    }

    void RecordQueueWait(double wait_ms) {
#ifdef MONGODB_STATISTICS
      if (wait_ms < 0) return;
      std::lock_guard<std::mutex> lock(mu);
      queue_wait_ms.append(wait_ms);
#endif
    }

    void RecordService(double service_ms, double queue_wait_ms_value) {
#ifdef MONGODB_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      mongo_service_ms.append(service_ms);
      end_to_end_ms.append(service_ms + queue_wait_ms_value);
      total_commands++;
#endif
    }

    void Dump(const char* tag) {
#ifdef MONGODB_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      Log_info("[MONGODB][%s] total_commands=%" PRIu64, tag, total_commands);
      auto log_or_empty = [&](const char* label, Distribution& dist, const char* unit) {
        if (dist.count() == 0) {
          Log_info("[MONGODB][%s] %s no samples", tag, label);
        } else {
          auto stats = dist.statistics();
          Log_info("[MONGODB][%s] %s %s (%s)", tag, label, stats.c_str(), unit);
        }
      };
      log_or_empty("QUEUE_WAIT_MS", queue_wait_ms, "ms");
      log_or_empty("QUEUE_DEPTH", queue_depth, "commands");
      log_or_empty("MONGO_LAT_MS", mongo_service_ms, "ms");
      log_or_empty("MONGO_END_TO_END_MS", end_to_end_ms, "ms");
#else
      (void)tag;
#endif
    }
  };

  class CommandQueue {
    struct QueuedCommand {
      std::shared_ptr<Marshallable> cmd;
#ifdef MONGODB_STATISTICS
      std::chrono::steady_clock::time_point enqueue_time;
      bool record_stats{true};
#endif
    };
   private:
    std::queue<QueuedCommand> queue;
    std::mutex mutex;
    std::condition_variable cond_var;
#ifdef MONGODB_STATISTICS
    std::shared_ptr<MongoMetrics> metrics_;
#endif
   public:
    CommandQueue() = default;
    explicit CommandQueue(const std::shared_ptr<MongoMetrics>& metrics)
#ifdef MONGODB_STATISTICS
        : metrics_(metrics) {}
#else
        { (void) metrics; }
#endif
   public:
    void push(const shared_ptr<Marshallable>& cmd, bool record_stats = true) {
      std::lock_guard<std::mutex> lock(mutex);
      queue.push(
#ifdef MONGODB_STATISTICS
          QueuedCommand{cmd, std::chrono::steady_clock::now(), record_stats}
#else
          QueuedCommand{cmd}
#endif
      );
#ifdef MONGODB_STATISTICS
      if (record_stats && metrics_) {
        metrics_->RecordQueueDepth(static_cast<double>(queue.size()));
      }
#else
      (void)record_stats;
#endif
      cond_var.notify_one();
    }
    shared_ptr<Marshallable> pop(double* wait_ms = nullptr) {
      std::unique_lock<std::mutex> lock(mutex);
      cond_var.wait(lock, [this]{ return !queue.empty(); });
      auto queued = queue.front();
      queue.pop();
#ifdef MONGODB_STATISTICS
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
  std::vector<std::shared_ptr<MongodbKVTableHandler>> mongodb_handlers_{10000};
  std::vector<std::shared_ptr<CommandQueue>> request_queues_;
  CommandQueue finished_queue_;
  std::shared_ptr<MongoMetrics> metrics_;

 public:

  void MongodbHandler(int thread_id) {
    while (true) {
#ifdef MONGODB_STATISTICS
      double queue_wait_ms = 0.0;
#endif
      shared_ptr<Marshallable> cmd =
          request_queues_[thread_id]->pop(
#ifdef MONGODB_STATISTICS
              &queue_wait_ms
#else
              nullptr
#endif
          );
      
      if (cmd == nullptr)
        break;

      SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);

#ifdef MONGODB_STATISTICS
      auto start_time = std::chrono::high_resolution_clock::now();
#endif

      if (parsed_cmd.IsRead())
        mongodb_handlers_[thread_id]->Read(parsed_cmd.key_);
      else if (parsed_cmd.IsWrite())
        mongodb_handlers_[thread_id]->Write(parsed_cmd.key_, parsed_cmd.value_);
      else
        break;

#ifdef MONGODB_STATISTICS
      auto end_time = std::chrono::high_resolution_clock::now();
      auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
      if (metrics_) {
        metrics_->RecordService(duration.count(), queue_wait_ms);
      }
#endif

      // finished_queue_.push(cmd);
      shared_ptr<TxPieceData> cmd_content = *(((VecPieceData*)(dynamic_pointer_cast<TpcCommitCommand>(cmd)->cmd_.get()))->sp_vec_piece_data_->begin());
#ifdef MONGODB_DEBUG
      Log_info("Before cmd_content->mongodb_finished->Set(1);");
#endif
      cmd_content->mongodb_finished->Set(1);
#ifdef MONGODB_DEBUG
      Log_info("After cmd_content->mongodb_finished->Set(1);");
#endif
    }
  }

  void static createHandlers(int i,
                             const std::string uri,
                             std::vector<std::shared_ptr<janus::MongodbKVTableHandler>>& handlers) {
    handlers[i] = std::make_shared<janus::MongodbKVTableHandler>(uri);
  }

  MongodbConnectionThreadPool(int thread_num, const std::string& uri)
      : thread_num_(thread_num), uri_(uri) {
#ifdef MONGODB_STATISTICS
    Log_info("[MONGODB][POOL] init threads=%d uri=%s", thread_num_, uri_.c_str());
#endif
    metrics_ = std::make_shared<MongoMetrics>();
    for (int i = 0; i < thread_num; i++) {
      request_queues_.push_back(std::make_shared<CommandQueue>(metrics_));
    }
    std::vector<std::thread> create_connection_threads;
    for (int i = 0; i < thread_num; i++) {
      create_connection_threads.emplace_back(createHandlers, i, uri_, std::ref(mongodb_handlers_));
    }
    for (auto& t : create_connection_threads) {
      t.join();
    }
    for (int i = 0; i < thread_num; i++)
      threads_.push_back(std::thread([this, i]() {
        MongodbHandler(i);
      }));
  }

  ~MongodbConnectionThreadPool() {

  }

  void MongodbRequest(const shared_ptr<Marshallable>& cmd) {
    if (thread_num_ == 0) {
      Log_warn("[MONGODB][POOL] thread_num is 0, dropping MongoDB request");
      return;
    }
    request_queues_[round_robin_]->push(cmd);
    round_robin_++;
    if (round_robin_ >= thread_num_)
      round_robin_ = 0;
  }

  shared_ptr<Marshallable> MongodbFinishedPop() {
    return finished_queue_.pop();
  }

  bool MongodbFinishedEmpty() {
    return finished_queue_.empty();
  }

  void DumpStats(const char* tag) {
#ifdef MONGODB_STATISTICS
    if (metrics_) {
      metrics_->Dump(tag);
    } else {
      Log_info("[MONGODB][%s] no metrics recorder (thread_num=%d)", tag, thread_num_);
    }
#else
    (void)tag;
#endif
  }

  void Close() {
    for (int i = 0; i < thread_num_; i++)
      request_queues_[i]->close();
    for (int i = 0; i < thread_num_; i++)
      threads_[i].join();
    finished_queue_.close();
    DumpStats("FINAL");
  }

  double LatencyMs() {
#ifdef MONGODB_STATISTICS
    if (!metrics_) {
      return -1;
    }
    std::lock_guard<std::mutex> lock(metrics_->mu);
    if (metrics_->mongo_service_ms.count() == 0)
      return -1;
    return metrics_->mongo_service_ms.pct50();
#else
    return -1;
#endif
  }
};


}
