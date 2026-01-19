#pragma once

#include <string>
#include <iostream>

#ifndef JANUS_ETCD_HAS_PPLX
#if defined(__has_include)
#if __has_include(<pplx/pplxtasks.h>)
#define JANUS_ETCD_HAS_PPLX 1
#else
#define JANUS_ETCD_HAS_PPLX 0
#endif
#else
#define JANUS_ETCD_HAS_PPLX 0
#endif
#endif

#if JANUS_ETCD_HAS_PPLX
#include <pplx/pplxtasks.h>
#include <etcd/Client.hpp>
#else
#include <etcd/SyncClient.hpp>
#endif
#include <etcd/Response.hpp>

namespace janus {

constexpr char kEtcdUri[] = "http://127.0.0.1:2379";
constexpr char kEtcdKeyPrefix[] = "JetPack/KVTable/";

class EtcdKVTableHandler {
 private:
 std::string uri_str_;
#if JANUS_ETCD_HAS_PPLX
  etcd::Client client_;
#else
  etcd::SyncClient client_;
#endif

  static std::string MakeKey(int key) {
    return std::string(kEtcdKeyPrefix) + std::to_string(key);
  }

 public:
  explicit EtcdKVTableHandler(const std::string& uri_str = kEtcdUri)
      : uri_str_(uri_str),
        client_(uri_str_) {
    Setup();
  }

  ~EtcdKVTableHandler() = default;

#if JANUS_ETCD_HAS_PPLX
  pplx::task<etcd::Response> WriteAsync(int key, int value) {
    const auto key_str = MakeKey(key);
    const auto value_str = std::to_string(value);
    return client_.put(key_str, value_str);
  }

  pplx::task<etcd::Response> ReadAsync(int key) {
    const auto key_str = MakeKey(key);
    return client_.get(key_str);
  }
#endif

  bool Write(int key, int value) {
    const auto key_str = MakeKey(key);
    const auto value_str = std::to_string(value);

    try {
#if JANUS_ETCD_HAS_PPLX
      auto response = client_.put(key_str, value_str).get();
#else
      auto response = client_.put(key_str, value_str);
#endif
      return response.is_ok();
    } catch (const std::exception& e) {
      std::cerr << "Etcd Write error: " << e.what() << std::endl;
    }
    return false;
  }

  int Read(int key) {
    const auto key_str = MakeKey(key);

    try {
#if JANUS_ETCD_HAS_PPLX
      auto response = client_.get(key_str).get();
#else
      auto response = client_.get(key_str);
#endif
      if (!response.is_ok()) {
        return 0;
      }
      const auto value_str = response.value().as_string();
      if (value_str.empty()) {
        return 0;
      }
      return std::stoi(value_str);
    } catch (const std::exception& e) {
      std::cerr << "Etcd Read error: " << e.what() << std::endl;
    }
    return 0;
  }

  void Clear() {
    try {
#if JANUS_ETCD_HAS_PPLX
      client_.rmdir(kEtcdKeyPrefix, true).get();
#else
      client_.rmdir(kEtcdKeyPrefix, true);
#endif
    } catch (const std::exception& e) {
      std::cerr << "Etcd Clear error: " << e.what() << std::endl;
    }
  }

  void Setup() {}
};

} // namespace janus
