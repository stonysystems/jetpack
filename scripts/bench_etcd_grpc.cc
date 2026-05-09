// bench_etcd_grpc.cc — direct-to-etcd microbench using raw grpc++ +
// etcdserverpb (no etcd-cpp-apiv3 wrapper). Sets the C++ ceiling for
// a 5-replica WAN etcd cluster.
//
// This is the apples-to-Go comparison: etcd's official `benchmark put`
// tool talks the same etcdserverpb gRPC interface from Go; this binary
// does the same from C++.
//
// Concurrency knobs (intentionally mirror bench_etcd_libetcd.cc):
//   --num-channels N  spawn N independent grpc::Channel instances.
//                     Each worker thread is sticky to one channel
//                     (round-robin). Janus-equivalent: N=1 ≈ pre-E2,
//                     N=8 ≈ kBatchHandlerPoolSize, N=conc ≈ no sharing.
//   --conc T          total worker threads making sync KV.Put calls.
//   --duration S      bench duration in seconds.
//   --value-size B    payload size in bytes.
//
// Build via scripts/build_backend_benches.sh (which generates the
// rpc.pb.{h,cc} + rpc.grpc.pb.{h,cc} stubs from
// third_party/etcd-cpp-apiv3/proto/rpc.proto via protoc).
//
// CSV: etcd-grpc,<n/a mode>,num_channels,conc,duration_s,n_ops,tput_rps,
//      p50_ms,p90_ms,p99_ms,avg_ms

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <memory>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

#include <grpcpp/grpcpp.h>

#include "rpc.grpc.pb.h"
#include "rpc.pb.h"

namespace {

struct Args {
  std::string host = "127.0.0.1";
  int port = 2379;
  int num_channels = 1;
  int conc = 1;
  int duration_s = 30;
  int value_size = 8;
};

void usage(const char* argv0) {
  std::fprintf(stderr,
      "usage: %s --host H [--port P] [--num-channels N] --conc T\n"
      "          [--duration S] [--value-size B]\n", argv0);
}

bool parse_args(int argc, char** argv, Args& a) {
  for (int i = 1; i < argc; ++i) {
    std::string k = argv[i];
    auto need = [&](int n) { return i + n < argc; };
    if (k == "--host" && need(1)) a.host = argv[++i];
    else if (k == "--port" && need(1)) a.port = std::atoi(argv[++i]);
    else if (k == "--num-channels" && need(1)) a.num_channels = std::atoi(argv[++i]);
    else if (k == "--conc" && need(1)) a.conc = std::atoi(argv[++i]);
    else if (k == "--duration" && need(1)) a.duration_s = std::atoi(argv[++i]);
    else if (k == "--value-size" && need(1)) a.value_size = std::atoi(argv[++i]);
    else { usage(argv[0]); return false; }
  }
  if (a.conc <= 0 || a.num_channels <= 0) { usage(argv[0]); return false; }
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

  const std::string target = args.host + ":" + std::to_string(args.port);
  const std::string value(args.value_size, 'v');

  // Build channels + KV stubs. Each channel is its own HTTP/2 connection
  // to etcd; N channels = N independent stream-cap budgets.
  grpc::ChannelArguments chan_args;
  chan_args.SetMaxReceiveMessageSize(64 * 1024 * 1024);
  chan_args.SetMaxSendMessageSize(64 * 1024 * 1024);
  std::vector<std::shared_ptr<grpc::Channel>> channels;
  std::vector<std::unique_ptr<etcdserverpb::KV::Stub>> stubs;
  for (int i = 0; i < args.num_channels; ++i) {
    auto chan = grpc::CreateCustomChannel(
        target, grpc::InsecureChannelCredentials(), chan_args);
    stubs.emplace_back(etcdserverpb::KV::NewStub(chan));
    channels.emplace_back(std::move(chan));
  }

  // Warm: do one Put per channel so connection setup / first-call latency
  // doesn't pollute the histogram.
  for (auto& stub : stubs) {
    grpc::ClientContext ctx;
    etcdserverpb::PutRequest req;
    req.set_key("/bench/warmup");
    req.set_value(value);
    etcdserverpb::PutResponse resp;
    (void)stub->Put(&ctx, req, &resp);
  }

  std::vector<std::vector<double>> per_thread_lat(args.conc);
  std::vector<int64_t> per_thread_ok(args.conc, 0);
  std::vector<int64_t> per_thread_err(args.conc, 0);

  const auto deadline = std::chrono::steady_clock::now()
                      + std::chrono::seconds(args.duration_s);

  auto worker = [&](int tid) {
    int idx = tid % args.num_channels;
    auto* stub = stubs[idx].get();
    int64_t n = 0;
    auto& lat = per_thread_lat[tid];
    lat.reserve(args.duration_s * 200);
    while (std::chrono::steady_clock::now() < deadline) {
      etcdserverpb::PutRequest req;
      req.set_key("/bench/t" + std::to_string(tid) + "/n" + std::to_string(n));
      req.set_value(value);
      etcdserverpb::PutResponse resp;
      grpc::ClientContext ctx;
      auto t0 = std::chrono::steady_clock::now();
      grpc::Status status = stub->Put(&ctx, req, &resp);
      auto t1 = std::chrono::steady_clock::now();
      double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
      if (status.ok()) { lat.push_back(ms); per_thread_ok[tid]++; }
      else { per_thread_err[tid]++; }
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
        "[etcd-grpc channels=%d conc=%d] NO SUCCESSFUL OPS, errors=%lld\n",
        args.num_channels, args.conc, (long long)n_err);
    return 1;
  }

  double p50 = percentile(all_lat, 0.50);
  double p90 = percentile(all_lat, 0.90);
  double p99 = percentile(all_lat, 0.99);
  double avg = std::accumulate(all_lat.begin(), all_lat.end(), 0.0)
             / (double)all_lat.size();
  double tput = (double)n_ok / elapsed_s;

  std::fprintf(stderr,
      "[etcd-grpc channels=%d conc=%d] "
      "ops=%lld err=%lld tput=%.1f r/s "
      "p50=%.1f p90=%.1f p99=%.1f avg=%.1f ms\n",
      args.num_channels, args.conc,
      (long long)n_ok, (long long)n_err, tput,
      p50, p90, p99, avg);

  std::printf("etcd-grpc,grpc,%d,%d,%d,%lld,%.3f,%.3f,%.3f,%.3f,%.3f\n",
              args.num_channels, args.conc, args.duration_s,
              (long long)n_ok, tput, p50, p90, p99, avg);
  return 0;
}
