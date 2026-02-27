#!/bin/bash

# Function to handle zoo username and directory
handle_zoo_details() {
  # Check if setup.json exists and has zoo details
  if [ -f "setup.json" ]; then
    zoo_username=$(jq -r '.zoo_username' setup.json)
    zoo_directory=$(jq -r '.zoo_directory' setup.json)

    # If zoo_username and zoo_directory exist in setup.json, use them
    if [ "$zoo_username" != "null" ] && [ -n "$zoo_username" ]; then
      echo "Using zoo username from setup.json: $zoo_username"
    else
      # Ask for the zoo username if not found
      echo "Please enter your zoo username:"
      read -r zoo_username
    fi

    if [ "$zoo_directory" != "null" ] && [ -n "$zoo_directory" ]; then
      echo "Using zoo directory from setup.json: $zoo_directory"
    else
      # Ask for the zoo directory if not found
      echo "Please enter the directory for the experiment on Zoo (e.g., /home/users/ztang/janus):"
      read -r zoo_directory
    fi
  else
    # Ask for the zoo username and directory if setup.json doesn't exist
    echo "Please enter your zoo username:"
    read -r zoo_username
    echo "Please enter the directory for the experiment on Zoo (e.g., /home/users/ztang/janus):"
    read -r zoo_directory
  fi

  # Set zoo username and directory for later use
  SERVER_USERNAME="$zoo_username"
  ZOO_DIRECTORY="$zoo_directory"
  echo "Using SERVER_USERNAME=\"$zoo_username\""
  echo "Using ZOO_DIRECTORY=\"$zoo_directory\""
}

# Function to handle aws_key_distributed for both AWS and Zoo
handle_aws_key_distributed() {
  if [ -f "setup.json" ]; then
    # Try to read aws_key_distributed from setup.json
    aws_key_distributed=$(jq -r '.aws_key_distributed' setup.json 2>/dev/null)

    # If aws_key_distributed does not exist or is null, set it to "false"
    if [ "$aws_key_distributed" == "null" ] || [ -z "$aws_key_distributed" ]; then
      aws_key_distributed="false"
    fi
  else
    # Default value if setup.json does not exist
    aws_key_distributed="false"
  fi

  echo "aws_key_distributed is set to: $aws_key_distributed"
}

# Prompt the user to choose between aws or zoo
echo "Which environment would you like to use? (Enter 'aws' for aws_ips.json or 'zoo' for zoo_ips.json)"
read -r choice

# Set the json_file and handle based on user input
if [ "$choice" = "aws" ]; then
  json_file="aws_ips.json"
  echo "You have chosen aws_ips.json."
  SERVER_USERNAME="ubuntu"
  echo "Using SERVER_USERNAME=\"ubuntu\""

elif [ "$choice" = "zoo" ]; then
  json_file="zoo_ips.json"
  echo "You have chosen zoo_ips.json."
  handle_zoo_details  # Handle zoo username and directory
else
  echo "Invalid choice. Please enter either 'aws' or 'zoo'. Exiting."
  exit 1
fi

# Handle aws_key_distributed for both AWS and Zoo
handle_aws_key_distributed

# Extract n_server from the chosen JSON and set it as a variable
n_server=$(jq '.n_server' "$json_file")
echo "Using N_SERVER=\"$n_server\""

# Initialize servers and keys variables (space-separated values)
servers=""
server_data=""
keys=""

# Loop over each server and gather the IPs and keys for AWS
for ((i=0; i<n_server; i++)); do
  server_ip=$(jq -r ".servers[\"server_${i}_ip\"]" "$json_file")
  if [ "$server_ip" != "nil" ] && [ -n "$server_ip" ]; then
    echo "Using SERVER_${i}_IP=\"$server_ip\""

    # Extract the key for AWS servers
    if [ "$choice" = "aws" ]; then
      server_key=$(jq -r ".servers[\"server_${i}_key\"]" "$json_file")
      if [ "$server_key" != "nil" ] && [ -n "$server_key" ]; then
        echo "Using SERVER_${i}_KEY=\"$server_key\""
      else
        echo "Skipping server_${i}_key because it is \"nil\" or empty"
      fi
    fi

    # Build space-separated servers and keys list
    servers="$servers $server_ip"
    server_data="$server_data{\"server_${i}_ip\": \"$server_ip\", \"server_${i}_key\": \"$server_key\"},"
    keys="$keys $server_key"
  else
    echo "Skipping server_${i}_ip because it is \"nil\" or empty"
  fi
done

# Trim trailing comma from server_data for JSON format
server_data="${server_data%,}"

# Create (or overwrite) setup.json file with environment data for other scripts
cat > setup.json <<EOL
{
  "environment": "$choice",
  "server_username": "$SERVER_USERNAME",
  "n_server": "$n_server",
  "servers": [$server_data],
  "zoo_username": "${zoo_username:-null}",
  "zoo_directory": "${zoo_directory:-null}",
  "aws_key_distributed": $aws_key_distributed
}
EOL

# Pretty-print (each array item on its own line)
tmp="$(mktemp)"
jq '.' setup.json > "$tmp" && mv "$tmp" setup.json

echo "Setup information saved to setup.json (overwritten if it already existed)."

