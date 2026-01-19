#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <inttypes.h>
#include <mutex>
#include <string>
#include <thread>

#include "constants.h"
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
  }

  ~EtcdConnectionThreadPool() {
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
          SignalFinished(cmd_content, start_time);
        });
      } catch (const std::exception& e) {
        Log_warn("[ETCD] read enqueue failed: %s", e.what());
        SignalFinished(cmd_content, start_time);
      }
#else
      const int key = parsed_cmd.key_;
      std::thread([this, cmd_content, key, start_time]() {
        handler_->Read(key);
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
        handler_->Write(key, value);
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
