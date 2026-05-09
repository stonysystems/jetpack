#!/usr/bin/env bash
# run_backend_direct_sweep.sh — drive the direct-to-backend bench sweep
# (no Janus framework involved).
#
# Two modes:
#   single   sweep all (variant, num_clients, conc) combos on the current
#            host. Use on server0/CA (leader-co-located) for a baseline
#            that is comparable to the existing Python/Go numbers.
#   multi    SSH-dispatch a 2-point sweep (conc 1 + conc 100) to all 10
#            AWS hosts in parallel, scp logs back.
#
# Output:
#   results/2026-05-07-backend-direct-comparison/
#     single_host/   logs/{client}_{mode}_nc{N}_c{conc}.{res,csv}
#     multi_host/    logs/{client}_h{idx}_c{conc}.{res,csv}
#     results.csv    aggregate of all CSV rows
#     README.md  settings.md  summary.md  (scaffolding)
#
# Env-var overrides:
#   ETCD_HOST / MONGO_HOST   leader IP (default: server0 = 50.18.6.110)
#   DURATION                 per-run seconds (default 30)
#   CONC_LIST                space-separated conc points (default per-mode)
#   NC_LIST                  num-clients values to sweep (default "1 8")
#   VARIANTS                 which client tools to run (default all)
#                            valid: libetcd-async libetcd-sync grpc python-etcd
#                                   mongo-cxx python-mongo
#
# Examples:
#   # quick smoke test:
#   DURATION=10 CONC_LIST="1 50" VARIANTS="libetcd-async grpc" \
#     ./scripts/run_backend_direct_sweep.sh single
#
#   ./scripts/run_backend_direct_sweep.sh single
#   ./scripts/run_backend_direct_sweep.sh multi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN="${SCRIPT_DIR}/build"
RES_ROOT="${ROOT}/results/2026-05-07-backend-direct-comparison"
PYBENCH="${SCRIPT_DIR}/bench_backends.py"
INSTANCES="${SCRIPT_DIR}/aws_instances.tsv"

ETCD_HOST="${ETCD_HOST:-50.18.6.110}"   # server0 / CA leader
MONGO_HOST="${MONGO_HOST:-${ETCD_HOST}}"
DURATION="${DURATION:-30}"
NC_LIST="${NC_LIST:-1 8}"
VARIANTS_DEFAULT="libetcd-async libetcd-sync grpc python-etcd mongo-cxx python-mongo"
VARIANTS="${VARIANTS:-${VARIANTS_DEFAULT}}"

mkdir -p "${RES_ROOT}/single_host/logs" "${RES_ROOT}/multi_host/logs"

# Aggregated CSV header (created on first write).
AGG_CSV="${RES_ROOT}/results.csv"
init_agg_csv() {
  if [ ! -f "${AGG_CSV}" ]; then
    echo "client,mode,num_clients,conc,duration_s,n_ops,tput_rps,p50_ms,p90_ms,p99_ms,avg_ms,host_idx,layout" \
      > "${AGG_CSV}"
  fi
}

append_row() {  # append_row <csv_line> <host_idx> <layout>
  local row="$1" host_idx="$2" layout="$3"
  echo "${row},${host_idx},${layout}" >> "${AGG_CSV}"
}

# -------- ensure binaries exist --------------------------------------------
need_build=0
for b in bench_etcd_libetcd bench_etcd_grpc bench_mongo_cxx; do
  [ -x "${BIN}/${b}" ] || need_build=1
done
if [ "${need_build}" -eq 1 ]; then
  echo "[run] binaries missing; running build_backend_benches.sh"
  "${SCRIPT_DIR}/build_backend_benches.sh"
fi

contains() { [[ " ${VARIANTS} " == *" $1 "* ]]; }

# -------- one timed run, append to results.csv -----------------------------
# Args: out_prefix variant_label cmd...
run_one() {
  local prefix="$1" label="$2"; shift 2
  local res_log="${prefix}.res" csv_log="${prefix}.csv"
  echo "[run] ${label} -> ${res_log}"
  # The bench binaries print CSV on stdout, summary on stderr.
  if "$@" 2> "${res_log}" 1> "${csv_log}"; then
    if [ -s "${csv_log}" ]; then
      append_row "$(cat "${csv_log}")" "${HOST_IDX:-0}" "${LAYOUT:-single}"
    fi
  else
    echo "[run] FAILED: ${label} (see ${res_log})" >&2
  fi
}

