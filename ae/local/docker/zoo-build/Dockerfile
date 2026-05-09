# Build Jetpack for Zoo cluster machines.
# Uses Ubuntu 22.04 as the base (lowest glibc version among Zoo machines).
# The resulting binary is compatible with all Zoo servers:
#   - 130.245.173.101: Debian trixie (glibc 2.38)
#   - 130.245.173.102: Ubuntu 22.04 (glibc 2.35)
#   - 130.245.173.103: Debian bookworm (glibc 2.36)
#   - 130.245.173.104: Ubuntu 22.04 (glibc 2.35)
#   - 130.245.173.105: Debian trixie (glibc 2.38)
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    wget \
    ca-certificates \
    # MongoDB driver dependencies
    libssl-dev \
    libsasl2-dev \
    libzstd-dev \
    libsnappy-dev \
    zlib1g-dev \
    libicu-dev \
    # etcd dependencies
    libprotobuf-dev \
    protobuf-compiler \
    protobuf-compiler-grpc \
    libgrpc++-dev \
    libcpprest-dev \
    # ZooKeeper jute generation dependencies
    default-jdk-headless \
    maven \
    # Jetpack dependencies
    libboost-all-dev \
    libyaml-cpp-dev \
    libjemalloc-dev \
    libgoogle-perftools-dev \
    libapr1-dev \
    libaprutil1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy third_party first for caching
COPY third_party/ /build/third_party/

# Build mongo-c-driver
RUN cd /build/third_party/mongo-c-driver && \
    mkdir -p cmake-build && cd cmake-build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DENABLE_AUTOMATIC_INIT_AND_CLEANUP=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Build mongo-cxx-driver (version pinned to avoid git describe in Docker)
RUN cd /build/third_party/mongo-cxx-driver && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DBSONCXX_POLY_USE_BOOST=1 \
        -DMONGOCXX_OVERRIDE_DEFAULT_INSTALL_PREFIX=OFF \
        -DBUILD_VERSION=3.10.1 \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Build etcd-cpp-apiv3
RUN cd /build/third_party/etcd-cpp-apiv3 && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_ETCD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Generate ZooKeeper jute files and build C client
RUN if [ -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/generated/zookeeper.jute.h ]; then \
        echo "Jute files exist"; \
    else \
        cd /build/third_party/zookeeper && \
        mvn generate-sources -pl zookeeper-jute -q -DskipTests; \
    fi && \
    cd /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DWANT_SYNCAPI=ON \
        -DWANT_CPPUNIT=OFF \
        -DWITH_OPENSSL=ON \
        -DWITH_CYRUS_SASL=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    mkdir -p /usr/local/include/zookeeper && \
    cp ../include/*.h /usr/local/include/zookeeper/ && \
    cp ../generated/zookeeper.jute.h /usr/local/include/zookeeper/ && \
    cp include/config.h /usr/local/include/zookeeper/ && \
    cp libzookeeper.a /usr/local/lib/ && \
    cp libhashtable.a /usr/local/lib/

RUN ldconfig

# Copy full source (includes pre-generated RPC files from host)
COPY . /build/

# Build Jetpack
RUN python3 waf configure && python3 waf build -j"$(nproc)"

# Collect all needed shared libraries into /output/lib
# This includes third-party libs and system libs that may differ across Zoo machines
RUN mkdir -p /output/lib && \
    cp /build/build/deptran_server /output/ && \
    # Use ldd to find all shared library dependencies and copy them
    ldd /build/build/deptran_server | grep "=> /" | awk '{print $3}' | sort -u | \
    while read lib; do cp "$lib" /output/lib/ 2>/dev/null; done && \
    # Also copy the dynamic linker
    cp /lib64/ld-linux-x86-64.so.2 /output/lib/ 2>/dev/null || true && \
    ls -la /output/lib/ | wc -l
