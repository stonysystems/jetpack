# Build Jetpack for Debian 13 (trixie) Zoo machines.
# Matches the library versions on the Zoo cluster.
FROM debian:trixie

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

# Output stage: binary, third-party libs, and required system libs
FROM debian:trixie-slim
COPY --from=0 /build/build/deptran_server /output/build/deptran_server
# Third-party libraries
COPY --from=0 /usr/local/lib/libmongoc* /output/lib/
COPY --from=0 /usr/local/lib/libbson* /output/lib/
COPY --from=0 /usr/local/lib/libmongocxx* /output/lib/
COPY --from=0 /usr/local/lib/libbsoncxx* /output/lib/
COPY --from=0 /usr/local/lib/libetcd* /output/lib/
COPY --from=0 /usr/local/lib/libzookeeper.a /output/lib/
COPY --from=0 /usr/local/lib/libhashtable.a /output/lib/
# System libraries not present on Zoo machines
COPY --from=0 /usr/lib/x86_64-linux-gnu/libcpprest.so.2.10 /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libgrpc++.so.1.51* /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libgrpc.so.29* /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libgpr.so.29* /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libupb.so.29* /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libaddress_sorting.so.29* /output/lib/
COPY --from=0 /usr/lib/x86_64-linux-gnu/libre2.so.11* /output/lib/
CMD ["echo", "Build complete. Copy /output/ contents to target."]
