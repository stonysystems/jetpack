#!/bin/bash
# Build etcd C++ client library (etcd-cpp-apiv3) from third_party/ submodule.
#
# Prerequisites (Ubuntu/Debian):
#   sudo apt-get install -y build-essential cmake libssl-dev pkg-config \
#       libboost-all-dev libprotobuf-dev protobuf-compiler \
#       libgrpc++-dev protobuf-compiler-grpc \
#       libcpprest-dev
#
# Usage:
#   cd third_party && ./build_etcd.sh [--prefix /usr/local]
#
# This builds:
#   etcd-cpp-apiv3 v0.2.14 (C++ client for etcd v3 API)
#   Produces: libetcd-cpp-api.so

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREFIX="/usr/local"

if [ "${1:-}" = "--prefix" ]; then
    PREFIX="${2:-/usr/local}"
fi

echo "=== Building etcd-cpp-apiv3 ==="
echo "  Source: ${SCRIPT_DIR}/etcd-cpp-apiv3"
echo "  Install prefix: ${PREFIX}"
echo ""

cd "${SCRIPT_DIR}/etcd-cpp-apiv3"
mkdir -p build && cd build
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DBUILD_ETCD_TESTS=OFF \
    -DBUILD_SHARED_LIBS=ON
cmake --build . -- -j"$(nproc)"
sudo cmake --build . --target install
echo ""
echo "=== Done. etcd-cpp-apiv3 installed to ${PREFIX} ==="
echo ""
echo "Verify with:"
echo "  pkg-config --modversion etcd-cpp-api || ls ${PREFIX}/lib/libetcd-cpp-api*"
