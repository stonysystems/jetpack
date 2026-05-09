#!/usr/bin/env bash
# Launch 1x c5.2xlarge per region for the Janus cross-region cluster.
# Settings: see scripts/aws_ec2_setup.md.
# Idempotent on key pair and security group; will launch a NEW instance every run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUB_KEY_FILE="$REPO_ROOT/config/ssh/id_rsa.pub"

KEY_NAME="zoo-key"
SG_NAME="jp-cluster"
SG_DESC="Janus cluster cross-region traffic"
INSTANCE_TYPE="c5.2xlarge"
UBUNTU_OWNER="099720109477"
UBUNTU_AMI_FILTER="ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"

# index city region_code
REGIONS=(
  "00 california us-west-1"
  "01 oregon us-west-2"
  "02 mumbai ap-south-1"
  "03 frankfurt eu-central-1"
  "04 stockholm eu-north-1"
  "05 london eu-west-2"
  "06 hongkong ap-east-1"
  "07 singapore ap-southeast-1"
  "08 ireland eu-west-1"
  "09 paris eu-west-3"
)

declare -a SUMMARY

create_in_region() {
  local idx="$1" city="$2" region="$3"
  local vol_size=16
  [[ "$idx" == "00" ]] && vol_size=128

  echo "=== $idx $city ($region) ==="

  local ami
  ami=$(aws ec2 describe-images --region "$region" \
    --owners "$UBUNTU_OWNER" \
    --filters "Name=name,Values=$UBUNTU_AMI_FILTER" "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
  if [[ -z "$ami" || "$ami" == "None" ]]; then
    echo "  ERROR: AMI lookup failed"
    SUMMARY+=("$idx $city $region FAILED-ami")
    return 1
  fi
  echo "  AMI:     $ami"

  if aws ec2 describe-key-pairs --region "$region" --key-names "$KEY_NAME" >/dev/null 2>&1; then
    echo "  Key:     $KEY_NAME (exists)"
  else
    aws ec2 import-key-pair --region "$region" \
      --key-name "$KEY_NAME" \
      --public-key-material "fileb://$PUB_KEY_FILE" >/dev/null
    echo "  Key:     $KEY_NAME (imported)"
  fi

  local sg_id
  sg_id=$(aws ec2 describe-security-groups --region "$region" \
    --filters "Name=group-name,Values=$SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 create-security-group --region "$region" \
      --group-name "$SG_NAME" --description "$SG_DESC" \
      --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$region" \
      --group-id "$sg_id" \
      --ip-permissions \
        "IpProtocol=tcp,FromPort=100,ToPort=50000,IpRanges=[{CidrIp=0.0.0.0/0}]" \
        "IpProtocol=udp,FromPort=100,ToPort=50000,IpRanges=[{CidrIp=0.0.0.0/0}]" \
        "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=0.0.0.0/0}]" \
        "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0}]" \
      >/dev/null
    echo "  SG:      $sg_id (created)"
  else
    echo "  SG:      $sg_id (exists)"
  fi

  local subnet_id
  subnet_id=$(aws ec2 describe-subnets --region "$region" \
    --filters "Name=default-for-az,Values=true" \
    --query 'Subnets[0].SubnetId' --output text)
  if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
    echo "  ERROR: no default subnet in $region"
    SUMMARY+=("$idx $city $region FAILED-subnet")
    return 1
  fi
  echo "  Subnet:  $subnet_id"

  local instance_id
  instance_id=$(aws ec2 run-instances --region "$region" \
    --image-id "$ami" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$sg_id" \
    --subnet-id "$subnet_id" \
    --associate-public-ip-address \
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$vol_size,VolumeType=gp2,DeleteOnTermination=true}" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=jp-$idx-$city}]" \
    --query 'Instances[0].InstanceId' --output text 2>&1)
  if [[ -z "$instance_id" || "$instance_id" != i-* ]]; then
    echo "  ERROR: run-instances failed: $instance_id"
    SUMMARY+=("$idx $city $region FAILED-launch")
    return 1
  fi
  echo "  Instance: $instance_id"

  aws ec2 wait instance-running --region "$region" --instance-ids "$instance_id"

  local alloc_id eip
  alloc_id=$(aws ec2 allocate-address --region "$region" \
    --domain vpc \
    --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=jp-$idx-$city}]" \
    --query 'AllocationId' --output text)
  aws ec2 associate-address --region "$region" \
    --instance-id "$instance_id" \
    --allocation-id "$alloc_id" >/dev/null
  eip=$(aws ec2 describe-addresses --region "$region" \
    --allocation-ids "$alloc_id" \
    --query 'Addresses[0].PublicIp' --output text)
  echo "  EIP:     $eip"

  if [[ "${STOP_AFTER_LAUNCH:-0}" == "1" ]]; then
    aws ec2 stop-instances --region "$region" --instance-ids "$instance_id" >/dev/null
    echo "  Stopped: $instance_id (stopping)"
    SUMMARY+=("$idx $city $region $instance_id $eip stopped")
  else
    SUMMARY+=("$idx $city $region $instance_id $eip running")
  fi
}

# Optional: SKIP_INDICES="00 01" to skip regions by index (space-separated).
SKIP_INDICES="${SKIP_INDICES:-}"

for entry in "${REGIONS[@]}"; do
  read -r idx city region <<< "$entry"
  if [[ " $SKIP_INDICES " == *" $idx "* ]]; then
    echo "=== $idx $city ($region) [SKIPPED] ==="
    continue
  fi
  create_in_region "$idx" "$city" "$region" || echo "  *** $idx $city failed; continuing ***"
done

echo ""
echo "=== Summary ==="
printf '%s\n' "${SUMMARY[@]}"
