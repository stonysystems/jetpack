#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>

#include "mongocxx/client.hpp"
#include "mongocxx/uri.hpp"
#include "mongocxx/options/apm.hpp"
#include "mongocxx/options/client.hpp"
#include "mongocxx/events/topology_changed_event.hpp"
#include "mongocxx/events/topology_description.hpp"
#include "mongocxx/events/server_description.hpp"

#include "../../jm_file_signal.h"

namespace janus {

// MongodbLeaderWatcher monitors a MongoDB replica set for primary changes
// using the mongocxx driver's APM (Application Performance Monitoring)
// topology_changed callbacks. When the driver detects a new primary has been
// elected (topology transitions to "ReplicaSetWithPrimary"), this watcher
// writes a file signal so that Jetpack replicas can trigger recovery.
//
// The mongocxx driver's SDAM (Server Discovery And Monitoring) background
// thread automatically monitors the replica set topology. APM callbacks fire
// on that thread when topology changes occur.
//
// Usage:
//   auto watcher = std::make_shared<MongodbLeaderWatcher>(mongo_uri, hostname);
//   watcher->Start();
//   // ... later ...
//   watcher->Stop();
class MongodbLeaderWatcher {
  std::string mongo_uri_;
  std::string local_host_;
  std::atomic<bool> running_{false};
  std::atomic<bool> had_no_primary_{false};

  // The client is kept alive to maintain the SDAM background monitoring.
  // APM callbacks are registered at construction time via options::client.
  std::unique_ptr<mongocxx::client> client_;

  void OnTopologyChanged(const mongocxx::events::topology_changed_event& event) {
    if (!running_.load()) return;

    auto prev_desc = event.previous_description();
    auto new_desc = event.new_description();

    std::string prev_type(prev_desc.type().data(), prev_desc.type().size());
    std::string new_type(new_desc.type().data(), new_desc.type().size());

    Log_info("[MONGODB-HOOKER] Topology changed: %s -> %s",
             prev_type.c_str(), new_type.c_str());

    // Track whether we've seen a state without primary.
    // We only signal recovery when transitioning FROM no-primary TO with-primary.
    if (new_type == "ReplicaSetNoPrimary" || new_type == "Unknown") {
      had_no_primary_.store(true);
    }

    if (new_type == "ReplicaSetWithPrimary" && had_no_primary_.load()) {
      had_no_primary_.store(false);

      // Find the new primary's host from the server descriptions.
      std::string primary_host;
      auto servers = new_desc.servers();
      for (auto& server : servers) {
        std::string server_type(server.type().data(), server.type().size());
        if (server_type == "RSPrimary") {
          primary_host = std::string(server.host().data(), server.host().size()) +
                         ":" + std::to_string(server.port());
          break;
        }
      }

      Log_info("[MONGODB-HOOKER] New primary elected: %s", primary_host.c_str());
      jm_signal::set_key("mongo", "primary_elected", local_host_);
      Log_info("[MONGODB-HOOKER] Signaled primary_elected for host=%s",
               local_host_.c_str());
    }
  }

 public:
  MongodbLeaderWatcher(const std::string& mongo_uri, const std::string& local_host)
      : mongo_uri_(mongo_uri), local_host_(local_host) {}

  ~MongodbLeaderWatcher() { Stop(); }

  void Start() {
    if (running_.exchange(true)) return;

    try {
      // Set up APM callbacks for topology monitoring.
      mongocxx::options::apm apm_opts;
      apm_opts.on_topology_changed(
          [this](const mongocxx::events::topology_changed_event& event) {
            OnTopologyChanged(event);
          });

      mongocxx::options::client client_opts;
      client_opts.apm_opts(apm_opts);

      // Create the client with APM. The driver's SDAM background thread
      // will automatically start monitoring the replica set topology.
      client_ = std::make_unique<mongocxx::client>(
          mongocxx::uri(mongo_uri_), client_opts);

      Log_info("[MONGODB-HOOKER] Started watching replica set at %s",
               mongo_uri_.c_str());
    } catch (const std::exception& e) {
      Log_warn("[MONGODB-HOOKER] Failed to start watcher: %s", e.what());
      running_ = false;
    }
  }

  void Stop() {
    if (!running_.exchange(false)) return;

    // Destroying the client stops the SDAM background monitoring.
    client_.reset();
    Log_info("[MONGODB-HOOKER] Stopped watching replica set");
  }
};

} // namespace janus
