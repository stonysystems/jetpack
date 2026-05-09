#!/bin/bash

# Check if setup.json exists and read values from it
if [ -f "setup.json" ]; then
    environment=$(jq -r '.environment' setup.json)
    N_SERVER=$(jq -r '.n_server' setup.json)
else
    echo "setup.json not found. Try to run \`source 00-ips.sh\`. Exiting."
    exit 1
fi

# If the environment is 'zoo', skip the NFS setup
if [ "$environment" == "zoo" ]; then
    echo "Zoo servers NFS already setup, do not need extra setup."
    exit 0
fi

# If the environment is 'aws', proceed with NFS setup
echo "Proceeding with AWS NFS setup..."

# Read SERVER_0_IP (the NFS host) from setup.json
host_ip=$(jq -r '.servers[0].server_0_ip' setup.json)

# Populate client IPs dynamically from setup.json for i from 1 to N_SERVER-1
client_ips=()
for i in $(seq 1 $((N_SERVER - 1))); do
    server_ip=$(jq -r ".servers[$i].server_${i}_ip" setup.json)

    # Check if the server IP exists
    if [ "$server_ip" != "null" ] && [ -n "$server_ip" ]; then
        client_ips+=("${server_ip}")
    else
        echo "Error: IP for server $i is not set or empty in setup.json."
        exit 1
    fi
done

# Create script for NFS host
etc_export=""
for ip in "${client_ips[@]}"; do
    etc_export+="/home/ubuntu/code ${ip}(rw,sync,no_root_squash,no_subtree_check)\n"
done

echo "Creating AWS NFS host script..."
cat << EOF > aws_nfs_host_script.sh
#!/bin/bash
mkdir -p /home/ubuntu/code
sudo chown ubuntu:ubuntu /home/ubuntu/code
sudo bash -c "echo -e '${etc_export}' | tee /etc/exports > /dev/null"
sudo systemctl restart nfs-kernel-server
EOF

# Create script for NFS clients
echo "Creating AWS NFS client script..."
echo "mkdir -p /home/ubuntu/code" > aws_nfs_client_script.sh
echo "sudo mount ${host_ip}:/home/ubuntu/code /home/ubuntu/code" >> aws_nfs_client_script.sh

# Copy and execute the host script
echo "Configuring the NFS host at $host_ip..."
scp aws_nfs_host_script.sh ubuntu@"$host_ip":~
ssh ubuntu@"$host_ip" "bash ~/aws_nfs_host_script.sh"

echo "Done configuring the NFS host."

# Declare an array to track background job IDs for client setups
declare -a jobs

# Loop through each client IP in parallel
for client_ip in "${client_ips[@]}"; do
    (
        # Copy and execute the client script
        echo "Configuring NFS client at $client_ip..."
        scp aws_nfs_client_script.sh ubuntu@"$client_ip":~
        ssh ubuntu@"$client_ip" "bash ~/aws_nfs_client_script.sh"
        echo "Done for client at $client_ip"
    ) &
    jobs+=($!) # Store the job ID
done

# Wait for all background jobs to complete
for job in "${jobs[@]}"; do
    wait $job
done

echo "All NFS client configurations completed."

# Cleanup local script files
rm aws_nfs_host_script.sh
echo "Removed aws_nfs_host_script.sh"
rm aws_nfs_client_script.sh
echo "Removed aws_nfs_client_script.sh"

echo "AWS NFS setup completed."

