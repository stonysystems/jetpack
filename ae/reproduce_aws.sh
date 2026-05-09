#!/usr/bin/env bash
# ae/reproduce_aws.sh
#
# One-click AWS gold-standard reproduction. Delegates to ae/aws/run.sh.
# Reproduces the camera-ready paper figures with exact AWS WAN numbers.
# Wall-clock ~28 h on 10 × c5.2xlarge across 5 AWS regions.
#
# Prerequisites (see ae/aws/camera-ready/settings.md §1):
#   - 10 EC2 instances provisioned per ae/aws/scripts/aws_create_instances.sh
#   - SSH trust bootstrapped (00-ips.sh through 07-link_mongocxx.sh)
#   - setup.json points at the AWS topology
#
# Usage:
#   ./ae/reproduce_aws.sh                  # full matrix (~28 h)
#   ./ae/reproduce_aws.sh --exp 0          # exp 0 only (~15 h)
#   ./ae/reproduce_aws.sh --dry-run

set -euo pipefail
cd "$(dirname "$0")"
exec ./aws/run.sh "$@"
