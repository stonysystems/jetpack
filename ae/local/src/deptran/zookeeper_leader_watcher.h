#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <chrono>

#include <zookeeper/zookeeper.h>

#include "../../jm_file_signal.h"

namespace janus {

// Well-known ZooKeeper znode where the current leader writes its identity.
// This is an ephemeral node: when the leader's session expires (crash/kill),
// the node is automatically deleted, triggering watches on all replicas.
constexpr char kZookeeperLeaderPath[] = "/JetPack/leader";

// ZookeeperLeaderWatcher monitors a well-known ZooKeeper znode for leader
// changes using ZooKeeper's native watch mechanism. When the leader znode
// is created or deleted (indicating a new leader election), this watcher
// detects the change and writes a file signal so that Jetpack replicas
// can trigger their own recovery.
//
// ZooKeeper watches are one-shot: after each watch fires, the watcher
// re-registers itself to continue monitoring. This is handled internally
// by the WatchCallback.
//
// Usage:
//   auto watcher = std::make_shared<ZookeeperLeaderWatcher>(zk_uri, hostname);
//   watcher->Start();
//   // ... later ...
//   watcher->Stop();
class ZookeeperLeaderWatcher {
  std::string zk_uri_;
  std::string local_host_;
  std::atomic<bool> running_{false};
  std::atomic<bool> had_no_leader_{false};
  zhandle_t* zh_{nullptr};

  static void DefaultWatcher(zhandle_t* zh, int type, int state,
                              const char* path, void* ctx) {
    (void)zh; (void)type; (void)path;
    auto* self = static_cast<ZookeeperLeaderWatcher*>(ctx);
    if (!self || !self->running_.load()) return;

    // Handle session events.
    if (type == ZOO_SESSION_EVENT) {
      if (state == ZOO_CONNECTED_STATE) {
        Log_info("[ZOOKEEPER-HOOKER] Session connected, setting up watch");
        self->SetWatch();
      } else if (state == ZOO_EXPIRED_SESSION_STATE) {
        Log_warn("[ZOOKEEPER-HOOKER] Session expired, reconnecting");
        self->Reconnect();
      }
    }
  }

  // Watch callback: fires when the leader znode changes.
  // ZooKeeper watches are one-shot, so we re-register after each event.
  static void LeaderWatchCallback(zhandle_t* zh, int type, int state,
                                   const char* path, void* ctx) {
    (void)zh; (void)state; (void)path;
    auto* self = static_cast<ZookeeperLeaderWatcher*>(ctx);
    if (!self || !self->running_.load()) return;

    if (type == ZOO_DELETED_EVENT) {
      // Leader's ephemeral node was deleted — leader crashed or disconnected.
      Log_info("[ZOOKEEPER-HOOKER] Leader znode deleted (leader lost)");
      self->had_no_leader_.store(true);
      // Re-register watch to detect when new leader appears.
      self->SetWatch();
    } else if (type == ZOO_CREATED_EVENT) {
      // New leader created the znode.
      if (self->had_no_leader_.load()) {
        self->had_no_leader_.store(false);
        self->OnLeaderChange();
      }
      // Re-register watch.
      self->SetWatch();
    } else if (type == ZOO_CHANGED_EVENT) {
      // Leader znode data changed — could mean a new leader wrote its identity.
      if (self->had_no_leader_.load()) {
        self->had_no_leader_.store(false);
        self->OnLeaderChange();
      }
      // Re-register watch.
      self->SetWatch();
    }
  }

  void SetWatch() {
    if (!zh_ || !running_.load()) return;
    struct Stat stat;
    int rc = zoo_wexists(zh_, kZookeeperLeaderPath, LeaderWatchCallback,
                         this, &stat);
    if (rc == ZNONODE) {
      // Node doesn't exist — the watch is still set and will fire on creation.
      had_no_leader_.store(true);
      Log_info("[ZOOKEEPER-HOOKER] Leader znode absent, watching for creation");
    } else if (rc == ZOK) {
      Log_info("[ZOOKEEPER-HOOKER] Leader znode exists, watching for changes");
    } else {
      Log_warn("[ZOOKEEPER-HOOKER] zoo_wexists failed: %s", zerror(rc));
    }
  }

  void Reconnect() {
    if (zh_) {
      zookeeper_close(zh_);
      zh_ = nullptr;
    }
    zh_ = zookeeper_init(zk_uri_.c_str(), DefaultWatcher,
                         30000, nullptr, this, 0);
    if (!zh_) {
      Log_warn("[ZOOKEEPER-HOOKER] Reconnect failed to %s", zk_uri_.c_str());
    }
  }

  void OnLeaderChange() {
    Log_info("[ZOOKEEPER-HOOKER] New ZooKeeper leader detected");
    jm_signal::set_key("zookeeper", "primary_elected", local_host_);
    Log_info("[ZOOKEEPER-HOOKER] Signaled primary_elected for host=%s",
             local_host_.c_str());
  }

 public:
  ZookeeperLeaderWatcher(const std::string& zk_uri, const std::string& local_host)
      : zk_uri_(zk_uri), local_host_(local_host) {}

  ~ZookeeperLeaderWatcher() { Stop(); }

  void Start() {
    if (running_.exchange(true)) return;

    zh_ = zookeeper_init(zk_uri_.c_str(), DefaultWatcher,
                         30000, nullptr, this, 0);
    if (!zh_) {
      Log_warn("[ZOOKEEPER-HOOKER] Failed to connect to %s", zk_uri_.c_str());
      running_ = false;
      return;
    }

    Log_info("[ZOOKEEPER-HOOKER] Started watching %s at %s",
             kZookeeperLeaderPath, zk_uri_.c_str());
    SetWatch();
  }

  void Stop() {
    if (!running_.exchange(false)) return;

    if (zh_) {
      zookeeper_close(zh_);
      zh_ = nullptr;
    }
    Log_info("[ZOOKEEPER-HOOKER] Stopped watching %s", kZookeeperLeaderPath);
  }
};

} // namespace janus
