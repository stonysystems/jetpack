#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <inttypes.h>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <utility>
#include <vector>

#include "constants.h"
#include "config.h"
#include "etcd_kv_table_handler.h"
#include "RW_command.h"

namespace janus {

class EtcdConnectionThreadPool {

  struct EtcdMetrics {
#ifdef ETCD_STATISTICS
    std::mutex mu;
    Distribution queue_wait_ms;
    Distribution queue_depth;
    Distribution etcd_service_ms;
    Distribution end_to_end_ms;
    uint64_t total_commands{0};
#endif
#ifdef ETCD_INNER_DEBUG
    // E2-redo phase breakdown. spawn_to_run_ms = thread-spawn + scheduler
    // queueing (t_enqueue → t_dequeue inside the worker). handler_ms = pure
    // handler->{Read,Write,BatchTxn} call duration (t_pre → t_post). total_ms
    // = t_enqueue → t_post. Together they answer: queue-wait dominant?
    // handler dominant? See E2-redo plan in TODO.md.
    std::mutex inner_mu;
    Distribution inner_spawn_to_run_ms;
    Distribution inner_handler_ms;
    Distribution inner_total_ms;
    uint64_t inner_samples{0};
#endif

    void RecordQueueDepth(double depth) {
#ifdef ETCD_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      queue_depth.append(depth);
#endif
    }

    void RecordQueueWait(double wait_ms) {
#ifdef ETCD_STATISTICS
      if (wait_ms < 0) return;
      std::lock_guard<std::mutex> lock(mu);
      queue_wait_ms.append(wait_ms);
#endif
    }

    void RecordService(double service_ms, double queue_wait_ms_value) {
#ifdef ETCD_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      etcd_service_ms.append(service_ms);
      end_to_end_ms.append(service_ms + queue_wait_ms_value);
      total_commands++;
#endif
    }

    void RecordInner(double spawn_to_run_ms, double handler_ms,
                     double total_ms) {
#ifdef ETCD_INNER_DEBUG
      std::lock_guard<std::mutex> lock(inner_mu);
      inner_spawn_to_run_ms.append(spawn_to_run_ms);
      inner_handler_ms.append(handler_ms);
      inner_total_ms.append(total_ms);
      inner_samples++;
#else
      (void)spawn_to_run_ms;
      (void)handler_ms;
      (void)total_ms;
#endif
    }

    void Dump(const char* tag) {
#ifdef ETCD_STATISTICS
      std::lock_guard<std::mutex> lock(mu);
      Log_info("[ETCD][%s] total_commands=%" PRIu64, tag, total_commands);
      auto log_or_empty = [&](const char* label, Distribution& dist, const char* unit) {
        if (dist.count() == 0) {
          Log_info("[ETCD][%s] %s no samples", tag, label);
        } else {
          auto stats = dist.statistics();
          Log_info("[ETCD][%s] %s %s (%s)", tag, label, stats.c_str(), unit);
        }
      };
      log_or_empty("QUEUE_WAIT_MS", queue_wait_ms, "ms");
      log_or_empty("QUEUE_DEPTH", queue_depth, "commands");
      log_or_empty("ETCD_LAT_MS", etcd_service_ms, "ms");
      log_or_empty("ETCD_END_TO_END_MS", end_to_end_ms, "ms");
#else
      (void)tag;
#endif
#ifdef ETCD_INNER_DEBUG
      std::lock_guard<std::mutex> lock(inner_mu);
      Log_info("[ETCD-INNER][%s] inner_samples=%" PRIu64, tag, inner_samples);
      auto inner_log_or_empty = [&](const char* label, Distribution& dist) {
        if (dist.count() == 0) {
          Log_info("[ETCD-INNER][%s] %s no samples", tag, label);
        } else {
          auto stats = dist.statistics();
          Log_info("[ETCD-INNER][%s] %s %s (ms)", tag, label, stats.c_str());
        }
      };
      inner_log_or_empty("SPAWN_TO_RUN", inner_spawn_to_run_ms);
      inner_log_or_empty("HANDLER", inner_handler_ms);
      inner_log_or_empty("TOTAL", inner_total_ms);
#endif
    }
  };

  int max_inflight_;
  std::atomic<int> inflight_{0};
  std::mutex inflight_mu_;
  std::condition_variable inflight_cv_;
  std::shared_ptr<EtcdKVTableHandler> handler_;
  std::shared_ptr<EtcdMetrics> metrics_;