# ---------------------------------------------------------------------------
# Single-host sweep
# ---------------------------------------------------------------------------
sweep_single() {
  init_agg_csv
  local CONC_LIST="${CONC_LIST:-1 50 100 250 500 1000 2000 4000}"
  local LAYOUT=single HOST_IDX=0
  export LAYOUT HOST_IDX
  local OUT="${RES_ROOT}/single_host/logs"

  echo "[single] CONC_LIST=${CONC_LIST}  NC_LIST=${NC_LIST}  VARIANTS=${VARIANTS}"
  echo "[single] etcd host=${ETCD_HOST}  mongo host=${MONGO_HOST}  duration=${DURATION}s"

  for c in ${CONC_LIST}; do
    # ---- etcd variants ----
    if contains libetcd-async; then
      for nc in ${NC_LIST}; do
        # cap nc at conc — N>conc is pointless (extra clients sit idle)
        local eff=$(( nc > c ? c : nc ))
        run_one "${OUT}/libetcd_async_nc${eff}_c${c}" \
          "libetcd-async nc=${eff} c=${c}" \
          "${BIN}/bench_etcd_libetcd" \
            --host "${ETCD_HOST}" --mode async \
            --num-clients "${eff}" --conc "${c}" --duration "${DURATION}"
      done
    fi
    if contains libetcd-sync; then
      for nc in ${NC_LIST}; do
        local eff=$(( nc > c ? c : nc ))
        run_one "${OUT}/libetcd_sync_nc${eff}_c${c}" \
          "libetcd-sync nc=${eff} c=${c}" \
          "${BIN}/bench_etcd_libetcd" \
            --host "${ETCD_HOST}" --mode sync \
            --num-clients "${eff}" --conc "${c}" --duration "${DURATION}"
      done
    fi
    if contains grpc; then
      for nc in ${NC_LIST}; do
        local eff=$(( nc > c ? c : nc ))
        run_one "${OUT}/grpc_nc${eff}_c${c}" \
          "grpc nc=${eff} c=${c}" \
          "${BIN}/bench_etcd_grpc" \
            --host "${ETCD_HOST}" \
            --num-channels "${eff}" --conc "${c}" --duration "${DURATION}"
      done
    fi
    if contains python-etcd; then
      run_one "${OUT}/python_etcd_c${c}" "python-etcd c=${c}" \
        python3 "${PYBENCH}" etcd \
          --host "${ETCD_HOST}" --conc "${c}" --duration "${DURATION}"
    fi

    # ---- mongo variants ----
    if contains mongo-cxx; then
      for nc in ${NC_LIST}; do
        local eff=$(( nc > c ? c : nc ))
        run_one "${OUT}/mongo_cxx_nc${eff}_c${c}" \
          "mongo-cxx nc=${eff} c=${c}" \
          "${BIN}/bench_mongo_cxx" \
            --host "${MONGO_HOST}" \
            --num-clients "${eff}" --conc "${c}" --duration "${DURATION}"
      done
    fi
    if contains python-mongo; then
      run_one "${OUT}/python_mongo_c${c}" "python-mongo c=${c}" \
        python3 "${PYBENCH}" mongodb \
          --host "${MONGO_HOST}" --conc "${c}" --duration "${DURATION}"
    fi
  done
  echo "[single] DONE — see ${RES_ROOT}/single_host/ and ${AGG_CSV}"
}

