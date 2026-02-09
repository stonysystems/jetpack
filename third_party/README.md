# Third-Party Dependencies

This directory contains third-party source code as git submodules.

## MongoDB Drivers

| Submodule | Version | Description |
|-----------|---------|-------------|
| `mongo-c-driver` | 1.27.1 | MongoDB C driver (libmongoc + libbson) |
| `mongo-cxx-driver` | r3.10.1 | MongoDB C++ driver (mongocxx + bsoncxx) |

### Build

```bash
# Install system prerequisites (Ubuntu/Debian)
sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
    libsasl2-dev libzstd-dev libsnappy-dev zlib1g-dev libicu-dev

# Initialize submodules (if not already done)
git submodule update --init third_party/mongo-c-driver third_party/mongo-cxx-driver

# Build and install (default prefix: /usr/local)
cd third_party
./build_mongodb.sh

# Or with custom prefix
./build_mongodb.sh --prefix ~/.local
```

### MongoDB Server

The MongoDB server (mongod v7.0) is installed separately via the system
package manager. See `dep.sh` for the full installation procedure.

## etcd C++ Client

| Submodule | Version | Description |
|-----------|---------|-------------|
| `etcd-cpp-apiv3` | v0.2.14 | C++ client for etcd v3 API |

### Build

```bash
# Install system prerequisites (Ubuntu/Debian)
sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
    libboost-all-dev libprotobuf-dev protobuf-compiler \
    libgrpc++-dev protobuf-compiler-grpc libcpprest-dev

# Initialize submodule (if not already done)
git submodule update --init third_party/etcd-cpp-apiv3

# Build and install (default prefix: /usr/local)
cd third_party
./build_etcd.sh

# Or with custom prefix
./build_etcd.sh --prefix ~/.local
```

### etcd Server

The etcd server is installed separately. See the
[etcd releases](https://github.com/etcd-io/etcd/releases) page.

## ZooKeeper C Client

| Submodule | Version | Description |
|-----------|---------|-------------|
| `zookeeper` | 3.9.4 | Apache ZooKeeper (C client at `zookeeper-client/zookeeper-client-c/`) |

The ZooKeeper C client provides both synchronous and asynchronous APIs
(`zookeeper_mt` library with `-DTHREADED`). Only the C client subdirectory
is used; the rest of the repository is needed for jute code generation.

### Build

```bash
# Install system prerequisites (Ubuntu/Debian)
sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
    libsasl2-dev default-jdk maven

# Initialize submodule (if not already done)
git submodule update --init third_party/zookeeper

# Build and install (default prefix: /usr/local)
cd third_party
./build_zookeeper.sh

# Or with custom prefix
./build_zookeeper.sh --prefix ~/.local
```

Note: Maven and Java are required to generate the jute serialization files
(`zookeeper.jute.c`, `zookeeper.jute.h`) from the git checkout. The build
script handles this automatically and skips generation if the files already
exist.

### ZooKeeper Server

The ZooKeeper server is installed separately. See the
[Apache ZooKeeper releases](https://zookeeper.apache.org/releases.html) page.
