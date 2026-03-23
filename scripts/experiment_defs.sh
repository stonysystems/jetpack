#!/bin/bash
# experiment_defs.sh — Centralized experiment definitions for JetPack.
#
# Source this file from entry scripts to access protocol/backend families,
# mode mappings, concurrency arrays, and command-generation helpers.
#
# Covers both legacy protocol families (Raft, CoPilot, Mencius, MongoDB)
# and current Docker-based backends (etcd, MongoDB, ZooKeeper).
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/experiment_defs.sh"
#
# Backward compatibility:
#   - All entry scripts (08, 09, 10, 11) accept the same CLI arguments as
#     before this module was introduced. No CLI contract has changed.
#   - Result naming conventions are unchanged: the result prefix format
#     <protocol>-<site>-<workload>-<concurrent>-<mode>-<ycsb> matches the
#     prior inline convention in 10-run_all.sh. Historical results under
#     scripts/results/ and failure-recovery data folders remain readable.
#   - Result parsers (results_reader.py, build_consolidated_csv.sh, tsv_to_md.sh,
#     calc_latency.py) parse output file content, not experiment definitions,
#     and are unaffected by this module.
#   - setup.json, aws_ips.json, and zoo_ips.json schemas are unchanged.
#   - MongoDB automation:
#       Legacy path: rule_mongodb / none_mongodb (AWS/Zoo via 09/10 scripts)
#       Current path: jetpack-mongodb Docker image (Docker sweep via sweep_benchmark.sh)
#       95-restart_mongodb.sh: standalone MongoDB service restart (AWS-only)
#     Both paths coexist; the legacy path is the canonical one for remote
#     cluster runs, the current path is canonical for local Docker benchmarks.

# ──────────────────────────────────────────────────────────────────────
# Protocol / backend families
# ──────────────────────────────────────────────────────────────────────

# Legacy protocol families (AWS/Zoo cluster workflow)
LEGACY_JETPACK_PROTOCOLS=("rule_fpga_raft" "rule_copilot" "rule_mencius" "rule_mongodb")
LEGACY_ORIGIN_PROTOCOLS=("none_raft" "none_copilot" "none_mencius" "none_mongodb")

# Current Docker-based backend families
CURRENT_BACKENDS=("etcd" "mongodb" "zookeeper")
CURRENT_JETPACK_PROTOCOLS=("rule_etcd" "rule_mongodb" "rule_zookeeper")
CURRENT_ORIGIN_PROTOCOLS=("none_etcd" "none_mongodb" "none_zookeeper")

# Zoo 5-machine protocol families — all 6 requested protocols.
# Uses rule_raft (not rule_fpga_raft) per explicit requirement.
ZOO_JETPACK_PROTOCOLS=("rule_raft" "rule_copilot" "rule_mencius" "rule_mongodb" "rule_etcd" "rule_zookeeper")
ZOO_ORIGIN_PROTOCOLS=("none_raft" "none_copilot" "none_mencius" "none_mongodb" "none_etcd" "none_zookeeper")

# Docker image names (indexed same as CURRENT_BACKENDS)
CURRENT_DOCKER_IMAGES=("jetpack-etcd" "jetpack-mongodb" "jetpack-zookeeper")

# ──────────────────────────────────────────────────────────────────────
# Mode definitions
# ──────────────────────────────────────────────────────────────────────

# Canonical fastpath mode values for deptran_server -m flag
MODE_ORIGINAL="0"       # Original protocol, no Jetpack fast-path
MODE_FASTPATH100="100"  # Force 100% fast-path attempts
MODE_ADAPTIVE="101"     # Adaptive fast-path throttle (sentinel value)

ALL_FASTPATH_MODES=("$MODE_ORIGINAL" "$MODE_FASTPATH100" "$MODE_ADAPTIVE")

# Map from human-readable mode name to -m flag value
mode_flag_for() {
    local mode_name="$1"
    case "$mode_name" in
        none|original)     echo "$MODE_ORIGINAL" ;;
        rule100|fp100)     echo "$MODE_FASTPATH100" ;;
        rule101|adaptive)  echo "$MODE_ADAPTIVE" ;;
        *)                 echo "$mode_name" ;;  # pass through numeric values
    esac
}

# Map from human-readable mode name to config file
# Usage: mode_config_for "adaptive" "etcd"  →  "rule_etcd.yml"
#        mode_config_for "original" "copilot" → "none_copilot.yml"
mode_config_for() {
    local mode_name="$1"
    local backend="$2"
    case "$mode_name" in
        none|original)                echo "none_${backend}.yml" ;;
        rule100|fp100|rule101|adaptive) echo "rule_${backend}.yml" ;;
        *)                            echo "${mode_name}.yml" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Concurrency arrays (legacy, protocol-specific)
