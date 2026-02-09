#pragma once

#include <functional>
#include <string>
#include <cstring>
#include <zookeeper/zookeeper.h>
#include "rrr.hpp"

namespace janus {

constexpr char kZookeeperUri[] = "127.0.0.1:2181";
constexpr char kZookeeperKeyPrefix[] = "/JetPack/KVTable/";
constexpr char kZookeeperRootPath[] = "/JetPack";
constexpr char kZookeeperTablePath[] = "/JetPack/KVTable";

// Callback context for async ZooKeeper operations.
struct ZkAsyncContext {
  std::function<void(int)> on_complete;
  std::string path;   // for write: used in create-on-ZNONODE fallback
  std::string value;  // for write: data to create if node doesn't exist
  zhandle_t* zh;      // handle for fallback create in write path
};

class ZookeeperKVTableHandler {
  std::string uri_str_;
  zhandle_t* zh_{nullptr};

  static std::string MakeKey(int key) {
    return std::string(kZookeeperKeyPrefix) + std::to_string(key);
  }

  static void DefaultWatcher(zhandle_t* zh, int type, int state,
                              const char* path, void* ctx) {
    (void)zh; (void)type; (void)state; (void)path; (void)ctx;
  }

  // Async callback for zoo_aget: fires on ZooKeeper I/O thread.
  static void ReadAsyncCallback(int rc, const char* value, int value_len,
                                 const struct Stat* stat, const void* data) {
    (void)value; (void)value_len; (void)stat;
    auto* ctx = static_cast<ZkAsyncContext*>(const_cast<void*>(data));
    if (ctx->on_complete) {
      ctx->on_complete(rc);
    }
    delete ctx;
  }

  // Async callback for zoo_aset: fires on ZooKeeper I/O thread.
  // On ZNONODE, falls back to zoo_acreate (upsert semantics).
  static void WriteSetAsyncCallback(int rc, const struct Stat* stat,
                                     const void* data) {
    (void)stat;
    auto* ctx = static_cast<ZkAsyncContext*>(const_cast<void*>(data));
    if (rc == ZNONODE && ctx->zh) {
      // Node doesn't exist yet — create it asynchronously.
      auto* create_ctx = new ZkAsyncContext{ctx->on_complete, ctx->path, ctx->value, nullptr};
      int crc = zoo_acreate(ctx->zh, ctx->path.c_str(),
                            ctx->value.c_str(),
                            static_cast<int>(ctx->value.size()),
                            &ZOO_OPEN_ACL_UNSAFE, 0,
                            WriteCreateAsyncCallback, create_ctx);
      if (crc != ZOK) {
        Log_warn("[ZOOKEEPER] async create dispatch failed: %s", zerror(crc));
        if (create_ctx->on_complete) create_ctx->on_complete(crc);
        delete create_ctx;
      }
    } else {
      if (ctx->on_complete) {
        ctx->on_complete(rc);
      }
    }
    delete ctx;
  }

  // Async callback for zoo_acreate (write fallback).
  static void WriteCreateAsyncCallback(int rc, const char* value,
                                        const void* data) {
    (void)value;
    auto* ctx = static_cast<ZkAsyncContext*>(const_cast<void*>(data));
    if (ctx->on_complete) {
      ctx->on_complete(rc);
    }
    delete ctx;
  }

 public:
  explicit ZookeeperKVTableHandler(const std::string& uri_str = kZookeeperUri)
      : uri_str_(uri_str) {
    zh_ = zookeeper_init(uri_str_.c_str(), DefaultWatcher,
                         30000, nullptr, nullptr, 0);
    if (!zh_) {
      Log_warn("[ZOOKEEPER] Failed to connect to %s", uri_str_.c_str());
    } else {
      Log_info("[ZOOKEEPER] Connected to %s", uri_str_.c_str());
    }
  }

  ~ZookeeperKVTableHandler() {
    if (zh_) {
      zookeeper_close(zh_);
      zh_ = nullptr;
    }
  }

