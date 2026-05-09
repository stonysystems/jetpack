#pragma once


#include "mongocxx/instance.hpp"
#include "mongocxx/client.hpp"
#include "mongocxx/database.hpp"
#include "mongocxx/uri.hpp"

#include "bsoncxx/builder/stream/document.hpp"
#include "bsoncxx/oid.hpp"

namespace janus {

// mongocxx requires exactly one instance to exist before any driver use.
// Uses Meyer's singleton pattern for thread-safe lazy initialization.
inline mongocxx::instance& GetMongoInstance() {
  static mongocxx::instance inst{};
  return inst;
}

// Camera-ready linearizable contract: every operation through these
// clients carries writeConcern={w:"majority", j:true} +
// readConcern="linearizable" + readPreference="primary". The mongo-cxx-
// driver picks these up from the URI and applies them as defaults on
// the client / database / collection — no per-operation patching needed.
// See results/2026-04-30-camera-ready-exp0-small/settings.md
// "MongoDB configuration: linearizable consistency".
//
// `--enable-mongodb-no-journal` flips `journal=true` to `journal=false`
// in the URI so writes ack before the server has flushed the journal.
// This is the only fsync-off-equivalent knob since mongodb 7+ removed
// `storage.journal.enabled` server-side (journal is mandatory for
// WiredTiger). Used by 2026-05-09 task 5 (mongodb fsync-off rerun).
#ifdef MONGODB_NO_JOURNAL
#define JANUS_MONGO_LINEARIZABLE_OPTS \
  "w=majority&journal=false&readConcernLevel=linearizable&readPreference=primary"
#else
#define JANUS_MONGO_LINEARIZABLE_OPTS \
  "w=majority&journal=true&readConcernLevel=linearizable&readPreference=primary"
#endif

#if defined(JETPACK_MONGODB_RECOVERY)
// Use local loopback in recovery mode to avoid changing legacy defaults.
constexpr char kMongoDbUri[] =
    "mongodb://127.0.0.1:27017/?" JANUS_MONGO_LINEARIZABLE_OPTS;
#else
#ifdef AWS
constexpr char kMongoDbUri[] =
    "mongodb://184.72.49.232:27017/?" JANUS_MONGO_LINEARIZABLE_OPTS;
#endif
#ifndef AWS
constexpr char kMongoDbUri[] =
    "mongodb://130.245.173.103:27017/?" JANUS_MONGO_LINEARIZABLE_OPTS;
#endif
#endif

constexpr char kDatabaseName[] = "JetPack";
constexpr char kCollectionName[] = "KVTable";

class MongodbKVTableHandler {
 private:
  // Force mongocxx::instance initialization before any driver objects.
  struct InstanceGuard { InstanceGuard() { GetMongoInstance(); } };
  InstanceGuard instance_guard_;
  std::string uri_str_;
  mongocxx::uri uri;
  mongocxx::client client;
  mongocxx::database db;
  mongocxx::collection collection;
 public:
  explicit MongodbKVTableHandler(const std::string& uri_str = kMongoDbUri)
    : instance_guard_(),
      uri_str_(uri_str),
      uri(mongocxx::uri(uri_str_)),
      client(mongocxx::client(uri)),
      db(client[kDatabaseName]),
      collection(db[kCollectionName]) {
    Setup();
  }

  ~MongodbKVTableHandler() {
    
  }

  bool Write(int key, int value) {
    // char kCollectionName[10];
    // std::string str = std::to_string(key);
    // str.copy(kCollectionName, str.length());
    // kCollectionName[str.length()] = '\0';

    // mongocxx::collection collection = db[kCollectionName];
    auto filter_builder = bsoncxx::builder::stream::document{};
    auto update_builder = bsoncxx::builder::stream::document{};


    bsoncxx::document::value filter =
      filter_builder << "key" << key << bsoncxx::builder::stream::finalize;

    bsoncxx::document::value update =
      update_builder << "$set" << bsoncxx::builder::stream::open_document
                    << "value" << value << bsoncxx::builder::stream::close_document
                    << bsoncxx::builder::stream::finalize;

    try {
      mongocxx::stdx::optional<mongocxx::result::update> result =
          collection.update_one(filter.view(), update.view(), mongocxx::options::update{}.upsert(true));

      if (result) {
        return true;
      }
    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
    }
    // If the operation failed, return false
    return false;
  }


  int Read(int key) {
    // char kCollectionName[10];
    // std::string str = std::to_string(key);
    // str.copy(kCollectionName, str.length());
    // kCollectionName[str.length()] = '\0';
    // mongocxx::collection collection = db[kCollectionName];

    auto filter_builder = bsoncxx::builder::stream::document{};
    
    bsoncxx::document::value filter =
      filter_builder << "key" << key << bsoncxx::builder::stream::finalize;

    try {
      bsoncxx::stdx::optional<bsoncxx::document::value> result =
        collection.find_one(filter.view());

      if (result) {
        bsoncxx::document::view view = result->view();
        auto value_element = view["value"];
        if (value_element && value_element.type() == bsoncxx::type::k_int32) {
          return value_element.get_int32().value;
        }
      }
    } catch (const std::exception& e) {
      std::cerr << "Error: " << e.what() << std::endl;
    }
    // If document does not exist or value is not found, return 0
    return 0;
  }

  void Clear() {
    try {
      db.drop();
        // mongocxx::stdx::optional<mongocxx::result::delete_result> result =
        //     collection.delete_many({});
        // assert(result);
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
    }
  }

  // document: {"_ids": 122323, "v": 2323}

  void Setup() {
    auto index_builder = bsoncxx::builder::stream::document{};
    bsoncxx::document::value index =
        index_builder << "key" << 1 << bsoncxx::builder::stream::finalize;
    try {
      bsoncxx::stdx::optional<bsoncxx::document::value> result =
        collection.create_index(index.view());
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
    }
    
  }

};

} // end of namespace