# ──────────────────────────────────────────────────────────────────────

RAFT_CONCS=(
    concurrent_1 concurrent_10 concurrent_20 concurrent_40 concurrent_60
    concurrent_80 concurrent_100 concurrent_120 concurrent_140 concurrent_150
    concurrent_160 concurrent_170 concurrent_180 concurrent_190 concurrent_200
    concurrent_250 concurrent_300 concurrent_400 concurrent_500 concurrent_750
    concurrent_1000
)
COPILOT_CONCS=(
    concurrent_1 concurrent_10 concurrent_20 concurrent_30 concurrent_40
    concurrent_50 concurrent_60 concurrent_70 concurrent_72 concurrent_75
    concurrent_77 concurrent_80 concurrent_82 concurrent_85 concurrent_87
    concurrent_90 concurrent_100 concurrent_120 concurrent_140 concurrent_160
    concurrent_180 concurrent_200
)
MENCIUS_CONCS=(
    concurrent_1 concurrent_10 concurrent_12 concurrent_14 concurrent_16
    concurrent_18 concurrent_20 concurrent_25 concurrent_30 concurrent_35
    concurrent_40 concurrent_45 concurrent_50 concurrent_55 concurrent_60
)
MONGODB_CONCS=(
    concurrent_1 concurrent_10 concurrent_20 concurrent_30 concurrent_35
    concurrent_40 concurrent_50 concurrent_60 concurrent_70 concurrent_80
    concurrent_90 concurrent_100 concurrent_110 concurrent_120
)

# Current Docker sweep concurrency levels
DOCKER_SWEEP_CONCS=(
    concurrent_1 concurrent_5 concurrent_10 concurrent_25 concurrent_50
    concurrent_75 concurrent_100 concurrent_150 concurrent_200 concurrent_300
    concurrent_400
)

# Zoo-specific concurrency arrays for etcd and zookeeper.
# These cover a similar range to MongoDB since the backends have comparable
# throughput characteristics on a 5-machine cluster with WAN latency.
ETCD_CONCS=(
    concurrent_1 concurrent_10 concurrent_20 concurrent_30 concurrent_40
    concurrent_50 concurrent_60 concurrent_70 concurrent_80 concurrent_90
    concurrent_100 concurrent_110 concurrent_120
)
ZOOKEEPER_CONCS=(
    concurrent_1 concurrent_10 concurrent_20 concurrent_30 concurrent_40
    concurrent_50 concurrent_60 concurrent_70 concurrent_80 concurrent_90
    concurrent_100 concurrent_110 concurrent_120
)

# Fixed concurrency for secondary experiments (indexed: raft, copilot, mencius, mongodb)
LEGACY_FIXED_CONCS=("concurrent_150" "concurrent_50" "concurrent_16" "concurrent_40")

# Look up the concurrency array for a given protocol family
# Usage: get_concs_for_protocol "raft"  → prints array name
concs_array_for() {
    local proto="$1"
    case "$proto" in
        *fpga_raft)        echo "RAFT_CONCS" ;;
        *raft)             echo "RAFT_CONCS" ;;
        *copilot)          echo "COPILOT_CONCS" ;;
        *mencius)          echo "MENCIUS_CONCS" ;;
        *mongodb)          echo "MONGODB_CONCS" ;;
        *etcd)             echo "ETCD_CONCS" ;;
        *zookeeper)        echo "ZOOKEEPER_CONCS" ;;
        *)                 echo "DOCKER_SWEEP_CONCS" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────
# Standard site configs
# ──────────────────────────────────────────────────────────────────────

SITE_AWS_SWEEP="60c1s5r10p"       # AWS 10-node layout
SITE_DOCKER_SWEEP="60c1s5r5p"     # Docker single-host 5-process
SITE_LOCAL_SANITY="3c1s3r1p"      # Single-process local sanity check
SITE_LOCAL_MULTI="5c1s5r5p"       # Docker 5-process low-client
SITE_ZOO_SWEEP="30c1s5r5p-zoo"   # Zoo 5-machine cluster

# ──────────────────────────────────────────────────────────────────────
# Docker backend failure-recovery definitions
# ──────────────────────────────────────────────────────────────────────

# Failover config files per backend (used with -f config/<file>)
declare -A FAILOVER_CONFIGS=(
    [etcd]="failover_etcd.yml"
    [mongodb]="failover_mongodb.yml"
    [zookeeper]="failover_zookeeper.yml"
)

