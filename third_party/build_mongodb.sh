#!/bin/bash
# Build MongoDB C and C++ drivers from third_party/ submodules.
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
#       libsasl2-dev libzstd-dev libsnappy-dev zlib1g-dev libicu-dev
#
# Usage:
#   cd third_party && ./build_mongodb.sh [--prefix /usr/local]
#
# This builds:
#   1. mongo-c-driver (libmongoc + libbson) v1.27.1
#   2. mongo-cxx-driver (mongocxx + bsoncxx) r3.10.1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${1:-/usr/local}"

if [ "$1" = "--prefix" ] 2>/dev/null; then
    PREFIX="${2:-/usr/local}"
fi

echo "=== Building MongoDB drivers ==="
echo "  Source: ${SCRIPT_DIR}"
echo "  Install prefix: ${PREFIX}"
echo ""

# Step 1: Build mongo-c-driver (libmongoc)
echo "=== Step 1/2: Building mongo-c-driver (libmongoc + libbson) ==="
cd "${SCRIPT_DIR}/mongo-c-driver"
mkdir -p cmake-build && cd cmake-build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF
cmake --build . -- -j"$(nproc)"
sudo cmake --build . --target install
echo "  mongo-c-driver installed to ${PREFIX}"
echo ""

# Step 2: Build mongo-cxx-driver (mongocxx)
echo "=== Step 2/2: Building mongo-cxx-driver (mongocxx + bsoncxx) ==="
cd "${SCRIPT_DIR}/mongo-cxx-driver"
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DBSONCXX_POLY_USE_BOOST=1 \
    -DMONGOCXX_OVERRIDE_DEFAULT_INSTALL_PREFIX=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF
cmake --build . -- -j"$(nproc)"
sudo cmake --build . --target install
echo "  mongo-cxx-driver installed to ${PREFIX}"
echo ""

echo "=== Done. MongoDB C/C++ drivers installed to ${PREFIX} ==="
echo ""
echo "Verify with:"
echo "  pkg-config --modversion libmongoc-1.0"
echo "  pkg-config --modversion libmongocxx"
