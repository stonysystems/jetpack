#!/usr/bin/env bash
# Start all instances listed in scripts/aws_instances.tsv.
# Optional: ONLY_INDICES="00 03" to start a subset.
set -uo pipefail

INVENTORY="$(cd "$(dirname "$0")" && pwd)/aws_instances.tsv"
ONLY_INDICES="${ONLY_INDICES:-}"

while IFS=$'\t' read -r idx city region instance_id eip; do
  [[ -z "$idx" || "$idx" == \#* ]] && continue
  if [[ -n "$ONLY_INDICES" && " $ONLY_INDICES " != *" $idx "* ]]; then
    continue
  fi
  printf "%s %-12s %-16s %s ... " "$idx" "$city" "$region" "$instance_id"
  state=$(aws ec2 start-instances --region "$region" --instance-ids "$instance_id" \
    --query 'StartingInstances[0].CurrentState.Name' --output text 2>&1) \
    && echo "$state" \
    || echo "ERROR: $state"
done < "$INVENTORY"
