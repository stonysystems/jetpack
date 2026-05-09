# TLA+ Runbook — 4-spec parallel run

Launch the four Jetpack composition specs side-by-side with disjoint CPU sets
and equal memory budgets. Written for the 500GB / 128-core zoo host where the
earlier large-config runs live in `tla/log/`.

## Layout

| Spec | Base protocol | Cpuset | Cores | Memory |
|---|---|---|---|---|
| `jetpack_raft_composition.tla` | Raft (1 proposer) | `65-74` | 10 | 40000MB |
| `jetpack_copilot_composition.tla` | CoPilot (pilot + copilot) | `75-84` | 10 | 40000MB |
| `jetpack_mencius_composition.tla` | Mencius (N proposers) | `85-94` | 10 | 40000MB |
| `jetpack_mongodb_composition.tla` | MongoDB (raft-like, "sole") | `95-104` | 10 | 40000MB |

Total budget: 40 cores + 160GB, well under the 1/3 auto cap of ~171GB.

All four run against [tla/large.cfg](large.cfg) (5 servers / 3 clients / 3 cmds / 2 keys).

## Prerequisites

- `tla/tla2tools.jar` present (v1.7.1, Java 8 compatible).
- `java` on `$PATH`. If local Java is 32-bit, the JVM heap is auto-clamped to
  1408MB regardless of `TLC_MEMORY_MB` — that's a known limitation recorded in
  every prior large-run log; it still makes forward progress, just slower.
- Host has ≥120GB RAM (each run's `TLC_MEMORY_MB` must be ≤ 1/3 of total).
- `taskset` available (`util-linux`), which `run-tlc.sh` already uses when
  `TLC_CPUSET` is set.

Sanity check:

```bash
cd tla
ls tla2tools.jar && java -version
nproc                  # must expose cores 65-104
awk '/MemTotal/' /proc/meminfo
```

## Launch (all four in parallel)

From `tla/` on the target host:

```bash
cd tla

# Batch label = today's date + rough (minute-precision) time. Shared across
# all four specs so you can group this experiment's logs with one glob.
EXP=$(date '+%Y%m%d_%H%M')

TLC_CPUSET=65-74  TLC_MEMORY_MB=40000 nohup ./run-tlc.sh \
    jetpack_raft_composition.tla    large.cfg -workers 10 \
    > log/${EXP}_jetpack_raft_composition.log 2>&1 &

TLC_CPUSET=75-84  TLC_MEMORY_MB=40000 nohup ./run-tlc.sh \
    jetpack_copilot_composition.tla large.cfg -workers 10 \
    > log/${EXP}_jetpack_copilot_composition.log 2>&1 &

TLC_CPUSET=85-94  TLC_MEMORY_MB=40000 nohup ./run-tlc.sh \
    jetpack_mencius_composition.tla large.cfg -workers 10 \
    > log/${EXP}_jetpack_mencius_composition.log 2>&1 &

TLC_CPUSET=95-104 TLC_MEMORY_MB=40000 nohup ./run-tlc.sh \
    jetpack_mongodb_composition.tla large.cfg -workers 10 \
    > log/${EXP}_jetpack_mongodb_composition.log 2>&1 &

jobs -l
echo "Batch label: $EXP"
```

Notes:
- `-workers 10` tells TLC itself to use 10 worker threads, matching the cpuset
  width. Without it TLC defaults to 1 worker and the extra cores idle.
- `TLC_MEMORY_MB=40000` is the container/script-level budget. The script derives
  `TLC_HEAP_MB` as 90% of that (= 36000MB) and passes `-Xmx36000m` to the JVM,
  unless local Java is 32-bit (in which case it clamps to 1408MB and logs it).

## Log files

Each run produces **two** log files under `tla/log/`:

1. **Batch log** (from the `nohup >` redirect above) — stable, predictable name
   you can tail from the moment you launch:

   ```
   tla/log/<YYYYMMDD>_<HHMM>_<spec_name>.log
   ```

   Example for a batch kicked off at 08:25 on 2026-04-21:

   ```
   tla/log/20260421_0825_jetpack_raft_composition.log
   tla/log/20260421_0825_jetpack_copilot_composition.log
   tla/log/20260421_0825_jetpack_mencius_composition.log
   tla/log/20260421_0825_jetpack_mongodb_composition.log
   ```

   All four share the same `<date>_<HHMM>` prefix, so one glob
   (`tla/log/20260421_0825_*.log`) picks up the whole experiment.

2. **run-tlc.sh's internal log** — written by the wrapper itself via `tee`:

   ```
   tla/log/<YYYYMMDD>_<HHMMSS>_<spec_name>_<config_label>.log
   ```

   Second-precision timestamp taken when the wrapper starts, plus the config
   label (`_large` here). This is the log referenced by prior runs checked in
   at `tla/log/20260325_094442_jetpack_raft_composition_large.log` etc.

The two files contain the same text (the wrapper tees stdout, which nohup also
captures). The batch log is there so you know the filename *before* the
wrapper picks its own second-precision stamp — handy when four specs launch
within the same second and you want predictable names to tail.

## Tracking progress

List the eight newest logs (4 batch + 4 wrapper), most recent first:

```bash
ls -lt tla/log/ | head -10
```

Follow all four specs of this batch via the stable-name batch logs:

```bash
tail -f tla/log/${EXP}_jetpack_*.log
```

Or via the wrapper's own logs (second-precision timestamp):

```bash
tail -f tla/log/*_jetpack_{raft,copilot,mencius,mongodb}_composition_large.log
```

Check the TLC processes:

```bash
ps -eo pid,psr,etime,pcpu,pmem,cmd | grep tla2tools | grep -v grep
```

- `psr` shows which CPU each worker is currently on — should stay inside the
  configured cpuset.
- Per-spec CPU utilization should approach `1000%` (10 cores × 100%) once TLC
  is past the initial-state generation phase.

TLC emits a progress line every few minutes of the form
`Progress(n) at t: <states> states generated, <distinct> distinct states, queue size <q>`.
`grep Progress tla/log/<file>` gives the time-series without scrolling.

## Stopping

```bash
# Stop a single spec (find its PID first):
ps -eo pid,cmd | grep jetpack_raft_composition | grep -v grep
kill <pid>

# Stop all four:
pkill -f 'tla2tools.jar.*jetpack_.*_composition'
```

Each Java process is the actual TLC worker parent — killing it propagates to
its worker threads. The `run-tlc.sh` wrapper finishes when TLC exits and writes
a trailing `Finished: …` line with the exit code to the log.

## Expected runtime

Historical large-config runs on the same host wall-clocked in the multi-day
range before state-space caps were hit. The `StateConstraint` in each
composition file caps term ≤ 3, log length ≤ 4, |messages| ≤ 5; reaching that
bound — not wall-clock — is what terminates the run.

## Caveats

- No `jetpack_mongodb.cfg` / `jetpack_mongodb_small.cfg` exists yet, so the
  MongoDB run must be invoked with an explicit config path
  (`large.cfg` above). The `CFG_FAMILY` switch in `run-tlc.sh` also doesn't
  include `jetpack_mongodb_composition`, so bare `./run-tlc.sh
  jetpack_mongodb_composition.tla` without a config argument will emit
  `WARNING: No config file found`.
- `taskset -c 65-74` requires the process owner to have access to those cores
  — on a host with cgroup cpuset restrictions (systemd slices, Docker), verify
  with `taskset -p $$` that your shell can see the target range first.
