#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
    zoo_directory=$(jq -r '.zoo_directory' setup.json)  # Read zoo_directory from setup.json
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

# Set SERVER_USERNAME to "ubuntu" for both AWS and Zoo environments
SERVER_USERNAME="ubuntu"

# Function to handle zoo directory
handle_zoo_directory() {
    if [ "$zoo_directory" != "null" ] && [ -n "$zoo_directory" ]; then
        echo "Using zoo directory from setup.json: $zoo_directory"
    else
        # Ask for the zoo directory if it's not found in setup.json
        echo "Please enter the directory for the experiment on Zoo (e.g., /home/users/ztang/janus):"
        read -r zoo_directory
        # Update setup.json with the new zoo_directory
        jq --arg zoo_directory "$zoo_directory" '.zoo_directory = $zoo_directory' setup.json > tmp.json && mv tmp.json setup.json
        echo "Zoo directory saved to setup.json."
    fi
    # Set the repo_directory to zoo_directory
    repo_directory="$zoo_directory"
}

# Determine environment based on setup.json
if [ "$experiment_env" == "zoo" ]; then
    # Handle Zoo-specific settings
    echo "Zoo environment detected."
    handle_zoo_directory
    commands="sudo $repo_directory/dep.sh"
else
    # Default to AWS settings
    echo "AWS environment detected."
    repo_directory="/home/${SERVER_USERNAME}/code/JetPack"
    commands="cd $repo_directory && ./dep.sh"
    echo "Using default AWS directory: $repo_directory"
fi

# Define an array of server IP addresses dynamically from setup.json
declare -a servers
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists in the JSON file
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        servers+=("${server_ip}")
    else
        echo "Error: IP for server $i is not set or empty in setup.json."
        exit 1
    fi
done

# Debug: Print the servers array to ensure it's populated correctly
echo "Servers array: ${servers[@]}"

# Declare an array to track background job IDs
declare -a jobs

# SKIP_DEP=1 skips the dep.sh run on every server. Useful on reruns since
# dep.sh re-extracts and rebuilds the mongo-cxx-driver tarball every time.
if [[ "${SKIP_DEP:-0}" == "1" ]]; then
    echo "SKIP_DEP=1: skipping dep.sh run on all servers."
else
    # Iterate through the list of server IPs and execute the command in parallel
    for i in $(seq 0 $((N_SERVER - 1))); do
        server_ip="${servers[$i]}"

        # Displaying which server is currently being accessed
        echo "Accessing $server_ip ..."

        # SSH into each server and execute the commands in the background
        ssh "${SERVER_USERNAME}@${server_ip}" "$commands" &

        # Save the PID of the background process
        jobs+=($!)
    done

    # Wait for all background jobs to complete
    for job in "${jobs[@]}"; do
        wait $job
    done

    echo "Commands executed on all servers."
fi

# --- Pip fixup ---
# dep.sh's `pip3 install -r requirements.txt` fails on Ubuntu 22.04's stock
# pip 22.0.2 with newer setuptools/packaging because of:
#   TypeError: canonicalize_version() got an unexpected keyword argument 'strip_trailing_zero'
# Upgrading pip pulls in a vendored packaging that has the kwarg, and the
# pip-installs are then retried. Idempotent on reruns (no-op if already healthy).
echo "Running pip fixup on all servers..."
declare -a fixup_jobs
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"
    echo "Fixing pip on $server_ip ..."
    ssh "${SERVER_USERNAME}@${server_ip}" 'set -e
cd /home/ubuntu/code/JetPack
python3 -m pip install --upgrade pip
python3 -m pip install -r requirements.txt
python3 -m pip install Pillow matplotlib pyyaml' &
    fixup_jobs+=($!)
done
for job in "${fixup_jobs[@]}"; do
    wait $job
done
echo "Pip fixup complete."

# --- etcd-cpp-apiv3 build ---
# JetPack's third_party/etcd-cpp-apiv3 is a git submodule that dep.sh doesn't
# handle. Source is NFS-shared, so the submodule is initialized once on
# SERVER_0; each server then builds with an instance-local /tmp build dir to
# avoid NFS write conflicts and installs to /usr/local. Idempotent.
echo "Installing etcd-cpp-apiv3 prereqs on all servers..."
declare -a etcd_apt_jobs
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"
    ssh "${SERVER_USERNAME}@${server_ip}" \
      'sudo apt-get install -y --assume-yes libprotobuf-dev protobuf-compiler libgrpc++-dev protobuf-compiler-grpc libcpprest-dev' &
    etcd_apt_jobs+=($!)
done
for job in "${etcd_apt_jobs[@]}"; do wait $job; done

