// bench_mongo_cxx.cc — direct-to-mongodb microbench using mongocxx
// (the same library Janus's mongodb_kv_table_handler.h uses). No Janus
// involved.
//
// Mirrors Janus's linearizable contract:
//   w=majority&journal=true&readConcernLevel=linearizable&readPreference=primary
// (see src/deptran/mongodb_kv_table_handler.h:28-29)
//
// Concurrency knobs:
//   --num-clients N   spawn N independent mongocxx::client instances
//                     (mongocxx::client is NOT thread-safe; Janus has
//                     one client per Janus host. N here = N independent
//                     connection pools.)
//   --conc T          total worker threads. Each is sticky to one client
//                     by tid % N.
//   --duration S      bench duration in seconds.
//   --value-size B    payload size (default 8B).
//
// CSV: mongodb-cxx,<n/a>,num_clients,conc,duration_s,n_ops,tput_rps,
//      p50_ms,p90_ms,p99_ms,avg_ms

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <memory>
#include <mutex>
#include <numeric>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <bsoncxx/builder/stream/document.hpp>
#include <bsoncxx/oid.hpp>
#include <mongocxx/client.hpp>
#include <mongocxx/exception/exception.hpp>
#include <mongocxx/instance.hpp>
#include <mongocxx/options/update.hpp>
#include <mongocxx/uri.hpp>

namespace {

struct Args {
  std::string host = "127.0.0.1";
  int port = 27017;
  int num_clients = 1;
  int conc = 1;
  int duration_s = 30;
  int value_size = 8;
};

void usage(const char* argv0) {
  std::fprintf(stderr,
      "usage: %s --host H [--port P] [--num-clients N] --conc T\n"
      "          [--duration S] [--value-size B]\n", argv0);
}

bool parse_args(int argc, char** argv, Args& a) {
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    auto need = [&](int n) { return i + n < argc; };
    if (k == "--host" && need(1)) a.host = argv[++i];
    else if (k == "--port" && need(1)) a.port = std::atoi(argv[++i]);
    else if (k == "--num-clients" && need(1)) a.num_clients = std::atoi(argv[++i]);
    else if (k == "--conc" && need(1)) a.conc = std::atoi(argv[++i]);
    else if (k == "--duration" && need(1)) a.duration_s = std::atoi(argv[++i]);
    else if (k == "--value-size" && need(1)) a.value_size = std::atoi(argv[++i]);
    else { usage(argv[0]); return false; }
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

  // Single global mongocxx::instance (driver requirement).
  static mongocxx::instance instance{};

  // Match Janus's linearizable URI exactly. directConnection=true so we
  // hit the leader and don't auto-failover to followers (which would
  // change the comparison shape).
  const std::string uri_str =
      "mongodb://" + args.host + ":" + std::to_string(args.port) +
      "/?directConnection=true&w=majority&journal=true"
      "&readConcernLevel=linearizable&readPreference=primary"
      "&serverSelectionTimeoutMS=10000";
  const std::string value(args.value_size, 'v');

  // mongocxx::client is NOT thread-safe (the driver crashes when two
  // threads race on one client). We use a per-client mutex so multiple
  // worker threads sharing the same client serialize on it. This
  // mirrors Janus's MongodbConnectionThreadPool shape: when num_clients
  // is small relative to conc, ops queue per-client just like Janus's
  // pool of N persistent handlers.
  std::vector<std::unique_ptr<mongocxx::client>> clients;
  std::vector<mongocxx::collection> colls;
  std::vector<std::unique_ptr<std::mutex>> client_mu;
  const std::string bench_id = []() {
    std::random_device rd;
    std::mt19937_64 g(rd());
    return std::to_string(g() & 0xffffffff);
  }();
  for (int i = 0; i < args.num_clients; ++i) {
    auto cli = std::make_unique<mongocxx::client>(mongocxx::uri{uri_str});
    auto coll = (*cli)["bench"]["kv"];
    colls.push_back(coll);
    clients.push_back(std::move(cli));
    client_mu.emplace_back(std::make_unique<std::mutex>());
  }

  // Warm: one upsert per client.
  for (auto& coll : colls) {
    auto filter = bsoncxx::builder::stream::document{}
                  << "_id" << ("warmup-" + bench_id)
                  << bsoncxx::builder::stream::finalize;
    auto update = bsoncxx::builder::stream::document{}
                  << "$set" << bsoncxx::builder::stream::open_document
                  << "v" << value
                  << bsoncxx::builder::stream::close_document
                  << bsoncxx::builder::stream::finalize;
    try {
      coll.update_one(filter.view(), update.view(),
                      mongocxx::options::update{}.upsert(true));
    } catch (...) {}
  }

  std::vector<std::vector<double>> per_thread_lat(args.conc);
  std::vector<int64_t> per_thread_ok(args.conc, 0);
  std::vector<int64_t> per_thread_err(args.conc, 0);

  const auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::seconds(args.duration_s);

  auto worker = [&](int tid) {
    int idx = tid % args.num_clients;
    auto& coll = colls[idx];
    int64_t n = 0;
    auto& lat = per_thread_lat[tid];
    lat.reserve(args.duration_s * 200);
    while (std::chrono::steady_clock::now() < deadline) {
      const std::string id = bench_id + "-t" + std::to_string(tid)
                           + "-n" + std::to_string(n);
      auto filter = bsoncxx::builder::stream::document{}
                    << "_id" << id
                    << bsoncxx::builder::stream::finalize;
      auto update = bsoncxx::builder::stream::document{}
                    << "$set" << bsoncxx::builder::stream::open_document
                    << "v" << value
                    << bsoncxx::builder::stream::close_document
                    << bsoncxx::builder::stream::finalize;
      auto t0 = std::chrono::steady_clock::now();
      bool ok = false;
      try {
        std::lock_guard<std::mutex> lk(*client_mu[idx]);
        auto res = coll.update_one(filter.view(), update.view(),
                                   mongocxx::options::update{}.upsert(true));
        ok = (bool)res;
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
        "[mongodb-cxx clients=%d conc=%d] NO SUCCESSFUL OPS, errors=%lld\n",
        args.num_clients, args.conc, (long long)n_err);
    return 1;
  }

  double p50 = percentile(all_lat, 0.50);
  double p90 = percentile(all_lat, 0.90);
  double p99 = percentile(all_lat, 0.99);
  double avg = std::accumulate(all_lat.begin(), all_lat.end(), 0.0)
             / (double)all_lat.size();
  double tput = (double)n_ok / elapsed_s;

  std::fprintf(stderr,
      "[mongodb-cxx clients=%d conc=%d] "
      "ops=%lld err=%lld tput=%.1f r/s "
      "p50=%.1f p90=%.1f p99=%.1f avg=%.1f ms\n",
      args.num_clients, args.conc,
      (long long)n_ok, (long long)n_err, tput,
      p50, p90, p99, avg);

  std::printf("mongodb-cxx,mongocxx,%d,%d,%d,%lld,%.3f,%.3f,%.3f,%.3f,%.3f\n",
              args.num_clients, args.conc, args.duration_s,
              (long long)n_ok, tput, p50, p90, p99, avg);
  return 0;
}