  // Batching state. When batch_size_ > 1, EtcdRequest enqueues into
  // batch_buf_ instead of dispatching directly; the buffer is flushed as a
  // single etcd Txn when it hits batch_size_ OR when batch_timeout_ms_
  // elapses since the first enqueue in the current batch. batch_size_ <= 1
  // (the default) disables batching and preserves the original per-op
  // dispatch path.
  struct PendingOp {
    bool is_write;
    int key;
    int value;
    std::shared_ptr<TxPieceData> cmd_content;
    std::chrono::steady_clock::time_point start_time;
  };
  int batch_size_{1};
  int batch_timeout_ms_{0};
  std::mutex batch_mu_;
  std::vector<PendingOp> batch_buf_;
  std::chrono::steady_clock::time_point batch_first_enqueue_;
  std::atomic<bool> batch_shutdown_{false};
  std::thread batch_timeout_thread_;

  // Pool of dedicated handlers for batched Txn dispatch. The gRPC channel
  // inside each etcd::SyncClient serialises concurrent calls on its stream,
  // so if we funnel every flush through one handler the per-request wait
  // grows with concurrency (the V2-batch pathology observed with a single
  // handler). Round-robin across batch_handlers_ to parallelise flushes.
  std::vector<std::shared_ptr<EtcdKVTableHandler>> batch_handlers_;
  std::atomic<uint32_t> batch_handler_rr_{0};
  static constexpr int kBatchHandlerPoolSize = 8;

  // Caller must hold batch_mu_. Moves the pending buffer out and spawns a
  // detached thread that runs the Txn and signals every waiter.
  void FlushLocked() {
    if (batch_buf_.empty()) return;
    auto ops = std::move(batch_buf_);
    batch_buf_.clear();
    // Pick a handler by round-robin so concurrent flushes don't queue on
    // the same gRPC channel.
    uint32_t idx = batch_handler_rr_.fetch_add(1, std::memory_order_relaxed);
    auto handler = batch_handlers_.empty()
        ? handler_
        : batch_handlers_[idx % batch_handlers_.size()];
    std::thread([this, ops = std::move(ops), handler]() mutable {
      std::vector<EtcdKVTableHandler::BatchOp> txn_ops;
      txn_ops.reserve(ops.size());
      for (const auto& op : ops) {
        txn_ops.emplace_back(op.is_write, op.key, op.value);
      }
      try {
        handler->BatchTxn(txn_ops);
      } catch (const std::exception& e) {
        Log_warn("[ETCD] BatchTxn threw: %s", e.what());
      }
      for (const auto& op : ops) {
        SignalFinished(op.cmd_content, op.start_time);
      }
    }).detach();
  }

