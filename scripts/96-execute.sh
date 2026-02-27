#!/bin/bash

# Check if the command was passed as an argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 '<command>'"
    exit 1
fi

# The command to execute is the first argument
command_to_execute="$1"

# Define the range of server IP addresses and their corresponding names
declare -a servers
declare -a replicanames
for i in $(seq 0 9); do
    ip_var="AWS_${i}_IP"
    name_var="aws${i}"
    servers+=("${!ip_var}")
    replicanames+=($name_var)
done

# Declare arrays to track background job information
declare -a jobs
declare -a job_names

# Loop through the array of servers
for i in "${!servers[@]}"; do
    server_ip="${servers[$i]}"
    replica_name="${replicanames[$i]}"
    echo "Executing command on server: $replica_name"

    # Run the command on the remote server in the background
    ssh ubuntu@"$server_ip" "$command_to_execute" &> /dev/null &

    # Save the PID of the background process
    jobs+=($!)
    job_names+=("$replica_name")
done

# Wait for all background jobs to complete and check their exit status
for j in "${!jobs[@]}"; do
    job=${jobs[$j]}
    replica_name=${job_names[$j]}

    wait $job
    exit_status=$?

    if [ $exit_status -eq 0 ]; then
        echo "Successfully executed command on $replica_name"
    else
        echo "Failed to execute command on $replica_name"
    fi
done

echo "Operation completed on all servers."

