// bench_etcd_libetcd.cc — direct-to-etcd microbench using etcd-cpp-apiv3
// (the same library Janus uses). No Janus framework involved.
//
// Tests the SAME C++ etcd client Janus's etcd_kv_table_handler.h links
// against, so a gap between this binary's tput and Janus's etcd-mediated
// tput localizes overhead inside Janus (pool, handler sharing, RPC wrap),
// not the etcd client library itself.
//
// Three modes:
//   --mode sync   uses etcd::SyncClient (the lib's "performance does not
//                 matter" path; see SyncClient.hpp:86-87)
//   --mode async  uses etcd::Client::put().get() — async API + sync wait
//                 from the calling thread (calling thread parks on
//                 task_completion_event; CQ thread directly notifies it)
//   --mode then   uses etcd::Client::put().then(cb) — Janus's exact
//                 consumption pattern. The continuation is dispatched via
//                 the pplx scheduler thread pool. Used to test whether
//                 pplx scheduler queueing is the source of the etcd
//                 latency surge in Janus (see results/2026-05-07-...).
//
// Concurrency knobs (mirrors Janus's EtcdConnectionThreadPool design):
//   --num-clients N   spawn N independent etcd::{Sync,}Client instances
//                     (= N gRPC channels). Each worker thread is sticky
//                     to one client. Janus's pre-E2 design has 1 client
//                     per host; kBatchHandlerPoolSize=8 has 8.
//   --conc T          total worker threads (round-robin assigned to clients)
//   --duration S      benchmark duration in seconds
//   --value-size B    payload size in bytes (8 by default, matches Python bench)
//
// CSV output schema matches scripts/bench_backends.py so all rows land in
// the same results.csv:
//   client,mode,num_clients,conc,duration_s,n_ops,tput_rps,p50_ms,p90_ms,p99_ms,avg_ms
//
// Build via scripts/build_backend_benches.sh.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <etcd/Client.hpp>
#include <etcd/Response.hpp>
#include <etcd/SyncClient.hpp>
#include <pplx/pplxtasks.h>

namespace {

struct Args {
  std::string host = "127.0.0.1";
  int port = 2379;
  std::string mode = "async";  // sync|async
  int num_clients = 1;
  int conc = 1;
  int duration_s = 30;
  int value_size = 8;
};

void usage(const char* argv0) {
  std::fprintf(stderr,
      "usage: %s --host H [--port P] [--mode sync|async|then]\n"
      "          [--num-clients N] --conc T [--duration S] [--value-size B]\n",
      argv0);
}

bool parse_args(int argc, char** argv, Args& a) {
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    auto need = [&](int n) { return i + n < argc; };
    if (k == "--host" && need(1)) a.host = argv[++i];
    else if (k == "--port" && need(1)) a.port = std::atoi(argv[++i]);
    else if (k == "--mode" && need(1)) a.mode = argv[++i];
    else if (k == "--num-clients" && need(1)) a.num_clients = std::atoi(argv[++i]);
    else if (k == "--conc" && need(1)) a.conc = std::atoi(argv[++i]);
    else if (k == "--duration" && need(1)) a.duration_s = std::atoi(argv[++i]);
    else if (k == "--value-size" && need(1)) a.value_size = std::atoi(argv[++i]);
    else { usage(argv[0]); return false; }
  }
  if (a.mode != "sync" && a.mode != "async" && a.mode != "then") {
    usage(argv[0]); return false;
  }
  if (a.conc <= 0 || a.num_clients <= 0) { usage(argv[0]); return false; }
  return true;
}

double percentile(std::vector<double>& v, double q) {
  if (v.empty()) return 0.0;
  size_t i = std::min(v.size() - 1, (size_t)(q * v.size()));
  std::nth_element(v.begin(), v.begin() + i, v.end());
  return v[i];
}

}  // namespace

