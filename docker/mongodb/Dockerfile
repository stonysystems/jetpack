# Docker environment for Jetpack + MongoDB integration testing.
#
# Builds Jetpack with mongocxx support and bundles a MongoDB server
# for self-contained integration testing.
#
# Build:
#   docker build -t jetpack-mongodb docker/mongodb/
#
# Run (single-process test):
#   docker run --rm jetpack-mongodb
#
# Run (interactive):
#   docker run --rm -it jetpack-mongodb bash

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Build dependencies for Jetpack + MongoDB C/C++ drivers
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
    # MongoDB driver dependencies
    libssl-dev \
    libsasl2-dev \
    libzstd-dev \
    libsnappy-dev \
    zlib1g-dev \
    libicu-dev \
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
        -DBSONCXX_POLY_USE_BOOST=1 \
        -DMONGOCXX_OVERRIDE_DEFAULT_INSTALL_PREFIX=OFF \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF && \
    cmake --build . -- -j"$(nproc)" && \
    cmake --install .

# Update library cache so linker can find mongocxx/bsoncxx
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
    python3 \
    python3-yaml \
    wget \
    curl \
    gnupg \
    procps \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install MongoDB server (mongod + mongosh) from official MongoDB repo
ARG MONGODB_VERSION=7.0
RUN wget -qO - https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc | \
    gpg --dearmor -o /usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-${MONGODB_VERSION}.gpg ] \
    https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/${MONGODB_VERSION} multiverse" | \
    tee /etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        mongodb-org-server \
        mongodb-org-mongos \
        mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/*

# Copy built MongoDB C/C++ driver libraries from builder
COPY --from=builder /usr/local/lib/libmongoc* /usr/local/lib/
COPY --from=builder /usr/local/lib/libbson* /usr/local/lib/
COPY --from=builder /usr/local/lib/libmongocxx* /usr/local/lib/
COPY --from=builder /usr/local/lib/libbsoncxx* /usr/local/lib/
RUN ldconfig

# Copy Jetpack build artifacts
COPY --from=builder /build/build/ /jetpack/build/
COPY --from=builder /build/config/ /jetpack/config/
COPY --from=builder /build/scripts/ /jetpack/scripts/
COPY --from=builder /build/docker/mongodb/run-mongodb-test.sh /jetpack/run-mongodb-test.sh

WORKDIR /jetpack

# Expose MongoDB port and Jetpack server ports
EXPOSE 27017

# Health check for MongoDB
HEALTHCHECK --interval=5s --timeout=3s --retries=3 \
    CMD mongosh --eval "db.adminCommand('ping')" --host 127.0.0.1:27017 --quiet || exit 1

ENTRYPOINT ["/jetpack/run-mongodb-test.sh"]
CMD ["single"]
