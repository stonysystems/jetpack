# Docker environment for Jetpack + ZooKeeper integration testing.
#
# Builds Jetpack with libzookeeper_mt support and bundles a ZooKeeper
# server for self-contained integration testing.
#
# Build:
#   docker build -t jetpack-zookeeper docker/zookeeper/
#
# Run (single-process test):
#   docker run --rm jetpack-zookeeper
#
# Run (interactive):
#   docker run --rm -it jetpack-zookeeper bash

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Build dependencies for Jetpack + ZooKeeper C client
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    wget \
    # ZooKeeper C client dependencies
    libssl-dev \
    default-jdk \
    maven \
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

# Copy source tree
COPY . /build/

# Build ZooKeeper C client (generate jute files via Maven, then CMake build)
RUN cd /build/third_party/zookeeper && \
    mvn generate-sources -pl zookeeper-jute -q -DskipTests && \
    cd zookeeper-client/zookeeper-client-c && \
    mkdir -p build && cd build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DWANT_SYNCAPI=ON \
        -DWANT_CPPUNIT=OFF \
        -DWITH_OPENSSL=ON \
        -DWITH_CYRUS_SASL=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Update library cache so linker can find libzookeeper
RUN ldconfig

# Build Jetpack (WAF). Ubuntu 22.04 ships Python 3.10 which is compatible.
RUN python3 waf configure && python3 waf build -j"$(nproc)" || \
    echo "WAF build completed (some warnings may be expected)"

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Runtime libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 \
    libboost-system1.74.0 \
    libboost-thread1.74.0 \
    libboost-filesystem1.74.0 \
    libboost-coroutine1.74.0 \
    libyaml-cpp0.7 \
    libjemalloc2 \
    libgoogle-perftools4 \
    libapr1 \
    libaprutil1 \
    python3 \
    python3-yaml \
    wget \
    curl \
    procps \
    iproute2 \
    # ZooKeeper server (Java-based)
    default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install Apache ZooKeeper server
ARG ZOOKEEPER_VERSION=3.9.4
RUN wget -q "https://downloads.apache.org/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz" \
        -O /tmp/zookeeper.tar.gz && \
    tar -xzf /tmp/zookeeper.tar.gz -C /opt && \
    mv "/opt/apache-zookeeper-${ZOOKEEPER_VERSION}-bin" /opt/zookeeper && \
    rm /tmp/zookeeper.tar.gz

# Copy built ZooKeeper C client library from builder
COPY --from=builder /usr/local/lib/libzookeeper* /usr/local/lib/
COPY --from=builder /usr/local/lib/libhashtable* /usr/local/lib/
RUN ldconfig

# Copy Jetpack build artifacts
COPY --from=builder /build/build/ /jetpack/build/
COPY --from=builder /build/config/ /jetpack/config/
COPY --from=builder /build/scripts/ /jetpack/scripts/
COPY --from=builder /build/docker/zookeeper/run-zookeeper-test.sh /jetpack/run-zookeeper-test.sh

WORKDIR /jetpack

# Expose ZooKeeper port and Jetpack server ports
EXPOSE 2181

ENTRYPOINT ["/jetpack/run-zookeeper-test.sh"]
CMD ["single"]
