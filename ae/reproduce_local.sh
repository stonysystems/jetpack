#!/usr/bin/env bash
# ae/reproduce_local.sh
#
# One-click local AE reproduction. Delegates to ae/local/run.sh.
# Default: full reproduction (build + exp0 + exp1 + exp2 + recovery
# + tla_small). Wall-clock 15-22h on 16 cores / 32 GB.
#
# Usage:
#   ./ae/reproduce_local.sh                # full reproduction
#   ./ae/reproduce_local.sh --quick        # 30-min smoke (kick the tires)
#   ./ae/reproduce_local.sh --phase exp0   # selective phase
#   ./ae/reproduce_local.sh --dry-run
#   ./ae/reproduce_local.sh --help

set -euo pipefail
cd "$(dirname "$0")"
exec ./local/run.sh "$@"