# ---------------------------------------------------------------------------
# Multi-host sweep (SSH dispatch to 10 AWS hosts)
# Binaries are NFS-shared from server0 at /home/ubuntu/code/JetPack/scripts/build/,
# so no rsync needed — every host can invoke the same path.
# ---------------------------------------------------------------------------
sweep_multi() {
  init_agg_csv
  local CONC_LIST="${CONC_LIST:-1 100}"
  local OUT="${RES_ROOT}/multi_host/logs"
  local REMOTE_BIN="${REMOTE_BIN:-/home/ubuntu/code/JetPack/scripts/build}"
  local REMOTE_PYBENCH="${REMOTE_PYBENCH:-/home/ubuntu/code/JetPack/scripts/bench_backends.py}"
  local SSH_KEY="${SSH_KEY:-${ROOT}/config/ssh/id_rsa}"
  local SETUP_JSON="${SCRIPT_DIR}/setup.json"

  if [ ! -f "${SETUP_JSON}" ]; then
    echo "ERROR: ${SETUP_JSON} missing — needed for multi-host dispatch" >&2
    exit 1
  fi

  # Read host inventory from setup.json (matches start_etcd_cluster_aws.sh).
  local n_hosts=$(jq -r '.n_server' "${SETUP_JSON}")
  echo "[multi] dispatching to ${n_hosts} hosts; CONC_LIST=${CONC_LIST}"
  echo "[multi] etcd_host=${ETCD_HOST}  mongo_host=${MONGO_HOST}  duration=${DURATION}s"

  local pids_run=()
  for ((i=0; i<n_hosts; i++)); do
    local eip=$(jq -r ".servers[$i].server_${i}_ip" "${SETUP_JSON}")
    (
      for c in ${CONC_LIST}; do
        for v in libetcd-async libetcd-sync grpc python-etcd mongo-cxx python-mongo; do
          if ! contains "${v}"; then continue; fi
          local cmd label
          case "${v}" in
            libetcd-async)
              label="libetcd_async_h${i}_c${c}"
              cmd="${REMOTE_BIN}/bench_etcd_libetcd \
                   --host ${ETCD_HOST} --mode async --num-clients 1 \
                   --conc ${c} --duration ${DURATION}" ;;
            libetcd-sync)
              label="libetcd_sync_h${i}_c${c}"
              cmd="${REMOTE_BIN}/bench_etcd_libetcd \
                   --host ${ETCD_HOST} --mode sync --num-clients 1 \
                   --conc ${c} --duration ${DURATION}" ;;
            grpc)
              label="grpc_h${i}_c${c}"
              cmd="${REMOTE_BIN}/bench_etcd_grpc \
                   --host ${ETCD_HOST} --num-channels 1 \
                   --conc ${c} --duration ${DURATION}" ;;
            python-etcd)
              label="python_etcd_h${i}_c${c}"
              cmd="python3 ${REMOTE_PYBENCH} etcd \
                   --host ${ETCD_HOST} --conc ${c} --duration ${DURATION}" ;;
            mongo-cxx)
              label="mongo_cxx_h${i}_c${c}"
              cmd="${REMOTE_BIN}/bench_mongo_cxx \
                   --host ${MONGO_HOST} --num-clients 1 \
                   --conc ${c} --duration ${DURATION}" ;;
            python-mongo)
              label="python_mongo_h${i}_c${c}"
              cmd="python3 ${REMOTE_PYBENCH} mongodb \
                   --host ${MONGO_HOST} --conc ${c} --duration ${DURATION}" ;;
          esac
          local res="${OUT}/${label}.res" csv="${OUT}/${label}.csv"
          ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
              -i "${SSH_KEY}" ubuntu@"${eip}" "${cmd}" \
              2> "${res}" 1> "${csv}" \
            || echo "[multi] ${label} FAILED on h${i} (${eip})" >&2
          if [ -s "${csv}" ]; then
            append_row "$(cat "${csv}")" "${i}" "multi"
          fi
        done
      done
    ) &
    pids_run+=($!)
  done
  echo "[multi] running on ${#pids_run[@]} hosts in parallel..."
  wait "${pids_run[@]}" 2>/dev/null || true
  echo "[multi] DONE — see ${RES_ROOT}/multi_host/ and ${AGG_CSV}"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  single) sweep_single ;;
  multi)  sweep_multi ;;
  both)   sweep_single; sweep_multi ;;
  *)
    cat <<EOF
usage: $0 {single|multi|both}
  single   sweep on current host (leader-co-located)
  multi    SSH-dispatch 2-point sweep to 10 AWS hosts
  both     run single first, then multi

Env vars: ETCD_HOST MONGO_HOST DURATION CONC_LIST NC_LIST VARIANTS
See script header for details.
EOF
    exit 2 ;;
esac