  zhandle_t* handle() const { return zh_; }

  void Setup() {
    if (!zh_) return;
    // Create parent znodes if they don't exist.
    struct Stat stat;
    if (zoo_exists(zh_, kZookeeperRootPath, 0, &stat) == ZNONODE) {
      zoo_create(zh_, kZookeeperRootPath, nullptr, -1,
                 &ZOO_OPEN_ACL_UNSAFE, 0, nullptr, 0);
    }
    if (zoo_exists(zh_, kZookeeperTablePath, 0, &stat) == ZNONODE) {
      zoo_create(zh_, kZookeeperTablePath, nullptr, -1,
                 &ZOO_OPEN_ACL_UNSAFE, 0, nullptr, 0);
    }
  }

  // --- Synchronous API ---

  bool Write(int key, int value) {
    if (!zh_) return false;
    std::string path = MakeKey(key);
    std::string val = std::to_string(value);
    struct Stat stat;
    int rc = zoo_exists(zh_, path.c_str(), 0, &stat);
    if (rc == ZNONODE) {
      rc = zoo_create(zh_, path.c_str(), val.c_str(),
                      static_cast<int>(val.size()),
                      &ZOO_OPEN_ACL_UNSAFE, 0, nullptr, 0);
    } else if (rc == ZOK) {
      rc = zoo_set(zh_, path.c_str(), val.c_str(),
                   static_cast<int>(val.size()), -1);
    }
    if (rc != ZOK) {
      Log_warn("[ZOOKEEPER] Write(%d, %d) failed: %s",
               key, value, zerror(rc));
      return false;
    }
    return true;
  }

  int Read(int key) {
    if (!zh_) return 0;
    std::string path = MakeKey(key);
    char buffer[256];
    int buffer_len = sizeof(buffer);
    struct Stat stat;
    int rc = zoo_get(zh_, path.c_str(), 0, buffer, &buffer_len, &stat);
    if (rc != ZOK || buffer_len <= 0) {
      return 0;
    }
    buffer[buffer_len] = '\0';
    return std::atoi(buffer);
  }

  // --- Asynchronous API ---
  // Callbacks fire on ZooKeeper's internal I/O thread (zookeeper_mt).

  int ReadAsync(int key, std::function<void(int)> on_complete) {
    if (!zh_) {
      if (on_complete) on_complete(ZINVALIDSTATE);
      return ZINVALIDSTATE;
    }
    std::string path = MakeKey(key);
    auto* ctx = new ZkAsyncContext{on_complete, path, "", nullptr};
    int rc = zoo_aget(zh_, path.c_str(), 0, ReadAsyncCallback, ctx);
    if (rc != ZOK) {
      if (on_complete) on_complete(rc);
      delete ctx;
    }
    return rc;
  }

  int WriteAsync(int key, int value, std::function<void(int)> on_complete) {
    if (!zh_) {
      if (on_complete) on_complete(ZINVALIDSTATE);
      return ZINVALIDSTATE;
    }
    std::string path = MakeKey(key);
    std::string val = std::to_string(value);
    // Try set first; on ZNONODE the callback falls back to create.
    auto* ctx = new ZkAsyncContext{on_complete, path, val, zh_};
    int rc = zoo_aset(zh_, path.c_str(), val.c_str(),
                      static_cast<int>(val.size()), -1,
                      WriteSetAsyncCallback, ctx);
    if (rc != ZOK) {
      if (on_complete) on_complete(rc);
      delete ctx;
    }
    return rc;
  }

  void Clear() {
    if (!zh_) return;
    struct String_vector children;
    if (zoo_get_children(zh_, kZookeeperTablePath, 0, &children) == ZOK) {
      for (int i = 0; i < children.count; i++) {
        std::string child_path = std::string(kZookeeperTablePath) + "/" + children.data[i];
        zoo_delete(zh_, child_path.c_str(), -1);
      }
      deallocate_String_vector(&children);
    }
  }
};

} // namespace janus
