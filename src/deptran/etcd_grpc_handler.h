// etcd_grpc_handler.h — raw gRPC C++ replacement for the KV hot path,
// bypassing etcd-cpp-apiv3 / cpprestsdk / pplx. Mirrors the working
// pattern in scripts/bench_etcd_grpc.cc.
//
// Same public interface as EtcdKVTableHandler (Write / Read / BatchTxn /
// Clear), so EtcdConnectionThreadPool can swap implementations via a
// `using` alias.
//
// Build: requires the etcdserverpb generated stubs at
//   third_party/etcd-cpp-apiv3/build/proto/gen/proto/{rpc,rpc.grpc,kv,
//   auth}.pb.{h,cc} plus the gogoproto + google/api transitive .pb.cc
//   files. wscript adds these to deptran_server when
//   JANUS_ETCD_USE_RAW_GRPC is defined.
//
// Caveats:
// - Sync gRPC API only; concurrency comes from worker threads in
//   EtcdConnectionThreadPool (matches bench_etcd_grpc.cc design).
// - No Watch / Lease — those are still served by etcd-cpp-apiv3 via
//   etcd_leader_watcher.h (hybrid).
// - Endpoint failover not implemented; assumes the single uri is the
//   leader (start_etcd_cluster_aws.sh pins leader to server0).
#pragma once

#include <atomic>
#include <chrono>
#include <iostream>
#include <memory>
#include <string>
#include <tuple>
#include <vector>

#include <grpcpp/grpcpp.h>
#include "rpc.grpc.pb.h"
#include "rpc.pb.h"

namespace janus {

constexpr char kEtcdGrpcKeyPrefix[] = "JetPack/KVTable/";

// Parse "http://host:port" or "host:port" into "host:port" for gRPC.
inline std::string ParseGrpcTarget(const std::string& uri_str) {
  std::string s = uri_str;
  const std::string http_prefix = "http://";
  const std::string https_prefix = "https://";
  if (s.compare(0, http_prefix.size(), http_prefix) == 0) {
    s = s.substr(http_prefix.size());
  } else if (s.compare(0, https_prefix.size(), https_prefix) == 0) {
    s = s.substr(https_prefix.size());
  }
  // Strip any trailing path
  auto slash = s.find('/');
  if (slash != std::string::npos) s = s.substr(0, slash);
  return s;
}

class EtcdGrpcHandler {
 private:
  std::string uri_str_;
  std::shared_ptr<grpc::Channel> channel_;
  std::unique_ptr<etcdserverpb::KV::Stub> kv_stub_;

  static std::string MakeKey(int key) {
    return std::string(kEtcdGrpcKeyPrefix) + std::to_string(key);
  }

  // Each call gets its own deadline. 10 s matches etcd-cpp-apiv3's default.
  static void SetDeadline(grpc::ClientContext& ctx) {
    ctx.set_deadline(std::chrono::system_clock::now() +
                     std::chrono::seconds(10));
  }

 public:
  explicit EtcdGrpcHandler(const std::string& uri_str = "http://127.0.0.1:2379")
      : uri_str_(uri_str) {
    const std::string target = ParseGrpcTarget(uri_str);
    grpc::ChannelArguments chan_args;
    chan_args.SetMaxReceiveMessageSize(64 * 1024 * 1024);
    chan_args.SetMaxSendMessageSize(64 * 1024 * 1024);
    channel_ = grpc::CreateCustomChannel(
        target, grpc::InsecureChannelCredentials(), chan_args);
    kv_stub_ = etcdserverpb::KV::NewStub(channel_);
  }

  ~EtcdGrpcHandler() = default;

  bool Write(int key, int value) {
    etcdserverpb::PutRequest req;
    req.set_key(MakeKey(key));
    req.set_value(std::to_string(value));
    etcdserverpb::PutResponse resp;
    grpc::ClientContext ctx;
    SetDeadline(ctx);
    grpc::Status status = kv_stub_->Put(&ctx, req, &resp);
    if (!status.ok()) {
      std::cerr << "EtcdGrpc Write error: " << status.error_message()
                << std::endl;
      return false;
    }
    return true;
  }

  int Read(int key) {
    etcdserverpb::RangeRequest req;
    req.set_key(MakeKey(key));
    etcdserverpb::RangeResponse resp;
    grpc::ClientContext ctx;
    SetDeadline(ctx);
    grpc::Status status = kv_stub_->Range(&ctx, req, &resp);
    if (!status.ok()) {
      std::cerr << "EtcdGrpc Read error: " << status.error_message()
                << std::endl;
      return 0;
    }
    if (resp.kvs_size() == 0) return 0;
    const std::string& v = resp.kvs(0).value();
    if (v.empty()) return 0;
    try {
      return std::stoi(v);
    } catch (const std::exception& e) {
      return 0;
    }
  }

  using BatchOp = std::tuple<bool, int, int>;

  bool BatchTxn(const std::vector<BatchOp>& ops) {
    if (ops.empty()) return true;
    etcdserverpb::TxnRequest req;
    for (const auto& op : ops) {
      bool is_write;
      int key, value;
      std::tie(is_write, key, value) = op;
      auto* succ = req.add_success();
      if (is_write) {
        auto* put = succ->mutable_request_put();
        put->set_key(MakeKey(key));
        put->set_value(std::to_string(value));
      } else {
        auto* rng = succ->mutable_request_range();
        rng->set_key(MakeKey(key));
      }
    }
    etcdserverpb::TxnResponse resp;
    grpc::ClientContext ctx;
    SetDeadline(ctx);
    grpc::Status status = kv_stub_->Txn(&ctx, req, &resp);
    if (!status.ok()) {
      std::cerr << "EtcdGrpc BatchTxn error: " << status.error_message()
                << std::endl;
      return false;
    }
    return resp.succeeded();
  }

  void Clear() {
    // DeleteRange with end-key set to prefix+0xFF removes all keys under
    // the prefix (etcd range-delete semantics).
    etcdserverpb::DeleteRangeRequest req;
    req.set_key(kEtcdGrpcKeyPrefix);
    std::string end_key = kEtcdGrpcKeyPrefix;
    // Range end for prefix delete: incremnent the last byte.
    if (!end_key.empty()) {
      end_key.back() = static_cast<char>(end_key.back() + 1);
    }
    req.set_range_end(end_key);
    etcdserverpb::DeleteRangeResponse resp;
    grpc::ClientContext ctx;
    SetDeadline(ctx);
    grpc::Status status = kv_stub_->DeleteRange(&ctx, req, &resp);
    if (!status.ok()) {
      std::cerr << "EtcdGrpc Clear error: " << status.error_message()
                << std::endl;
    }
  }

  void Setup() {}
};

}  // namespace janus
