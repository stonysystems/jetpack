// Standalone ZK latency / throughput benchmark using libzookeeper-mt
// (the same C client Janus uses via deptran/zookeeper_kv_table_handler.h).
// Run from a host where Janus's ZK setup works (i.e. from server0..4 with
// zhost=127.0.0.1:2181). N pthreads each do back-to-back zoo_set; main
// thread aggregates latencies and prints CSV.
//
// Build:
//   g++ -std=c++17 -O2 -pthread bench_zk.cc -o bench_zk -lzookeeper_mt
//
// Run:
//   ./bench_zk <conc> <duration_s>
//
// Output (one CSV line on stdout):
//   zookeeper,conc,duration_s,n_ops,tput_rps,p50_ms,p90_ms,p99_ms

#include <zookeeper/zookeeper.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>

namespace {
const char* kRoot = "/bench_zk";
const std::string kVal = "v";

void noop_watcher(zhandle_t*, int, int, const char*, void*) {}

zhandle_t* open_handle() {
  zhandle_t* zh = zookeeper_init("127.0.0.1:2181", noop_watcher,
                                  30000, nullptr, nullptr, 0);
  // Wait briefly for the session to come up (zookeeper_init returns
  // immediately; first sync call will block until ready).
  for (int i = 0; i < 100 && zh && zoo_state(zh) != ZOO_CONNECTED_STATE; ++i) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  }
  return zh;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <conc> <duration_s>\n", argv[0]);
    return 1;
  }
  int conc = std::atoi(argv[1]);
  int duration_s = std::atoi(argv[2]);

  // One bootstrap handle to ensure /bench_zk root exists.
  zhandle_t* boot = open_handle();
  if (!boot) { fprintf(stderr, "bootstrap connect failed\n"); return 1; }
  if (zoo_state(boot) != ZOO_CONNECTED_STATE) {
    fprintf(stderr, "bootstrap not connected (state=%d)\n", zoo_state(boot));
    return 1;
  }
  struct Stat st;
  if (zoo_exists(boot, kRoot, 0, &st) == ZNONODE) {
    int rc = zoo_create(boot, kRoot, nullptr, -1,
                        &ZOO_OPEN_ACL_UNSAFE, 0, nullptr, 0);
    if (rc != ZOK && rc != ZNODEEXISTS) {
      fprintf(stderr, "create root failed: %s\n", zerror(rc));
      zookeeper_close(boot);
      return 1;
    }
  }
  zookeeper_close(boot);

  // Per-thread state.
  std::vector<std::vector<double>> latencies(conc);
  std::vector<long> counts(conc, 0);
  std::vector<long> errors(conc, 0);
  auto deadline = std::chrono::steady_clock::now() +
                  std::chrono::seconds(duration_s);

  auto worker = [&](int i) {
    zhandle_t* zh = open_handle();
    if (!zh) { errors[i]++; return; }
    if (zoo_state(zh) != ZOO_CONNECTED_STATE) {
      errors[i]++; zookeeper_close(zh); return;
    }
    // Pre-create the worker's znode so subsequent calls are pure
    // updates (sync write = ZAB-quorum ack).
    std::string path = std::string(kRoot) + "/w" + std::to_string(i);
    int crc = zoo_create(zh, path.c_str(), kVal.data(), kVal.size(),
                         &ZOO_OPEN_ACL_UNSAFE, 0, nullptr, 0);
    if (crc != ZOK && crc != ZNODEEXISTS) {
      fprintf(stderr, "[w%d] create failed: %s\n", i, zerror(crc));
      errors[i]++;
      zookeeper_close(zh);
      return;
    }
    long n = 0;
    while (std::chrono::steady_clock::now() < deadline) {
      auto t0 = std::chrono::steady_clock::now();
      int rc = zoo_set(zh, path.c_str(), kVal.data(), kVal.size(), -1);
      auto t1 = std::chrono::steady_clock::now();
      if (rc == ZOK) {
        latencies[i].push_back(
            std::chrono::duration<double, std::milli>(t1 - t0).count());
        counts[i]++;
      } else {
        errors[i]++;
      }
      n++;
    }
    zookeeper_close(zh);
  };

  std::vector<std::thread> threads;
  threads.reserve(conc);
  auto t_start = std::chrono::steady_clock::now();
  for (int i = 0; i < conc; ++i) threads.emplace_back(worker, i);
  for (auto& t : threads) t.join();
  double elapsed_s = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - t_start).count();

  // Aggregate.
  std::vector<double> all;
  long n_total = 0, n_err = 0;
  for (int i = 0; i < conc; ++i) {
    n_total += counts[i];
    n_err += errors[i];
    for (auto x : latencies[i]) all.push_back(x);
  }
  if (all.empty()) {
    fprintf(stderr, "no successful ops, errors=%ld\n", n_err);
    return 1;
  }
  std::sort(all.begin(), all.end());
  auto pct = [&](double q) {
    return all[std::min<size_t>(q * all.size(), all.size() - 1)];
  };
  double p50 = pct(0.50), p90 = pct(0.90), p99 = pct(0.99);
  double avg = 0;
  for (auto x : all) avg += x;
  avg /= all.size();

  double tput = n_total / elapsed_s;
  fprintf(stderr,
          "[zookeeper] conc=%d ops=%ld err=%ld tput=%.1f r/s "
          "p50=%.1f p90=%.1f p99=%.1f avg=%.1f ms\n",
          conc, n_total, n_err, tput, p50, p90, p99, avg);
  // CSV line on stdout.
  printf("zookeeper,%d,%d,%ld,%.3f,%.3f,%.3f,%.3f\n",
         conc, duration_s, n_total, tput, p50, p90, p99);
  return 0;
}
