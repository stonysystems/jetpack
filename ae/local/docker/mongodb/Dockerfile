# Docker environment for Jetpack + MongoDB integration testing.
#
# Builds Jetpack with all backend libraries (mongocxx, etcd-cpp-api,
# libzookeeper) since WAF compiles all integration modules, then
# bundles a MongoDB server for self-contained integration testing.
#
# Build:
#   docker build --network=host -t jetpack-mongodb -f docker/mongodb/Dockerfile .
#
# Run (single-process test):
#   docker run --rm --privileged jetpack-mongodb
#
# Run (interactive):
#   docker run --rm --privileged -it jetpack-mongodb bash

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Build dependencies for Jetpack + all backend libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    python2 \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    wget \
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
    # ZooKeeper C client dependencies
    #
    # Jetpack dependencies
    libboost-all-dev \
    libyaml-cpp-dev \
    libjemalloc-dev \
    libgoogle-perftools-dev \
    libapr1-dev \
    libaprutil1-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for WAF build and test scripts
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir pyyaml tabulate numpy setuptools || true

WORKDIR /build

# Copy third_party first so cmake builds below are cached independently of
# Jetpack source changes. When only src/ changes, Docker skips re-running
# the slow cmake build steps and only re-runs rpcgen + WAF (~6 min).
COPY third_party/ /build/third_party/

# Validate required third_party submodules are populated in build context.
# If these directories are empty placeholders, initialize submodules on host:
#   git submodule update --init --recursive
RUN test -f /build/third_party/mongo-c-driver/CMakeLists.txt && \
    test -f /build/third_party/mongo-c-driver/build/cmake/BuildVersion.cmake && \
    test -f /build/third_party/mongo-c-driver/build/cmake/ParseVersion.cmake && \
    test -f /build/third_party/mongo-cxx-driver/CMakeLists.txt && \
    test -f /build/third_party/etcd-cpp-apiv3/CMakeLists.txt && \
    test -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/CMakeLists.txt || \
    (echo "ERROR: Missing third_party submodule sources in Docker build context." >&2 && \
     echo "Also check .dockerignore does not exclude third_party/mongo-c-driver/build/cmake." >&2 && \
     echo "Run: git submodule update --init --recursive" >&2 && \
     exit 1)

# Build mongo-c-driver (libmongoc + libbson)
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

# Build mongo-cxx-driver (mongocxx + bsoncxx)
RUN cd /build/third_party/mongo-cxx-driver && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DCMAKE_PREFIX_PATH=/usr/local \
        -DBUILD_VERSION=3.10.1 \
        -DBSONCXX_POLY_USE_BOOST=1 \
        -DMONGOCXX_OVERRIDE_DEFAULT_INSTALL_PREFIX=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Build etcd-cpp-apiv3 library
RUN cd /build/third_party/etcd-cpp-apiv3 && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DBUILD_ETCD_TESTS=OFF \
        -DBUILD_SHARED_LIBS=ON && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Generate ZooKeeper jute C sources required by zookeeper-client-c CMake build.
# Skip maven generation if jute files are already pre-generated on host.
RUN if [ -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/generated/zookeeper.jute.h ] && \
       [ -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/generated/zookeeper.jute.c ]; then \
        echo "Jute files already exist, skipping maven generation"; \
    else \
        cd /build/third_party/zookeeper && \
        mvn generate-sources -pl zookeeper-jute -q -DskipTests; \
    fi && \
    test -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/generated/zookeeper.jute.h && \
    test -f /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c/generated/zookeeper.jute.c

# Build ZooKeeper C client.
# Note: ZooKeeper's CMakeLists.txt has no install() rules, so we manually
# install headers and libraries after building.
RUN cd /build/third_party/zookeeper/zookeeper-client/zookeeper-client-c && \
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

# Update library cache so linker can find all libraries
RUN ldconfig

# Copy Jetpack source and build files. This COPY is invalidated by source
# changes but all third_party cmake layers above remain cached.
COPY . /build/

# Generate RPC files (rpcgen requires python2)
RUN python2 bin/rpcgen --python --cpp src/deptran/rcc_rpc.rpc

# Build Jetpack (WAF). Ubuntu 22.04 ships Python 3.10 which is compatible.
RUN python3 waf configure && python3 waf build -j"$(nproc)"

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Runtime libraries (all backends)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libsasl2-2 \
    libzstd1 \
    libsnappy1v5 \
    zlib1g \
    libicu70 \
    libboost-system1.74.0 \
    libboost-thread1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-coroutine1.74.0 \
    libyaml-cpp0.7 \
    libjemalloc2 \
    libgoogle-perftools4 \
    libapr1 \
    libaprutil1 \
    libprotobuf23 \
    libgrpc++1 \
    libcpprest \
    python3 \
    python3-yaml \
    wget \
    curl \
    gnupg \
    ca-certificates \
    procps \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install MongoDB server (mongod + mongosh) from official MongoDB repo
ARG MONGODB_VERSION=7.0
ADD https://pgp.mongodb.com/server-${MONGODB_VERSION}.asc /tmp/mongodb-server.asc
RUN gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg /tmp/mongodb-server.asc && \
    rm /tmp/mongodb-server.asc && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg ] \
    https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/${MONGODB_VERSION} multiverse" | \
    tee /etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        mongodb-org-server \
        mongodb-org-mongos \
        mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/*

# Copy built libraries from builder (all backends)
COPY --from=builder /usr/local/lib/libmongoc* /usr/local/lib/
COPY --from=builder /usr/local/lib/libbson* /usr/local/lib/
COPY --from=builder /usr/local/lib/libmongocxx* /usr/local/lib/
COPY --from=builder /usr/local/lib/libbsoncxx* /usr/local/lib/
COPY --from=builder /usr/local/lib/libetcd* /usr/local/lib/
# ZooKeeper and hashtable are statically linked, no runtime copy needed
RUN ldconfig

# Copy Jetpack build artifacts
COPY --from=builder /build/build/ /jetpack/build/
COPY --from=builder /build/config/ /jetpack/config/
COPY --from=builder /build/scripts/ /jetpack/scripts/
COPY --from=builder /build/docker/mongodb/run-mongodb-test.sh /jetpack/run-mongodb-test.sh
COPY --from=builder /build/docker/mongodb/test-mongodb-setup.sh /jetpack/test-mongodb-setup.sh

WORKDIR /jetpack

# Expose MongoDB port and Jetpack server ports
EXPOSE 27017

# Health check for MongoDB
HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
    CMD mongosh --eval "db.adminCommand('ping')" --host 127.0.0.1:27017 --quiet || exit 1

ENTRYPOINT ["/jetpack/run-mongodb-test.sh"]
CMD ["single"]
