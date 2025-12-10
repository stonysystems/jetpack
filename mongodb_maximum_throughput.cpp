#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <bsoncxx/json.hpp>
#include <bsoncxx/types.hpp>
#include <bsoncxx/builder/basic/document.hpp>
#include <bsoncxx/builder/basic/kvp.hpp>
#include <mongocxx/client.hpp>
#include <mongocxx/instance.hpp>
#include <mongocxx/uri.hpp>

// Build:
//   g++ -std=c++17 mongodb_maximum_throughput.cpp -o mongodb_maximum_throughput $(pkg-config --cflags --libs libmongocxx)
//
// Run (example):
//   ./mongodb_maximum_throughput "mongodb://127.0.0.1:27017" test_db bench_coll 8 30 512
//
// Args:
//   [1] URI
//   [2] database name
//   [3] collection name
//   [4] threads (default 4)
//   [5] duration seconds (default 30)
//   [6] payload bytes (default 512; stored in a "payload" string field)

namespace {

std::atomic<bool> stop_flag{false};

bsoncxx::document::value MakeDoc(std::mt19937& gen, size_t payload_bytes) {
  static std::atomic<uint64_t> seq{0};
  std::uniform_int_distribution<int> dist(0, 15);

  std::string payload;
  payload.reserve(payload_bytes);
  for (size_t i = 0; i < payload_bytes; ++i) {
    payload.push_back("0123456789abcdef"[dist(gen)]);
  }

  bsoncxx::builder::basic::document builder;
  builder.append(
      bsoncxx::builder::basic::kvp("seq", static_cast<int64_t>(seq.fetch_add(1))),
      bsoncxx::builder::basic::kvp("ts", static_cast<int64_t>(
          std::chrono::duration_cast<std::chrono::milliseconds>(
              std::chrono::steady_clock::now().time_since_epoch()).count())),
      bsoncxx::builder::basic::kvp("payload", payload));
  return builder.extract();
}

void Worker(const std::string& uri_str,
            const std::string& db_name,
            const std::string& coll_name,
            size_t payload_bytes,
            std::atomic<uint64_t>* counter) {
  mongocxx::uri uri(uri_str);
  mongocxx::client client(uri);
  auto coll = client[db_name][coll_name];

  // Per-thread RNG
  std::mt19937 gen(static_cast<unsigned int>(
      std::chrono::high_resolution_clock::now().time_since_epoch().count() ^
      reinterpret_cast<uintptr_t>(counter)));

  while (!stop_flag.load(std::memory_order_relaxed)) {
    auto doc = MakeDoc(gen, payload_bytes);
    try {
      auto res = coll.insert_one(doc.view());
      if (res) {
        counter->fetch_add(1, std::memory_order_relaxed);
      }
    } catch (const std::exception& e) {
      // Swallow and continue so one hiccup doesn't stop the run.
      std::cerr << "[WARN] insert failed: " << e.what() << "\n";
    }
  }
}

} // namespace

int main(int argc, char* argv[]) {
  mongocxx::instance inst{};

  const char* uri_str = (argc > 1) ? argv[1] : "mongodb://127.0.0.1:27017";
  std::string db_name = (argc > 2) ? argv[2] : "test_db";
  std::string coll_name = (argc > 3) ? argv[3] : "bench_coll";
  int threads = (argc > 4) ? std::atoi(argv[4]) : 4;
  int duration_sec = (argc > 5) ? std::atoi(argv[5]) : 30;
  size_t payload_bytes = (argc > 6) ? static_cast<size_t>(std::strtoul(argv[6], nullptr, 10)) : 512;

  if (threads <= 0) threads = 1;
  if (duration_sec <= 0) duration_sec = 10;

  std::cout << "URI=" << uri_str
            << " db=" << db_name
            << " coll=" << coll_name
            << " threads=" << threads
            << " duration=" << duration_sec << "s"
            << " payload=" << payload_bytes << " bytes\n";

  std::atomic<uint64_t> total_ops{0};

  std::vector<std::thread> workers;
  workers.reserve(static_cast<size_t>(threads));
  for (int i = 0; i < threads; ++i) {
    workers.emplace_back(Worker, std::string(uri_str), db_name, coll_name, payload_bytes, &total_ops);
  }

  auto start = std::chrono::steady_clock::now();
  for (int sec = 0; sec < duration_sec; ++sec) {
    std::this_thread::sleep_for(std::chrono::seconds(1));
    auto ops = total_ops.load(std::memory_order_relaxed);
    auto elapsed_s = std::chrono::duration_cast<std::chrono::duration<double>>(
        std::chrono::steady_clock::now() - start).count();
    double tps = ops / elapsed_s;
    std::cout << "[PROGRESS] t=" << std::setw(4) << sec+1 << "s "
              << "ops=" << ops << " tps=" << std::fixed << std::setprecision(2) << tps << "\r"
              << std::flush;
  }
  std::cout << "\n";

  stop_flag.store(true, std::memory_order_relaxed);
  for (auto& t : workers) {
    t.join();
  }

  auto elapsed = std::chrono::duration_cast<std::chrono::duration<double>>(
      std::chrono::steady_clock::now() - start).count();
  uint64_t ops = total_ops.load(std::memory_order_relaxed);
  double tps = ops / elapsed;

  std::cout << "Completed " << ops << " inserts in " << elapsed << "s, throughput = "
            << std::fixed << std::setprecision(2) << tps << " ops/s\n";
  return 0;
}
