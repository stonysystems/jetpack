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

  // Fix E2 (set 2026-05-05): per-op pool that mirrors
  // MongodbConnectionThreadPool's design. When batch_size_ <= 1 (the
  // default), EtcdRequest pushes into one of N persistent per-thread
  // queues instead of spawning a fresh std::thread per request that
  // funnelled into a single shared handler_. Each worker thread owns its
  // own EtcdKVTableHandler (own gRPC channel), so concurrent writes
  // don't serialise on a single channel. N = max_inflight_ at
  // construction time (matches mongodb pool sizing on AWS = 2500).
  struct PerOpQueuedCommand {
    bool is_read{false};
    bool is_write{false};
    int key{0};
    int value{0};
    std::shared_ptr<TxPieceData> cmd_content;
    std::chrono::steady_clock::time_point start_time;
    bool stop{false};  // sentinel from Close() to wake the worker
  };
  class PerOpQueue {
   public:
    void push(PerOpQueuedCommand&& qc) {
      std::lock_guard<std::mutex> lk(mu_);
      q_.push(std::move(qc));
      cv_.notify_one();
    }
    PerOpQueuedCommand pop() {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait(lk, [this] { return !q_.empty(); });
      PerOpQueuedCommand qc = std::move(q_.front());
      q_.pop();
      return qc;
    }
   private:
    std::queue<PerOpQueuedCommand> q_;
    std::mutex mu_;
    std::condition_variable cv_;
  };
  int per_op_thread_num_{0};
  std::vector<std::shared_ptr<EtcdKVTableHandler>> per_op_handlers_;
  std::vector<std::unique_ptr<PerOpQueue>> per_op_queues_;
  std::vector<std::thread> per_op_threads_;
  std::atomic<uint32_t> per_op_dispatch_rr_{0};

  void PerOpWorker(int thread_id) {
    auto& q = per_op_queues_[thread_id];
    auto& handler = per_op_handlers_[thread_id];
    while (true) {
      PerOpQueuedCommand qc = q->pop();
      if (qc.stop) break;
      try {
        if (qc.is_read) {
          handler->Read(qc.key);
        } else if (qc.is_write) {
          handler->Write(qc.key, qc.value);
        } else {
          Log_warn("[ETCD][POOL] worker %d: unsupported queued command type", thread_id);
        }
      } catch (const std::exception& e) {
        Log_warn("[ETCD][POOL] worker %d: handler call threw: %s", thread_id, e.what());
      }
      SignalFinished(qc.cmd_content, qc.start_time);
    }
  }

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
    auto* cfg = Config::GetConfig();
    if (cfg != nullptr) {
      batch_size_ = cfg->GetEtcdBatchSize();
      batch_timeout_ms_ = cfg->GetEtcdBatchTimeoutMs();
    }

    // The legacy shared handler_ is kept around only because the
    // batching path's FlushLocked falls back to it when batch_handlers_
    // is empty. The per-op path NEVER uses it under Fix E2.
    if (max_inflight_ > 0) {
      handler_ = std::make_shared<EtcdKVTableHandler>(uri);
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
    } else if (max_inflight_ > 0) {
      // Fix E2: spawn N persistent worker threads, each with its own
      // EtcdKVTableHandler (own gRPC channel). N = max_inflight_ matches
      // MongodbConnectionThreadPool's mongodb_connection_=2500 sizing.
      // Each request enqueues into one of N round-robin queues; the
      // matching worker pops and runs the request through its own
      // handler. No more single-channel serialisation.
      per_op_thread_num_ = max_inflight_;
      Log_info("[ETCD][POOL] per-op pool: thread_num=%d (one handler/queue per worker)", per_op_thread_num_);
      per_op_handlers_.reserve(per_op_thread_num_);
      per_op_queues_.reserve(per_op_thread_num_);
      // Create handlers in parallel (each opens a gRPC channel; doing
      // 2500 sequentially would serialise on TCP setup). Mirrors
      // MongodbConnectionThreadPool::createHandlers.
      std::vector<std::thread> create_threads;
      per_op_handlers_.assign(per_op_thread_num_, nullptr);
      for (int i = 0; i < per_op_thread_num_; ++i) {
        per_op_queues_.push_back(std::make_unique<PerOpQueue>());
        create_threads.emplace_back([this, i, uri]() {
          per_op_handlers_[i] = std::make_shared<EtcdKVTableHandler>(uri);
        });
      }
      for (auto& t : create_threads) t.join();
      per_op_threads_.reserve(per_op_thread_num_);
      for (int i = 0; i < per_op_thread_num_; ++i) {
        per_op_threads_.emplace_back([this, i]() { PerOpWorker(i); });
      }
    }
  }

  ~EtcdConnectionThreadPool() {
    batch_shutdown_.store(true, std::memory_order_relaxed);
    if (batch_timeout_thread_.joinable()) batch_timeout_thread_.join();
    // Wake every per-op worker with a stop sentinel and join. Safe to
    // call even if Close() already drained — workers will just exit
    // immediately on the second sentinel.
    for (auto& q : per_op_queues_) {
      PerOpQueuedCommand stop_qc;
      stop_qc.stop = true;
      q->push(std::move(stop_qc));
    }
    for (auto& t : per_op_threads_) {
      if (t.joinable()) t.join();
    }
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

    // Fix E2 (set 2026-05-05): per-op pool dispatch. The previous
    // implementation spawned `std::thread([..](){ handler_->Read/Write; }).detach()`
    // per request, all funnelling into the single shared handler_'s gRPC
    // channel — that channel serialised concurrent calls and produced
    // the etcd-only conc-1→100 surge (276 → 1788 ms p50). Now: build a
    // queued op, push round-robin across N per-thread queues; the
    // matching worker pops and runs through its OWN handler.
    if (parsed_cmd.IsRead() || parsed_cmd.IsWrite()) {
      verify(per_op_thread_num_ > 0);
      verify(static_cast<int>(per_op_queues_.size()) == per_op_thread_num_);
      PerOpQueuedCommand qc;
      qc.is_read = parsed_cmd.IsRead();
      qc.is_write = parsed_cmd.IsWrite();
      qc.key = parsed_cmd.key_;
      qc.value = parsed_cmd.value_;
      qc.cmd_content = cmd_content;
      qc.start_time = start_time;
      uint32_t idx = per_op_dispatch_rr_.fetch_add(1, std::memory_order_relaxed) % per_op_thread_num_;
      per_op_queues_[idx]->push(std::move(qc));
    } else {
      Log_warn("[ETCD] unsupported command type");
      SignalFinished(cmd_content, start_time);
    }

    return static_cast<size_t>(depth);
  }

  void DumpStats(const char* tag) {
#ifdef ETCD_STATISTICS
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
    // Wait for every in-flight per-op request to be picked up by a
    // worker AND signalled (SignalFinished decrements inflight_ to 0
    // and notifies). Per-op queues drain naturally since EtcdRequest
    // increments inflight_ before pushing and SignalFinished
    // decrements after the request completes.
    {
      std::unique_lock<std::mutex> lock(inflight_mu_);
      inflight_cv_.wait(lock, [this] { return inflight_.load() == 0; });
    }
    // Stop the per-op workers cleanly so the destructor doesn't have
    // to send sentinels under racing teardown. Idempotent — destructor
    // also pushes sentinels and joins; a second sentinel after
    // shutdown is harmless because workers exit on the first one.
    for (auto& q : per_op_queues_) {
      PerOpQueuedCommand stop_qc;
      stop_qc.stop = true;
      q->push(std::move(stop_qc));
    }
    for (auto& t : per_op_threads_) {
      if (t.joinable()) t.join();
    }
    per_op_threads_.clear();
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
