#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    N_SERVER=$(jq -r '.n_server' setup.json)
    experiment_env=$(jq -r '.environment' setup.json)
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

# Define all server hosts by reading from setup.json
declare -a HOSTS
declare -a HOSTNAMES

# Populate the HOSTS and HOSTNAMES arrays dynamically from setup.json
for i in $(seq 0 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)
    HOSTS+=("$server_ip")
    HOSTNAMES+=("server-$i")
done

# Create a temporary directory for storing results
tmp_dir=$(mktemp -d -t latency-XXXXXX)

# Ping each server from the local machine and store the average latency in a temp file
echo "Measuring latency from local to each server..."
declare -a jobs_local

for i in "${!HOSTS[@]}"; do
    (
        host_ip=${HOSTS[$i]}
        host_name=${HOSTNAMES[$i]}
        latency_local=$(ping -c 4 "${host_ip}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        if [ -n "$latency_local" ]; then
            echo "Latency from local to ${host_name} (${host_ip}): ${latency_local} ms"
            echo "${latency_local} ms" > "$tmp_dir/local_latency_${i}.txt"
        else
            echo "Failed to measure latency from local to ${host_name} (${host_ip})."
            echo "N/A" > "$tmp_dir/local_latency_${i}.txt"
        fi
    ) &
    jobs_local+=($!)
done

# Wait for all local ping jobs to complete
for job in "${jobs_local[@]}"; do
    wait $job
done

echo "All local latency measurements completed."

# Measure inter-server latency and store the results in unique temp files
echo "Measuring inter-server latency..."
declare -a jobs_remote

# Limit concurrency for SSH operations (adjust to avoid overloading the system)
CONCURRENCY_LIMIT=5

for i in "${!HOSTS[@]}"; do
    (
        src_host=${HOSTS[$i]}
        src_host_name=${HOSTNAMES[$i]}
        tmp_file="$tmp_dir/inter_latency_${i}_header.json"
        echo "{\"from\": \"$src_host_name\", \"latencies\": {" > "$tmp_file"

        for j in "${!HOSTS[@]}"; do
            dst_host=${HOSTS[$j]}
            dst_host_name=${HOSTNAMES[$j]}
            latency=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "ubuntu@${src_host}" "ping -c 4 ${dst_host}" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
            if [ -n "$latency" ]; then
                echo "Latency from ${src_host_name} to ${dst_host_name}: ${latency} ms"
                echo "\"$dst_host_name\": \"$latency ms\"" > "$tmp_dir/inter_latency_${i}_to_${j}.txt"
            else
                echo "Failed to measure latency from ${src_host_name} to ${dst_host_name}."
                echo "\"$dst_host_name\": \"N/A\"" > "$tmp_dir/inter_latency_${i}_to_${j}.txt"
            fi
        done
    ) &
    jobs_remote+=($!)

    # Limit concurrent SSH jobs to avoid overloading the system
    if (( ${#jobs_remote[@]} >= CONCURRENCY_LIMIT )); then
        wait "${jobs_remote[@]}"
        jobs_remote=()
    fi
done

# Wait for all remote ping jobs to complete
for job in "${jobs_remote[@]}"; do
    wait $job
done

echo "All inter-server latency measurements completed."

# Create the final JSON file and add the number of servers
mkdir -p latency_results
timestamp=$(date +"%Y%m%d_%H%M%S")  # Format: YYYYMMDD_HHMMSS
output_file="latency_results/latency_results_${timestamp}.json"
echo "{\"n_server\": $N_SERVER, \"local_latencies\": [" > $output_file

# Read and append local latency results from temp files
for i in $(seq 0 $((N_SERVER - 1))); do
    latency=$(cat "$tmp_dir/local_latency_${i}.txt")
    echo "{\"server\": \"${HOSTNAMES[$i]}\", \"ip\": \"${HOSTS[$i]}\", \"latency\": \"$latency\"}" >> $output_file
    # Add a comma unless it's the last iteration
    if [ $i -lt $((N_SERVER - 1)) ]; then
        echo "," >> $output_file
    fi
done

echo "], \"inter_server_latencies\": [" >> $output_file

# Read and append inter-server latency results from unique temp files
for i in $(seq 0 $((N_SERVER - 1))); do
    # Append the header
    cat "$tmp_dir/inter_latency_${i}_header.json" >> $output_file
    # Append latencies for this source server
    for j in $(seq 0 $((N_SERVER - 1))); do
        cat "$tmp_dir/inter_latency_${i}_to_${j}.txt" >> $output_file
        if [ $j -lt $((N_SERVER - 1)) ]; then
            echo "," >> $output_file
        fi
    done
    # Close the latencies object
    echo "}}" >> $output_file

    # Add a comma unless it's the last iteration
    if [ $i -lt $((N_SERVER - 1)) ]; then
        echo "," >> $output_file
    fi
done

# Close the JSON file
echo "]}" >> $output_file

# Clean up temporary files and directory
rm -rf "$tmp_dir"

echo "All results stored and saved to $output_file."

