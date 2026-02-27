#include <iostream>
#include <bsoncxx/json.hpp>
#include <mongocxx/client.hpp>
#include <mongocxx/instance.hpp>
#include <mongocxx/uri.hpp>

// g++ -std=c++17 simple_mongo.cpp -o simple_mongo $(pkg-config --cflags --libs libmongocxx)
// ./simple_mongo

int main() {
    // Required: only one instance per process
    mongocxx::instance inst{};

    // Connect to your replica set (adjust URI if needed)
    // For your 5-node local setup:
    mongocxx::uri uri(
        "mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017,"
        "127.0.0.4:27017,127.0.0.5:27017"
    );

    try {
        mongocxx::client client(uri);

        auto db = client["test_db"];
        auto coll = db["test_collection"];

        // Insert one document
        bsoncxx::builder::basic::document builder{};
        builder.append(
            bsoncxx::builder::basic::kvp("name", "weihai"),
            bsoncxx::builder::basic::kvp("answer", 42),
            bsoncxx::builder::basic::kvp("note", "hello from C++")
        );

        auto insert_result = coll.insert_one(builder.view());
        if (!insert_result) {
            std::cerr << "Insert failed\n";
            return 1;
        }

        std::cout << "Inserted document with _id: "
                  << insert_result->inserted_id().get_oid().value.to_string()
                  << std::endl;

        // Find one document
        auto maybe_doc = coll.find_one({});
        if (maybe_doc) {
            std::cout << "Found document: "
                      << bsoncxx::to_json(*maybe_doc) << std::endl;
        } else {
            std::cout << "No document found\n";
        }

    } catch (const std::exception& e) {
        std::cerr << "MongoDB exception: " << e.what() << std::endl;
        return 1;
    }

    return 0;
}

