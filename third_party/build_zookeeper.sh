#!/bin/bash
# Build Apache ZooKeeper C client library from third_party/ submodule.
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
#       libsasl2-dev default-jdk maven
#
# Usage:
#   cd third_party && ./build_zookeeper.sh [--prefix /usr/local]
#
# This builds:
#   Apache ZooKeeper C client v3.9.4
#   Produces: libzookeeper.a (static library with sync+async API)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="/usr/local"

if [ "${1:-}" = "--prefix" ]; then
    PREFIX="${2:-/usr/local}"
fi

ZK_ROOT="${SCRIPT_DIR}/zookeeper"
ZK_C_CLIENT="${ZK_ROOT}/zookeeper-client/zookeeper-client-c"

echo "=== Building Apache ZooKeeper C client ==="
echo "  Source: ${ZK_C_CLIENT}"
echo "  Install prefix: ${PREFIX}"
echo ""

# Step 1: Generate jute C files via Maven (required for git checkouts)
GENERATED_DIR="${ZK_C_CLIENT}/generated"
if [ ! -f "${GENERATED_DIR}/zookeeper.jute.c" ] || \
   [ ! -f "${GENERATED_DIR}/zookeeper.jute.h" ]; then
    echo "=== Step 1/2: Generating jute C files via Maven ==="
    cd "${ZK_ROOT}"
    mvn generate-sources -pl zookeeper-jute -q -DskipTests
    echo "  Generated: ${GENERATED_DIR}/zookeeper.jute.{c,h}"
    echo ""
else
    echo "=== Step 1/2: Jute C files already generated (skipping Maven) ==="
    echo ""
fi

# Step 2: Build C client with CMake
echo "=== Step 2/2: Building ZooKeeper C client ==="
cd "${ZK_C_CLIENT}"
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DWANT_SYNCAPI=ON \
    -DWANT_CPPUNIT=OFF \
    -DWITH_OPENSSL=ON \
    -DWITH_CYRUS_SASL=OFF
cmake --build . -- -j"$(nproc)"
sudo cmake --build . --target install
echo ""
echo "=== Done. ZooKeeper C client installed to ${PREFIX} ==="
echo ""
echo "Verify with:"
echo "  ls ${PREFIX}/lib/libzookeeper* ${PREFIX}/include/zookeeper/zookeeper.h"