# Docker compose files per backend (relative to repo root)
declare -A DOCKER_COMPOSE_FILES=(
    [etcd]="docker/etcd/docker-compose.yml"
    [mongodb]="docker/mongodb/docker-compose.yml"
    [zookeeper]="docker/zookeeper/docker-compose.yml"
)

# Docker test scripts per backend (relative to repo root)
declare -A DOCKER_TEST_SCRIPTS=(
    [etcd]="docker/etcd/run-etcd-test.sh"
    [mongodb]="docker/mongodb/run-mongodb-test.sh"
    [zookeeper]="docker/zookeeper/run-zookeeper-test.sh"
)

# Docker test modes available per backend
# All 3 backends support: single, multi, benchmark, recovery
DOCKER_TEST_MODES=("single" "multi" "benchmark" "recovery")

# AWS-only restart helper scripts (only MongoDB has one)
declare -A AWS_RESTART_SCRIPTS=(
    [mongodb]="scripts/95-restart_mongodb.sh"
)

# ──────────────────────────────────────────────────────────────────────
# Command generation helpers
# ──────────────────────────────────────────────────────────────────────

# Derive the client config file from a protocol name.
# Convention: if protocol has an underscore suffix, use client_open_<suffix>.yml
# if that file exists under config/; otherwise use client_open.yml.
derive_client_config() {
    local protocol="$1"
    local config_dir="${2:-config}"
    if [[ "$protocol" == *_* ]]; then
        local suffix="${protocol#*_}"
        local candidate="client_open_${suffix}.yml"
        if [[ -f "${config_dir}/${candidate}" ]]; then
            echo "$candidate"
            return
        fi
    fi
    echo "client_open.yml"
}

# Build a deptran_server command string from experiment parameters.
#
# Required env/args:
#   $1 = repo_dir       (remote repo path)
#   $2 = protocol       (e.g. "rule_copilot", "none_etcd")
#   $3 = site           (e.g. "60c1s5r10p")
#   $4 = workload       (e.g. "rw_1000000")
#   $5 = concurrent     (e.g. "concurrent_100")
#   $6 = fastpath_mode  (e.g. "0", "100", "101")
#   $7 = duration       (seconds, e.g. "30")
#   $8 = ycsb           (e.g. "YCSB_A", or "" to omit)
#   $9 = failover       ("true" to add failover.yml, anything else to omit)
#
# Prints the full command string to stdout.
build_deptran_cmd() {
    local repo_dir="$1"
    local protocol="$2"
    local site="$3"
    local workload="$4"
    local concurrent="$5"
    local fastpath_mode="$6"
    local duration="$7"
    local ycsb="$8"
    local failover="$9"

    local client_config
    client_config=$(derive_client_config "$protocol" "${repo_dir}/config")

    local cmd="cd ${repo_dir} && build/deptran_server"
    cmd+=" -f config/${protocol}.yml"
    cmd+=" -f config/${client_config}"
    cmd+=" -f config/${site}.yml"
    cmd+=" -f config/${workload}.yml"
    cmd+=" -f config/${concurrent}.yml"
    if [[ -n "$ycsb" ]]; then
        cmd+=" -f config/${ycsb}.yml"
    fi
    if [[ "$failover" == "true" ]]; then
        cmd+=" -f config/failover.yml"
    fi
    cmd+=" -m ${fastpath_mode}"
    cmd+=" -d ${duration}"

    echo "$cmd"
}

# Build a result name prefix from experiment parameters.
# Format: <protocol>-<site>-<workload>-<concurrent>-<mode>-<ycsb>
build_result_prefix() {
    local protocol="$1"
    local site="$2"
    local workload="$3"
    local concurrent="$4"
    local fastpath_mode="$5"
    local ycsb="${6:-YCSB_A}"

    echo "${protocol}-${site}-${workload}-${concurrent}-${fastpath_mode}-${ycsb}"
}

# ──────────────────────────────────────────────────────────────────────
# Experiment matrix generation
# ──────────────────────────────────────────────────────────────────────