int main(int argc, char** argv) {
  Args args;
  if (!parse_args(argc, argv, args)) return 2;

  const std::string uri = "http://" + args.host + ":" + std::to_string(args.port);
  const std::string value(args.value_size, 'v');

  // Build the client pool. async/then modes = etcd::Client (pplx);
  // sync mode = etcd::SyncClient. One channel per element.
  std::vector<std::shared_ptr<etcd::Client>> async_clients;
  std::vector<std::shared_ptr<etcd::SyncClient>> sync_clients;
  const bool use_async_client = (args.mode == "async" || args.mode == "then");
  if (use_async_client) {
    for (int i = 0; i < args.num_clients; ++i) {
      async_clients.emplace_back(std::make_shared<etcd::Client>(uri));
    }
  } else {
    for (int i = 0; i < args.num_clients; ++i) {
      sync_clients.emplace_back(std::make_shared<etcd::SyncClient>(uri));
    }
  }

  // Warm the connections — first put can pay handshake cost we don't want
  // to attribute to the latency distribution.
  if (use_async_client) {
    for (auto& c : async_clients) c->put("/bench/warmup", value).wait();
  } else {
    for (auto& c : sync_clients) c->put("/bench/warmup", value);
  }

  std::vector<std::vector<double>> per_thread_lat(args.conc);
  std::vector<int64_t> per_thread_ok(args.conc, 0);
  std::vector<int64_t> per_thread_err(args.conc, 0);

  const auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::seconds(args.duration_s);

  auto worker = [&](int tid) {
    int client_idx = tid % args.num_clients;
    int64_t n = 0;
    auto& lat = per_thread_lat[tid];
    lat.reserve(args.duration_s * 200);  // rough preallocation
    while (std::chrono::steady_clock::now() < deadline) {
      const std::string key = "/bench/t" + std::to_string(tid)
                            + "/n" + std::to_string(n);
      auto t0 = std::chrono::steady_clock::now();
      bool ok = false;
      try {
        if (args.mode == "async") {
          auto resp = async_clients[client_idx]->put(key, value).get();
          ok = resp.is_ok();
        } else if (args.mode == "then") {
          // Mirror Janus's consumption pattern: register a continuation
          // that signals via task_completion_event, then wait on the event.
          // The continuation is dispatched by pplx's scheduler thread pool,
          // so any scheduler-queue latency shows up here just like in Janus.
          pplx::task_completion_event<bool> tce;
          auto wait_task = pplx::create_task(tce);
          async_clients[client_idx]->put(key, value).then(
              [tce](pplx::task<etcd::Response> rt) {
                bool cb_ok = false;
                try { cb_ok = rt.get().is_ok(); } catch (...) {}
                tce.set(cb_ok);
              });
          ok = wait_task.get();
        } else {
          auto resp = sync_clients[client_idx]->put(key, value);
          ok = resp.is_ok();
        }
      } catch (const std::exception& e) {
        ok = false;
      }
      auto t1 = std::chrono::steady_clock::now();
      double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
      if (ok) { lat.push_back(ms); per_thread_ok[tid]++; }
      else    { per_thread_err[tid]++; }
      ++n;
    }
  };

  auto t_start = std::chrono::steady_clock::now();
  std::vector<std::thread> threads;
  threads.reserve(args.conc);
  for (int i = 0; i < args.conc; ++i) threads.emplace_back(worker, i);
  for (auto& t : threads) t.join();
  auto t_end = std::chrono::steady_clock::now();
  double elapsed_s = std::chrono::duration<double>(t_end - t_start).count();

  // Aggregate.
  std::vector<double> all_lat;
  int64_t n_ok = 0, n_err = 0;
  for (int i = 0; i < args.conc; ++i) {
    n_ok += per_thread_ok[i];
    n_err += per_thread_err[i];
    all_lat.insert(all_lat.end(), per_thread_lat[i].begin(),
                   per_thread_lat[i].end());
  }
  if (all_lat.empty()) {
    std::fprintf(stderr,
        "[etcd-libetcd mode=%s clients=%d conc=%d] NO SUCCESSFUL OPS, "
        "errors=%lld\n", args.mode.c_str(), args.num_clients, args.conc,
        (long long)n_err);
    return 1;
  }

  double p50 = percentile(all_lat, 0.50);
  double p90 = percentile(all_lat, 0.90);
  double p99 = percentile(all_lat, 0.99);
  double avg = std::accumulate(all_lat.begin(), all_lat.end(), 0.0)
             / (double)all_lat.size();
  double tput = (double)n_ok / elapsed_s;

  std::fprintf(stderr,
      "[etcd-libetcd mode=%s clients=%d conc=%d] "
      "ops=%lld err=%lld tput=%.1f r/s "
      "p50=%.1f p90=%.1f p99=%.1f avg=%.1f ms\n",
      args.mode.c_str(), args.num_clients, args.conc,
      (long long)n_ok, (long long)n_err, tput,
      p50, p90, p99, avg);

  // CSV: client,mode,num_clients,conc,duration_s,n_ops,tput_rps,p50_ms,p90_ms,p99_ms,avg_ms
  std::printf("etcd-libetcd,%s,%d,%d,%d,%lld,%.3f,%.3f,%.3f,%.3f,%.3f\n",
              args.mode.c_str(), args.num_clients, args.conc, args.duration_s,
              (long long)n_ok, tput, p50, p90, p99, avg);
  return 0;
}
