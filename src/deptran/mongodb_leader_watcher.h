#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "mongocxx/client.hpp"
#include "mongocxx/uri.hpp"
#include "mongocxx/options/apm.hpp"
#include "mongocxx/options/client.hpp"
#include "mongocxx/events/topology_changed_event.hpp"
#include "mongocxx/events/topology_description.hpp"
#include "mongocxx/events/server_description.hpp"

#include "../../jm_file_signal.h"
#include "mongodb_kv_table_handler.h"

namespace janus {

// MongodbLeaderWatcher monitors a MongoDB replica set for primary changes
// using the mongocxx driver's APM (Application Performance Monitoring)
// topology_changed callbacks. When the driver detects a new primary has been
// elected (topology transitions to "ReplicaSetWithPrimary"), this watcher
// writes a file signal so that Jetpack replicas can trigger recovery.
//
// The signal carries the new primary's replica-set term (the view id),
// "mongo:primary_elected term=T", plus loc=L when the primary's host is the
// host of replica locale L, so that with a shared signal file only that
// replica coordinates. No term in the primary's hello: no signal. The
// callback only parses and appends a line; it issues no driver commands.
//
// The mongocxx driver's SDAM (Server Discovery And Monitoring) background
// thread automatically monitors the replica set topology. APM callbacks fire
// on that thread when topology changes occur.
//
// Usage:
//   auto watcher = std::make_shared<MongodbLeaderWatcher>(mongo_uri, hostname, replica_hosts);
//   watcher->Start();
//   // ... later ...
//   watcher->Stop();
class MongodbLeaderWatcher {
  std::string mongo_uri_;
  std::string local_host_;
  std::vector<std::string> replica_hosts_;  // locale order, host part only
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
    // We only signal recovery when transitioning FROM no-primary TO with-primary
    // (the first discovery, from Unknown, counts: the watcher starts after the
    // kill). A repeated signal is harmless: the pollers act only on terms
    // above the ones they handled.
    if (new_type == "ReplicaSetNoPrimary" || new_type == "Unknown") {
      had_no_primary_.store(true);
    }

    if (new_type == "ReplicaSetWithPrimary" &&
        (had_no_primary_.load() || prev_type == "Unknown")) {
      had_no_primary_.store(false);

      // Find the new primary's host and term from the server descriptions.
      std::string primary_host;
      uint64_t term = 0;
      int loc = -1;
      auto servers = new_desc.servers();
      for (auto& server : servers) {
        std::string server_type(server.type().data(), server.type().size());
        if (server_type == "RSPrimary") {
          const std::string h(server.host().data(), server.host().size());
          primary_host = h + ":" + std::to_string(server.port());
          bool is_primary = false;
          term = JpMongoHelloTerm(server.hello(), &is_primary);
          for (size_t i = 0; i < replica_hosts_.size(); i++) {
            if (replica_hosts_[i] == h) {
              loc = (int) i;
              break;
            }
          }
          break;
        }
      }

      Log_info("[MONGODB-HOOKER] New primary elected: %s term=%llu loc=%d", primary_host.c_str(),
               (unsigned long long) term, loc);
      if (term == 0) {
        Log_warn("[MONGODB-HOOKER] no replica-set term in the new primary's hello: no signal "
                 "(a term-less primary_elected starts no recovery)");
        return;
      }
      std::string value = "primary_elected term=" + std::to_string(term);
      if (loc >= 0) {
        value += " loc=" + std::to_string(loc);
      }
      try {
        jm_signal::set_key("mongo", value, local_host_);
        Log_info("[MONGODB-HOOKER] Signaled mongo:%s for host=%s", value.c_str(),
                 local_host_.c_str());
      } catch (const std::exception& e) {
        Log_warn("[MONGODB-HOOKER] failed to signal mongo:%s: %s", value.c_str(), e.what());
      }
    }
  }

 public:
  MongodbLeaderWatcher(const std::string& mongo_uri, const std::string& local_host,
                       const std::vector<std::string>& replica_hosts = {})
      : mongo_uri_(mongo_uri), local_host_(local_host), replica_hosts_(replica_hosts) {}

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
