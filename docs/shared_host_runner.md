# TLA Limited Runs

Use [`tla/run-tlc.sh`](/home/users/ztang/janus/tla/run-tlc.sh#L1) directly. You do not need an extra batch wrapper.

For a `128`-core / `503 GiB` host, a simple way to keep 3 TLC jobs from interfering too much is:

- use CPUs `96-105` for Raft
- use CPUs `106-115` for CoPilot
- use CPUs `116-125` for Mencius
- use about `40000` MiB per job

That keeps the combined batch around:

- `30` CPUs total
- `120000` MiB total

which is close to `1/4` of the machine.

## Commands

All three commands:

- use `tla/large.cfg`
- are meant to be run directly inside `tmux`
- write the launch stdout/stderr into the `tla/` folder via `tee`
- still let [`tla/run-tlc.sh`](/home/users/ztang/janus/tla/run-tlc.sh#L278) write its timestamped TLC log into `tla/log/`

```bash
prlimit --as=$((43000*1024*1024)) -- \
  env TLC_MODE=local TLC_CPUSET=96-105 TLC_MEMORY_MB=40000 \
  ./tla/run-tlc.sh jetpack_raft_composition.tla tla/large.cfg \
  2>&1 | tee tla/raft_large.launch.log
```

```bash
prlimit --as=$((43000*1024*1024)) -- \
  env TLC_MODE=local TLC_CPUSET=106-115 TLC_MEMORY_MB=40000 \
  ./tla/run-tlc.sh jetpack_copilot_composition.tla tla/large.cfg \
  2>&1 | tee tla/copilot_large.launch.log
```

```bash
prlimit --as=$((43000*1024*1024)) -- \
  env TLC_MODE=local TLC_CPUSET=116-125 TLC_MEMORY_MB=40000 \
  ./tla/run-tlc.sh jetpack_mencius_composition.tla tla/large.cfg \
  2>&1 | tee tla/mencius_large.launch.log
```

## Knobs You Can Change

```bash
prlimit --as=$((<address-space-mb>*1024*1024)) -- \
  env TLC_MODE=local TLC_CPUSET=<cpu-range> TLC_MEMORY_MB=<heap-mb> \
  ./tla/run-tlc.sh <spec.tla> tla/large.cfg \
  2>&1 | tee tla/<name>.launch.log
```

- `TLC_CPUSET`: CPU pinning for the TLC process, for example `96-105`
- `TLC_MEMORY_MB`: JVM/TLC memory budget used by [`tla/run-tlc.sh`](/home/users/ztang/janus/tla/run-tlc.sh#L228)
- `prlimit --as`: stricter process address-space cap
- `<spec.tla>`: choose the spec you want

Examples:

- `jetpack_raft_composition.tla`
- `jetpack_copilot_composition.tla`
- `jetpack_mencius_composition.tla`
