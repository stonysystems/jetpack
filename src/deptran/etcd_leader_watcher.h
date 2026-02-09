#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "etcd_kv_table_handler.h"
#include "../../jm_file_signal.h"

#if JANUS_ETCD_HAS_PPLX
#include <etcd/Watcher.hpp>
#endif

namespace janus {

// Well-known etcd key where the current leader writes its identity.
// When this key changes (PUT event), it means a new leader was elected.
constexpr char kEtcdLeaderKey[] = "JetPack/leader";

// EtcdLeaderWatcher monitors a well-known etcd key for leader changes.
// When a new leader is elected and writes to the leader key, this watcher
// detects the change and writes a file signal so that Jetpack replicas
// can trigger their own recovery.
//
// Usage:
//   auto watcher = std::make_shared<EtcdLeaderWatcher>(etcd_uri, hostname);
//   watcher->Start();
//   // ... later ...
//   watcher->Stop();
class EtcdLeaderWatcher {
  std::string etcd_uri_;
  std::string local_host_;
  std::atomic<bool> running_{false};

#if JANUS_ETCD_HAS_PPLX
  std::unique_ptr<etcd::Watcher> watcher_;
#else
  std::thread poll_thread_;
#endif

  void OnLeaderChange(const std::string& new_leader_value) {
    Log_info("[ETCD-HOOKER] Leader change detected: %s", new_leader_value.c_str());
    jm_signal::set_key("etcd", "primary_elected", local_host_);
    Log_info("[ETCD-HOOKER] Signaled primary_elected for host=%s", local_host_.c_str());
  }

 public:
  EtcdLeaderWatcher(const std::string& etcd_uri, const std::string& local_host)
      : etcd_uri_(etcd_uri), local_host_(local_host) {}

  ~EtcdLeaderWatcher() { Stop(); }

  void Start() {
    if (running_.exchange(true)) return;

#if JANUS_ETCD_HAS_PPLX
    // Use etcd Watcher API for efficient event-driven leader change detection.
    try {
      watcher_ = std::make_unique<etcd::Watcher>(
          etcd_uri_, kEtcdLeaderKey,
          [this](etcd::Response response) {
            if (!running_.load()) return;
            if (response.is_ok()) {
              for (const auto& event : response.events()) {
                if (event.event_type() == etcd::Event::EventType::PUT) {
                  if (event.has_kv()) {
                    OnLeaderChange(event.kv().as_string());
                  } else {
                    OnLeaderChange("");
                  }
                }
              }
            } else {
              Log_warn("[ETCD-HOOKER] Watch response error: %s",
                       response.error_message().c_str());
            }
          });
      Log_info("[ETCD-HOOKER] Started watching %s at %s",
               kEtcdLeaderKey, etcd_uri_.c_str());
    } catch (const std::exception& e) {
      Log_warn("[ETCD-HOOKER] Failed to start watcher: %s", e.what());
      running_ = false;
    }
#else
    // Fallback: poll the leader key periodically using SyncClient.
    poll_thread_ = std::thread([this]() {
      try {
        etcd::SyncClient client(etcd_uri_);
        std::string last_value;
        bool first_read = true;

        while (running_.load()) {
          try {
            auto response = client.get(kEtcdLeaderKey);
            if (response.is_ok()) {
              std::string current_value = response.value().as_string();
              if (first_read) {
                last_value = current_value;
                first_read = false;
              } else if (current_value != last_value) {
                last_value = current_value;
                OnLeaderChange(current_value);
              }
            }
          } catch (const std::exception& e) {
            Log_warn("[ETCD-HOOKER] Poll error: %s", e.what());
          }
          // Poll every 100ms.
          std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
      } catch (const std::exception& e) {
        Log_warn("[ETCD-HOOKER] Poll thread failed: %s", e.what());
      }
    });
    Log_info("[ETCD-HOOKER] Started polling %s at %s",
             kEtcdLeaderKey, etcd_uri_.c_str());
#endif
  }

  void Stop() {
    if (!running_.exchange(false)) return;

#if JANUS_ETCD_HAS_PPLX
    if (watcher_) {
      watcher_->Cancel();
      watcher_.reset();
    }
#else
    if (poll_thread_.joinable()) {
      poll_thread_.join();
    }
#endif
    Log_info("[ETCD-HOOKER] Stopped watching %s", kEtcdLeaderKey);
  }
};

} // namespace janus
