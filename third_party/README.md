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