echo "Initializing third_party/etcd-cpp-apiv3 submodule on SERVER_0..."
ssh "${SERVER_USERNAME}@${servers[0]}" '
set -e
cd /home/ubuntu/code/JetPack
if [ ! -f third_party/etcd-cpp-apiv3/CMakeLists.txt ]; then
  git submodule update --init third_party/etcd-cpp-apiv3
fi
'

echo "Building etcd-cpp-apiv3 on each server (parallel)..."
declare -a etcd_build_jobs
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"
    ssh "${SERVER_USERNAME}@${server_ip}" 'set -e
if [ -f /usr/local/lib/libetcd-cpp-api.so ]; then
  echo "etcd-cpp-api already installed, skipping"
  exit 0
fi
cmake -B /tmp/etcd-build -S /home/ubuntu/code/JetPack/third_party/etcd-cpp-apiv3 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DBUILD_ETCD_TESTS=OFF \
  -DBUILD_SHARED_LIBS=ON
cmake --build /tmp/etcd-build -- -j$(nproc)
sudo cmake --build /tmp/etcd-build --target install
sudo ldconfig
' &
    etcd_build_jobs+=($!)
done
for job in "${etcd_build_jobs[@]}"; do wait $job; done
echo "etcd-cpp-apiv3 build complete."

# --- zookeeper C client build ---
# JetPack's third_party/zookeeper is a git submodule. The jute step requires
# Maven and writes generated .c/.h files into the NFS-shared source tree, so
# it runs once on SERVER_0. Each server then builds the C client with an
# instance-local /tmp build dir (NFS write conflicts otherwise) and installs
# to /usr/local. Idempotent.
echo "Installing zookeeper prereqs on all servers (jdk+maven)..."
declare -a zk_apt_jobs
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"
    ssh "${SERVER_USERNAME}@${server_ip}" \
      'sudo apt-get install -y --assume-yes default-jdk maven libsasl2-dev' &
    zk_apt_jobs+=($!)
done
for job in "${zk_apt_jobs[@]}"; do wait $job; done

echo "Initializing third_party/zookeeper submodule on SERVER_0..."
ssh "${SERVER_USERNAME}@${servers[0]}" '
set -e
cd /home/ubuntu/code/JetPack
if [ ! -d third_party/zookeeper/zookeeper-client ]; then
  git submodule update --init third_party/zookeeper
fi
'

echo "Generating jute C files on SERVER_0 (one-time, output is NFS-shared)..."
ssh "${SERVER_USERNAME}@${servers[0]}" '
set -e
cd /home/ubuntu/code/JetPack/third_party/zookeeper
GENERATED_DIR=zookeeper-client/zookeeper-client-c/generated
if [ ! -f "$GENERATED_DIR/zookeeper.jute.c" ] || [ ! -f "$GENERATED_DIR/zookeeper.jute.h" ]; then
  mvn generate-sources -pl zookeeper-jute -q -DskipTests
fi
'

echo "Building zookeeper C client on each server (parallel)..."
# Note: zookeeper-client-c's CMakeLists.txt has no install() commands, so
# `cmake --target install` is a no-op. We manually copy the artifacts.
declare -a zk_build_jobs
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip="${servers[$i]}"
    ssh "${SERVER_USERNAME}@${server_ip}" 'set -e
if [ -f /usr/local/lib/libzookeeper.a ] && [ -f /usr/local/include/zookeeper/zookeeper.h ]; then
  echo "zookeeper already installed, skipping"
  exit 0
fi
ZK_C=/home/ubuntu/code/JetPack/third_party/zookeeper/zookeeper-client/zookeeper-client-c
cmake -B /tmp/zk-build -S "$ZK_C" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DWANT_SYNCAPI=ON \
    -DWANT_CPPUNIT=OFF \
    -DWITH_OPENSSL=ON \
    -DWITH_CYRUS_SASL=OFF
cmake --build /tmp/zk-build -- -j$(nproc)
sudo install -d /usr/local/lib /usr/local/include/zookeeper
sudo install -m 644 /tmp/zk-build/libzookeeper.a /tmp/zk-build/libhashtable.a /usr/local/lib/
sudo install -m 644 "$ZK_C"/include/*.h /usr/local/include/zookeeper/
sudo install -m 644 /tmp/zk-build/include/config.h /usr/local/include/zookeeper/
JUTE=$ZK_C/generated/zookeeper.jute.h
[ -f "$JUTE" ] && sudo install -m 644 "$JUTE" /usr/local/include/zookeeper/
sudo ldconfig
' &
    zk_build_jobs+=($!)
done
for job in "${zk_build_jobs[@]}"; do wait $job; done
echo "zookeeper build complete."