  void BatchTimeoutLoop() {
    const int poll_ms = std::max(1, batch_timeout_ms_ / 4);
    while (!batch_shutdown_.load(std::memory_order_relaxed)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(poll_ms));
      std::unique_lock<std::mutex> lock(batch_mu_);
      if (batch_buf_.empty()) continue;
      auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - batch_first_enqueue_).count();
      if (elapsed >= batch_timeout_ms_) {
        FlushLocked();
      }
    }
  }

  void SignalFinished(const std::shared_ptr<TxPieceData>& cmd_content,
                      const std::chrono::steady_clock::time_point& start_time) {
#ifdef ETCD_STATISTICS
    if (metrics_) {
      auto end_time = std::chrono::steady_clock::now();
      auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
      metrics_->RecordService(duration.count(), 0.0);
    }
#else
    (void)start_time;
#endif
    if (cmd_content && cmd_content->etcd_finished) {
      cmd_content->etcd_finished->Set(1);
    }
    int remaining = inflight_.fetch_sub(1) - 1;
    if (remaining <= 0) {
      std::lock_guard<std::mutex> lock(inflight_mu_);
      inflight_cv_.notify_all();
    }
  }

  void SignalDropped(const std::shared_ptr<TxPieceData>& cmd_content) {
    if (cmd_content && cmd_content->etcd_finished) {
      cmd_content->etcd_finished->Set(1);
    }
  }

 public:
  EtcdConnectionThreadPool(int max_inflight, const std::string& uri)
      : max_inflight_(max_inflight),
        metrics_(std::make_shared<EtcdMetrics>()) {
#ifdef ETCD_STATISTICS
    Log_info("[ETCD][POOL] init max_inflight=%d uri=%s", max_inflight_, uri.c_str());
#endif
    if (max_inflight_ > 0) {
      handler_ = std::make_shared<EtcdKVTableHandler>(uri);
    }
    auto* cfg = Config::GetConfig();
    if (cfg != nullptr) {
      batch_size_ = cfg->GetEtcdBatchSize();
      batch_timeout_ms_ = cfg->GetEtcdBatchTimeoutMs();
    }
    if (batch_size_ > 1) {
      Log_info("[ETCD][POOL] client-side batching enabled: size=%d timeout_ms=%d handler_pool=%d",
               batch_size_, batch_timeout_ms_, kBatchHandlerPoolSize);
      batch_handlers_.reserve(kBatchHandlerPoolSize);
      for (int i = 0; i < kBatchHandlerPoolSize; ++i) {
        batch_handlers_.push_back(std::make_shared<EtcdKVTableHandler>(uri));
      }
      if (batch_timeout_ms_ > 0) {
        batch_timeout_thread_ = std::thread([this]() { BatchTimeoutLoop(); });
      }
    }
  }

  ~EtcdConnectionThreadPool() {
    batch_shutdown_.store(true, std::memory_order_relaxed);
    if (batch_timeout_thread_.joinable()) batch_timeout_thread_.join();
  }

  size_t EtcdRequest(const shared_ptr<Marshallable>& cmd) {
    if (max_inflight_ == 0) {
      Log_warn("[ETCD][POOL] max_inflight is 0, dropping Etcd request");
      auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
      if (tpc_cmd) {
        auto cmd_content = *(((VecPieceData*)(tpc_cmd->cmd_.get()))->sp_vec_piece_data_->begin());
        SignalDropped(cmd_content);
      }
      return 0;
    }

    verify(handler_ != nullptr);

    int depth = inflight_.fetch_add(1) + 1;
    if (metrics_) {
      metrics_->RecordQueueDepth(static_cast<double>(depth));
    }

    SimpleRWCommand parsed_cmd = SimpleRWCommand(cmd);
    auto tpc_cmd = dynamic_pointer_cast<TpcCommitCommand>(cmd);
    verify(tpc_cmd != nullptr);
    auto cmd_content = *(((VecPieceData*)(tpc_cmd->cmd_.get()))->sp_vec_piece_data_->begin());
    auto start_time = std::chrono::steady_clock::now();

    // Batching path: enqueue into the shared buffer; flush when the buffer
    // hits batch_size_ (the time-based trigger is handled by the background
    // BatchTimeoutLoop thread). Dropping straight into the non-batching
    // path below when batch_size_ <= 1.
    if (batch_size_ > 1 && (parsed_cmd.IsRead() || parsed_cmd.IsWrite())) {
      PendingOp op;
      op.is_write = parsed_cmd.IsWrite();
      op.key = parsed_cmd.key_;
      op.value = parsed_cmd.value_;
      op.cmd_content = cmd_content;
      op.start_time = start_time;
      std::unique_lock<std::mutex> lock(batch_mu_);
      if (batch_buf_.empty()) {
        batch_first_enqueue_ = std::chrono::steady_clock::now();
      }
      batch_buf_.push_back(std::move(op));
      if (static_cast<int>(batch_buf_.size()) >= batch_size_) {
        FlushLocked();
      }
      return static_cast<size_t>(depth);
    }

    if (parsed_cmd.IsRead()) {
#if JANUS_ETCD_HAS_PPLX
      try {
        handler_->ReadAsync(parsed_cmd.key_).then([
            this,
            cmd_content,
            cmd,
            start_time
          ](pplx::task<etcd::Response> response_task) {
          (void)cmd;
          try {
            auto response = response_task.get();
            (void)response;
          } catch (const std::exception& e) {
            Log_warn("[ETCD] read failed: %s", e.what());
          }
#ifdef ETCD_INNER_DEBUG
          auto t_post = std::chrono::steady_clock::now();
          if (metrics_) {
            auto handler_ms = std::chrono::duration_cast<std::chrono::microseconds>(
                t_post - start_time).count() / 1000.0;
            metrics_->RecordInner(0.0, handler_ms, handler_ms);
          }
#endif
          SignalFinished(cmd_content, start_time);
        });
      } catch (const std::exception& e) {
        Log_warn("[ETCD] read enqueue failed: %s", e.what());
        SignalFinished(cmd_content, start_time);
      }
#else
      const int key = parsed_cmd.key_;
      std::thread([this, cmd_content, key, start_time]() {
#ifdef ETCD_INNER_DEBUG
        auto t_dequeue = std::chrono::steady_clock::now();
#endif
        handler_->Read(key);
#ifdef ETCD_INNER_DEBUG
        auto t_post = std::chrono::steady_clock::now();
        if (metrics_) {
          auto spawn_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_dequeue - start_time).count() / 1000.0;
          auto handler_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_post - t_dequeue).count() / 1000.0;
          auto total_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_post - start_time).count() / 1000.0;
          metrics_->RecordInner(spawn_ms, handler_ms, total_ms);
        }
#endif
        SignalFinished(cmd_content, start_time);
      }).detach();