# Generate a full experiment matrix for the legacy AWS/Zoo workflow.
# Populates the global array GENERATED_CONFIGS with comma-separated tuples:
#   site,protocol,workload,concurrent,fastpath_mode,ycsb
#
# Arguments:
#   $1 = experiment type: "concurrency_sweep" | "zipf_sweep" | "keyrange_sweep"
#   $2 = site config name (e.g. "60c1s5r10p")
generate_legacy_matrix() {
    local exp_type="$1"
    local site="$2"
    GENERATED_CONFIGS=()

    case "$exp_type" in
        concurrency_sweep)
            for i in "${!LEGACY_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${LEGACY_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${LEGACY_JETPACK_PROTOCOLS[$i]}"
                local concs_name
                concs_name=$(concs_array_for "$origin")
                local -n concs_ref="$concs_name"

                # Original protocol
                for conc in "${concs_ref[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},rw_1000000,${conc},0,YCSB_A")
                done
                # Jetpack protocol with all fastpath modes
                for mode in "${ALL_FASTPATH_MODES[@]}"; do
                    for conc in "${concs_ref[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},rw_1000000,${conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
        zipf_sweep)
            local -a zipf_wl=(
                rw_zipf_1 rw_zipf_0.95 rw_zipf_0.9 rw_zipf_0.85 rw_zipf_0.8
                rw_zipf_0.75 rw_zipf_0.7 rw_zipf_0.65 rw_zipf_0.6 rw_zipf_0.55
                rw_zipf_0.5
            )
            for i in "${!LEGACY_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${LEGACY_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${LEGACY_JETPACK_PROTOCOLS[$i]}"
                local fixed_conc="${LEGACY_FIXED_CONCS[$i]}"

                for wl in "${zipf_wl[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},${wl},${fixed_conc},0,YCSB_A")
                    for mode in "${ALL_FASTPATH_MODES[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},${wl},${fixed_conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
        keyrange_sweep)
            local -a kr_wl=(rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000)
            for i in "${!LEGACY_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${LEGACY_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${LEGACY_JETPACK_PROTOCOLS[$i]}"
                local fixed_conc="${LEGACY_FIXED_CONCS[$i]}"

                for wl in "${kr_wl[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},${wl},${fixed_conc},0,YCSB_A")
                    for mode in "${ALL_FASTPATH_MODES[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},${wl},${fixed_conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
    esac
}

# Generate experiment matrix for current Docker-based backends.
# Populates GENERATED_CONFIGS with comma-separated tuples:
#   backend,mode_name,docker_image,protocol_config,mode_flag,site,concurrent
#
# Arguments:
#   $1 = experiment type: "concurrency_sweep" | "single_point"
#   $2 = site config name (e.g. "60c1s5r5p")
#   $3 = (optional) specific backend to filter, e.g. "etcd"
generate_current_matrix() {
    local exp_type="$1"
    local site="$2"
    local filter_backend="${3:-}"
    GENERATED_CONFIGS=()

    for i in "${!CURRENT_BACKENDS[@]}"; do
        local backend="${CURRENT_BACKENDS[$i]}"
        if [[ -n "$filter_backend" && "$backend" != "$filter_backend" ]]; then
            continue
        fi
        local image="${CURRENT_DOCKER_IMAGES[$i]}"
        local origin="${CURRENT_ORIGIN_PROTOCOLS[$i]}"
        local jetpack="${CURRENT_JETPACK_PROTOCOLS[$i]}"

        case "$exp_type" in
            concurrency_sweep)
                # Original mode
                for conc in "${DOCKER_SWEEP_CONCS[@]}"; do
                    GENERATED_CONFIGS+=("${backend},original,${image},${origin},${MODE_ORIGINAL},${site},${conc}")
                done
                # Fast-path 100%
                for conc in "${DOCKER_SWEEP_CONCS[@]}"; do
                    GENERATED_CONFIGS+=("${backend},fp100,${image},${jetpack},${MODE_FASTPATH100},${site},${conc}")
                done
                # Adaptive
                for conc in "${DOCKER_SWEEP_CONCS[@]}"; do
                    GENERATED_CONFIGS+=("${backend},adaptive,${image},${jetpack},${MODE_ADAPTIVE},${site},${conc}")
                done
                ;;
            single_point)
                GENERATED_CONFIGS+=("${backend},original,${image},${origin},${MODE_ORIGINAL},${site},concurrent_1")
                GENERATED_CONFIGS+=("${backend},fp100,${image},${jetpack},${MODE_FASTPATH100},${site},concurrent_1")
                GENERATED_CONFIGS+=("${backend},adaptive,${image},${jetpack},${MODE_ADAPTIVE},${site},concurrent_1")
                ;;
        esac
    done
}

