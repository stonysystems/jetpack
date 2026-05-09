#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    experiment_env=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Please ensure it exists and is properly configured. Exiting."
    exit 1
fi

# Set SERVER_USERNAME to "ubuntu" for both AWS and Zoo environments
SERVER_USERNAME="ubuntu"

# Define an array of server IP addresses dynamically from setup.json
declare -a servers

# Populate the servers array from the servers array in setup.json
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists in the JSON file
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        servers+=("${server_ip}")
    else
        echo "Error: SERVER_${i}_IP is not set or is empty in setup.json."
        exit 1
    fi
done

# The directory to be added to the linker's search paths
library_path="/usr/local/lib"
config_file="usr_local_lib.conf"

# Declare an array to track background job IDs
declare -a jobs

# Command block to configure each server in parallel
for i in "${!servers[@]}"; do
    server_ip="${servers[$i]}"
    echo "Configuring ${server_ip}..."

    # Run commands remotely to configure the library path in a background subshell
    (
        ssh "${SERVER_USERNAME}@${server_ip}" bash << EOF
            # Check if the library exists
            if [ -f "$library_path/libmongocxx.so._noabi" ]; then
                echo "Library exists. Configuring..."

                # Create or append the linker config if it does not already contain the path
                if ! grep -q "$library_path" /etc/ld.so.conf.d/$config_file; then
                    echo "$library_path" | sudo tee /etc/ld.so.conf.d/$config_file > /dev/null
                else
                    echo "Path already configured."
                fi

                # Update the linker cache
                sudo ldconfig

                echo "Configuration complete on ${server_ip}"
            else
                echo "Library not found on ${server_ip}"
            fi
EOF
    ) &
    jobs+=($!) # Store the job ID
done

# Wait for all background jobs to complete
for job in "${jobs[@]}"; do
    wait $job
done

echo "All configurations completed."

