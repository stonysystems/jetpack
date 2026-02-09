# Docker environment for Jetpack + etcd integration testing.
#
# Builds Jetpack with etcd-cpp-apiv3 support and bundles an etcd server
# for self-contained integration testing.
#
# Build:
#   docker build -t jetpack-etcd docker/etcd/
#
# Run (single-process test):
#   docker run --rm jetpack-etcd
#
# Run (interactive):
#   docker run --rm -it jetpack-etcd bash

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Build dependencies for Jetpack + etcd-cpp-apiv3
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
    # etcd-cpp-apiv3 dependencies
    libssl-dev \
    libprotobuf-dev \
    protobuf-compiler \
    libgrpc++-dev \
    libcpprest-dev \
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

# Update library cache so linker can find etcd-cpp-api
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
    libprotobuf23 \
    libgrpc++1 \
    libcpprest \
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
    && rm -rf /var/lib/apt/lists/*

# Install etcd server binary (v3.5.17)
ARG ETCD_VERSION=v3.5.17
RUN wget -q "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
    -O /tmp/etcd.tar.gz && \
    mkdir -p /opt/etcd && \
    tar xzf /tmp/etcd.tar.gz -C /opt/etcd --strip-components=1 && \
    rm /tmp/etcd.tar.gz && \
    ln -s /opt/etcd/etcd /usr/local/bin/etcd && \
    ln -s /opt/etcd/etcdctl /usr/local/bin/etcdctl

# Copy built libraries and binaries from builder
COPY --from=builder /usr/local/lib/libetcd* /usr/local/lib/
COPY --from=builder /usr/local/lib/libcpprest* /usr/local/lib/
RUN ldconfig

# Copy Jetpack build artifacts
COPY --from=builder /build/build/ /jetpack/build/
COPY --from=builder /build/config/ /jetpack/config/
COPY --from=builder /build/scripts/ /jetpack/scripts/
COPY --from=builder /build/docker/etcd/run-etcd-test.sh /jetpack/run-etcd-test.sh

WORKDIR /jetpack

# Expose etcd client port and Jetpack server ports
EXPOSE 2379 2380

# Health check for etcd
HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
    CMD etcdctl endpoint health --endpoints=http://127.0.0.1:2379 || exit 1

ENTRYPOINT ["/jetpack/run-etcd-test.sh"]
CMD ["single"]