# Print a summary of the experiment matrix for dry-run output.
print_matrix_summary() {
    local -n configs_ref="$1"
    local count=${#configs_ref[@]}
    echo "Total experiments: ${count}"
    echo ""
    for item in "${configs_ref[@]}"; do
        echo "  $item"
    done
}

# ──────────────────────────────────────────────────────────────────────
# Zoo 5-machine experiment matrix generation
# ──────────────────────────────────────────────────────────────────────

# Zoo concurrency array names (indexed same as ZOO_*_PROTOCOLS)
ZOO_CONCS_ARRAYS=("RAFT_CONCS" "COPILOT_CONCS" "MENCIUS_CONCS" "MONGODB_CONCS" "ETCD_CONCS" "ZOOKEEPER_CONCS")

# Zoo fixed concurrencies — initially empty; populated after experiment 0.
# Format: one value per protocol family in ZOO_*_PROTOCOLS order.
# After experiment 0, save to fixed_conc.json and source back here.
ZOO_FIXED_CONCS=()

# Load Zoo fixed concurrencies from a JSON file if it exists.
# Usage: load_zoo_fixed_concs "/path/to/fixed_conc.json"
load_zoo_fixed_concs() {
    local json_file="$1"
    if [[ ! -f "$json_file" ]]; then
        echo "WARNING: $json_file not found; Zoo fixed concurrencies not loaded." >&2
        return 1
    fi
    ZOO_FIXED_CONCS=()
    for i in "${!ZOO_ORIGIN_PROTOCOLS[@]}"; do
        local proto="${ZOO_ORIGIN_PROTOCOLS[$i]#none_}"
        local val
        val=$(jq -r ".${proto} // empty" "$json_file")
        if [[ -z "$val" ]]; then
            echo "WARNING: no fixed conc for $proto in $json_file" >&2
            val="concurrent_50"
        fi
        ZOO_FIXED_CONCS+=("$val")
    done
}

# Generate experiment matrix for Zoo 5-machine cluster.
# Populates GENERATED_CONFIGS with comma-separated tuples:
#   site,protocol,workload,concurrent,fastpath_mode,ycsb
#
# Arguments:
#   $1 = experiment type: "concurrency_sweep" | "zipf_sweep" | "keyrange_sweep"
#   $2 = site config name (e.g. "30c1s5r5p-zoo")
generate_zoo_matrix() {
    local exp_type="$1"
    local site="$2"
    GENERATED_CONFIGS=()

    case "$exp_type" in
        concurrency_sweep)
            for i in "${!ZOO_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${ZOO_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${ZOO_JETPACK_PROTOCOLS[$i]}"
                local concs_name="${ZOO_CONCS_ARRAYS[$i]}"
                local -n concs_ref="$concs_name"

                # Original protocol
                for conc in "${concs_ref[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},rw_1000000,${conc},0,YCSB_A")
                done
                # Jetpack protocol with all fastpath modes
                for mode in "${ALL_FASTPATH_MODES[@]}"; do
                    for conc in "${concs_ref[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},rw_1000000,${conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
        zipf_sweep)
            if [[ ${#ZOO_FIXED_CONCS[@]} -eq 0 ]]; then
                echo "ERROR: ZOO_FIXED_CONCS not set. Run experiment 0 first." >&2
                return 1
            fi
            local -a zipf_wl=(
                rw_zipf_1 rw_zipf_0.9 rw_zipf_0.8
                rw_zipf_0.7 rw_zipf_0.6 rw_zipf_0.5
            )
            for i in "${!ZOO_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${ZOO_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${ZOO_JETPACK_PROTOCOLS[$i]}"
                local fixed_conc="${ZOO_FIXED_CONCS[$i]}"

                for wl in "${zipf_wl[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},${wl},${fixed_conc},0,YCSB_A")
                    for mode in "${ALL_FASTPATH_MODES[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},${wl},${fixed_conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
        keyrange_sweep)
            if [[ ${#ZOO_FIXED_CONCS[@]} -eq 0 ]]; then
                echo "ERROR: ZOO_FIXED_CONCS not set. Run experiment 0 first." >&2
                return 1
            fi
            local -a kr_wl=(rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000)
            for i in "${!ZOO_ORIGIN_PROTOCOLS[@]}"; do
                local origin="${ZOO_ORIGIN_PROTOCOLS[$i]}"
                local jetpack="${ZOO_JETPACK_PROTOCOLS[$i]}"
                local fixed_conc="${ZOO_FIXED_CONCS[$i]}"

                for wl in "${kr_wl[@]}"; do
                    GENERATED_CONFIGS+=("${site},${origin},${wl},${fixed_conc},0,YCSB_A")
                    for mode in "${ALL_FASTPATH_MODES[@]}"; do
                        GENERATED_CONFIGS+=("${site},${jetpack},${wl},${fixed_conc},${mode},YCSB_A")
                    done
                done
            done
            ;;
    esac
}