#endif
    } else if (parsed_cmd.IsWrite()) {
#if JANUS_ETCD_HAS_PPLX
      try {
        handler_->WriteAsync(parsed_cmd.key_, parsed_cmd.value_).then([
            this,
            cmd_content,
            cmd,
            start_time
          ](pplx::task<etcd::Response> response_task) {
          (void)cmd;
          try {
            auto response = response_task.get();
            (void)response;
          } catch (const std::exception& e) {
            Log_warn("[ETCD] write failed: %s", e.what());
          }
#ifdef ETCD_INNER_DEBUG
          auto t_post = std::chrono::steady_clock::now();
          if (metrics_) {
            auto handler_ms = std::chrono::duration_cast<std::chrono::microseconds>(
                t_post - start_time).count() / 1000.0;
            metrics_->RecordInner(0.0, handler_ms, handler_ms);
          }
#endif
          SignalFinished(cmd_content, start_time);
        });
      } catch (const std::exception& e) {
        Log_warn("[ETCD] write enqueue failed: %s", e.what());
        SignalFinished(cmd_content, start_time);
      }
#else
      const int key = parsed_cmd.key_;
      const int value = parsed_cmd.value_;
      std::thread([this, cmd_content, key, value, start_time]() {
#ifdef ETCD_INNER_DEBUG
        auto t_dequeue = std::chrono::steady_clock::now();
#endif
        handler_->Write(key, value);
#ifdef ETCD_INNER_DEBUG
        auto t_post = std::chrono::steady_clock::now();
        if (metrics_) {
          auto spawn_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_dequeue - start_time).count() / 1000.0;
          auto handler_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_post - t_dequeue).count() / 1000.0;
          auto total_ms = std::chrono::duration_cast<std::chrono::microseconds>(
              t_post - start_time).count() / 1000.0;
          metrics_->RecordInner(spawn_ms, handler_ms, total_ms);
        }
#endif
        SignalFinished(cmd_content, start_time);
      }).detach();
#endif
    } else {
      Log_warn("[ETCD] unsupported command type");
      SignalFinished(cmd_content, start_time);
    }

    return static_cast<size_t>(depth);
  }

  void DumpStats(const char* tag) {
#if defined(ETCD_STATISTICS) || defined(ETCD_INNER_DEBUG)
    if (metrics_) {
      metrics_->Dump(tag);
    } else {
      Log_info("[ETCD][%s] no metrics recorder (max_inflight=%d)", tag, max_inflight_);
    }
#else
    (void)tag;
#endif
  }

  void Close() {
    // Drain any pending batched ops so their waiters don't stall forever.
    {
      std::unique_lock<std::mutex> blk(batch_mu_);
      FlushLocked();
    }
    std::unique_lock<std::mutex> lock(inflight_mu_);
    inflight_cv_.wait(lock, [this] { return inflight_.load() == 0; });
    DumpStats("FINAL");
  }

  double LatencyMs() {
#ifdef ETCD_STATISTICS
    if (!metrics_) {
      return -1;
    }
    std::lock_guard<std::mutex> lock(metrics_->mu);
    if (metrics_->etcd_service_ms.count() == 0)
      return -1;
    return metrics_->etcd_service_ms.pct50();
#else
    return -1;
#endif
  }
};


}
