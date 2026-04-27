# CURP paper — data sweep

Date: 2026-04-26 → 2026-04-27 (overnight, ~6 h wall)
Cluster: zoo1..zoo5, `SERVER_CORE_ID=17`, `WAN_DELAY_MS=20`,
30 s per data point, 500 ongoing per client.
Driver: [scripts/run_curp_data_sweep.sh](../../scripts/run_curp_data_sweep.sh).
Figure builder: [scripts/build_curp_figures.py](../../scripts/build_curp_figures.py).

## Layout

| Path | Contents |
|---|---|
| `set_a_throughput_latency/` | per-replica `.res` + per-cmd `.csv` for the concurrency sweep |
| `set_b_keyrange/` | per-replica artifacts for the key-range sweep at fixed N |
| `set_c_zipf/` | per-replica artifacts for the zipf sweep at fixed N |
| `set_a_summary.csv` | parsed metrics per (proto, mode, N) — 119 rows |
| `set_b_summary.csv` | parsed metrics per (proto, mode, key-range) — 161 rows |
| `set_c_summary.csv` | parsed metrics per (proto, mode, zipf) — 161 rows |
| `fixed_n_per_protocol.csv` | per-protocol N picked from Set A as closest to 50% zoo2 CPU |
| `figures/` | 8 PNGs + per-figure data CSVs under `figures/data/` |

## Protocol/mode matrix (23 entries)

For each of `raft / copilot / mencius / etcd / mongodb`:
`<base>`, `jp-<base>-fp0`, `jp-<base>-fp100`, `jp-<base>-adaptive`. Plus
`epaxos`, `swiftpaxos`, `curp` standalone.

## Per-protocol fixed-N (Set B/C unsaturated point, ~50% leader CPU)

See `fixed_n_per_protocol.csv`. Highlights:

| protocol | peak N | peak tput | fixed N | fixed cpu |
|---|---|---|---|---|
| raft | 100 | 15,594 | 150 | 41.8% |
| jp-raft-fp100 | 75 | 14,981 | 150 | 49.2% |
| jp-raft-adaptive | 75 | 14,984 | 100 | 44.5% |
| epaxos | 150 | 28,480 | 200 | 26.3% |
| swiftpaxos | 100 | 16,153 | 100 | 58.2% |
| **curp** | **75** | **13,467** | **100** | **48.4%** |
| copilot family | 25 | ~5,000 | 25 | 77–89% (saturates fast) |
| etcd family | 50–100 | ~10,000 | 100 | 24–49% |

## Known data gaps (pre-existing issues, not script failures)

- **Mencius family**: peak tput 0 (segfault). Pre-existing glibc 2.35 binary
  vs glibc 2.41 host heap-corruption bug (TODO Track 8F). Mencius rows in
  the figures are absent.
- **MongoDB family**: trivial throughput (peak ~20 cmd/s for `mongodb`,
  `jp-mongodb-fp0`; ~1k–1.6k for `jp-mongodb-fp100`/`adaptive`). Likely
  mongo-cxx-driver state issue from the existing modified submodule
  (`third_party/mongo-cxx-driver` shows `modified content` in git status).
  Surfaces as flat lines / missing series in the figures.

## Figures

- `figures/fig_throughput_latency.png` — Set A: total tput (cmd/s) vs zoo2 p50 (ms), one curve per protocol/mode.
- `figures/fig_latency_cdf.png` — Set A at the per-protocol fixed-N: per-cmd end-to-end latency CDF.
- `figures/fig_keyrange_avg_latency.png` — Set B: key range vs avg per-cmd latency.
- `figures/fig_zipf_avg_latency.png` — Set C: zipf vs avg per-cmd latency.
- `figures/fig_zipf_p90.png` — Set C: zipf vs zoo2 p90.
- `figures/fig_zipf_p99.png` — Set C: zipf vs zoo2 p99.
- `figures/fig_zipf_fp_rate.png` — Set C: zipf vs fast-path success rate (jp-* and curp).
- `figures/fig_zipf_success_rate.png` — Set C: zipf vs efficient fast-path success rate.

Per-figure underlying data lives at `figures/data/<fig>.csv`.

## Reproducing

```bash
SERVER_CORE_ID=17 \
  scripts/run_curp_data_sweep.sh \
  results/<date>-curp-data-sweep-core17

python3 scripts/build_curp_figures.py \
  results/<date>-curp-data-sweep-core17
```

Wall time ~6 h.
