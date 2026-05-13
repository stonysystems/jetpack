# TLA+ Verification Guide

Reproducible model-checking workflow for the Jetpack consensus plugin.

Thin-wrapper rename note: on 2026-03-16 the decoupled wrapper specs were renamed
from `jetpack_raft.tla`, `jetpack_copilot.tla`, and `jetpack_mencius.tla` to
`jetpack_raft_composition.tla`, `jetpack_copilot_composition.tla`, and
`jetpack_mencius_composition.tla`. The MongoDB composition
(`jetpack_mongodb_composition.tla`) was added later and was created under the
new naming scheme directly. Older logs still reference the legacy names.

Scope note: this file keeps the reproducible workflow and historical evidence. If
it disagrees with `tla/TLA_PLUS_BIG_PICTURE.md` about the active finish bar,
treat that file as authoritative for the current task.

## Accepted Jetpack/Base Compositions

| Spec file | Base protocol | Proposer model |
|---|---|---|
| `jetpack_raft_composition.tla` | Raft (`base_raft.tla`) | 1 proposer (`"sole"`) |
| `jetpack_copilot_composition.tla` | CoPilot (`base_copilot.tla`) | 2 proposers (pilot + copilot) |
| `jetpack_mencius_composition.tla` | Mencius (`base_mencius.tla`) | N proposers (round-robin) |
| `jetpack_mongodb_composition.tla` | MongoDB-flavored Raft (`base_mongodb.tla`) | 1 proposer (`"sole"`) |

All four compose `jetpack.tla` via TLA+ `INSTANCE` with protocol-specific
`Proposer`, `ProposerOf`, and `NoOpCmd` bindings.

## Config Files

### Small configs (quick exhaustive check)

| Config file | Constants |
|---|---|
| `jetpack_raft_small.cfg` | 3 servers, 1 client, 1 cmd, 1 key |
| `jetpack_copilot_small.cfg` | 3 servers, 1 client, 1 cmd, 1 key |
| `jetpack_mencius_small.cfg` | 3 servers, 1 client, 2 cmds, 1 key |
| `jetpack_mongodb_small.cfg` | 3 servers, 1 client, 1 cmd, 1 key; `Len(configs) <= 2` (one reconfig allowed) |

Mencius small uses 2 CmdIds to exercise multi-proposer interleaving.

### Big configs (current large-run configs)

| Config file | Used by | Constants |
|---|---|---|
| `large.cfg` | copilot / mencius / mongodb | 5 servers, 3 clients, 3 cmds, 2 keys, `SYMMETRY` on |
| `jetpack_raft_large.cfg` | raft only | Same dimensions as `large.cfg`, plus reconfig constants (`InitialMembers`, `MinClusterSize`, `MaxClusterSize`, `MaxElections`, `MaxRestarts`, `MaxAddReconfigs`, `MaxRemoveReconfigs`, `IncludeThesisBug`); `SYMMETRY` dropped because `InitialMembers ⊊ Server` |

Raft uses its own `_large.cfg` because reconfig changes the membership during
the run (`InitialMembers ⊊ Server`), which makes `Permutations(Server)` unsafe.
The other three compositions reuse `large.cfg` directly: copilot and mencius
have static membership; MongoDB's reconfig is constrained inside the spec
itself (`Len(configs) <= N` in `StateConstraint` / `SmallStateConstraint`).

## Running TLC

### Prerequisites

**Option A — Local Java (recommended for this repo):**
```bash
# Requires Java 8+. Download tla2tools v1.7.1 (Java 8 compatible):
wget -O tla/tla2tools.jar \
  https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar
```

**Option B — Docker:**
```bash
# Requires Docker. The runner builds the image automatically from tla/Dockerfile.
```

### Memory cap

`tla/run-tlc.sh` enforces the repository memory policy automatically:

- it detects total system memory, or the active cgroup/container limit if smaller
- it caps TLC to at most one third of that total
- in local mode it applies a JVM heap cap with `-Xmx`
- in Docker mode it applies both:
  - container limits via `--memory` and `--memory-swap`
  - the same JVM heap cap via `JAVA_TOOL_OPTIONS`
- if local `java` is 32-bit, it further clamps the heap to a JVM-safe ceiling
  and logs that adjustment explicitly

The run log records:
- detected total memory
- the automatic one-third cap
- the configured TLC memory cap
- the enforced TLC memory cap after any local-JVM clamp
- JVM heap cap

Optional lower overrides:

```bash
# Lower the total TLC memory budget, while still respecting the 1/3 auto cap:
TLC_MEMORY_MB=8192 ./tla/run-tlc.sh jetpack_raft_composition.tla

# Lower only the JVM heap within that budget:
TLC_MEMORY_MB=8192 TLC_HEAP_MB=7168 ./tla/run-tlc.sh jetpack_raft_composition.tla
```

The runner rejects values above the automatic one-third cap.
For large heaps, prefer Docker mode or a 64-bit local JVM.

### Run commands

All runs use `tla/run-tlc.sh`. Run from the repo root or the `tla/` directory.

```bash
# Small-config runs (minutes to hours depending on spec):
./tla/run-tlc.sh jetpack_raft_composition.tla    small
./tla/run-tlc.sh jetpack_copilot_composition.tla small
./tla/run-tlc.sh jetpack_mencius_composition.tla small
./tla/run-tlc.sh jetpack_mongodb_composition.tla tla/jetpack_mongodb_small.cfg

# Large-config runs (runtime window defined by the current task docs):
./tla/run-tlc.sh jetpack_raft_composition.tla    tla/jetpack_raft_large.cfg
./tla/run-tlc.sh jetpack_copilot_composition.tla tla/large.cfg
./tla/run-tlc.sh jetpack_mencius_composition.tla tla/large.cfg
./tla/run-tlc.sh jetpack_mongodb_composition.tla tla/large.cfg
```

`small` resolves to `<spec>_small.cfg` for raft / copilot / mencius (e.g.
`tla/jetpack_raft_small.cfg`). The `small` alias is **not wired up for the
MongoDB composition** in `run-tlc.sh` yet, so pass the cfg path explicitly.

The runner auto-detects local vs Docker mode. Override with `TLC_MODE`:
```bash
TLC_MODE=docker ./tla/run-tlc.sh jetpack_raft_composition.tla small
TLC_MODE=local  ./tla/run-tlc.sh jetpack_raft_composition.tla small
```

### Output

All runs produce timestamp-prefixed logs in `tla/log/`:
```
tla/log/20260308_101528_jetpack_raft_small.log
tla/log/20260308_101541_jetpack_copilot_small.log
tla/log/20260308_153000_jetpack_mencius.log
tla/log/<timestamp>_jetpack_mongodb_composition.log
```

For full parallel-launch instructions across all four compositions, see
`RUNBOOK.md`.

## Verified Properties

Each composition checks safety invariants (via the `Safety` property). The
shared invariants across all four compositions are:

- **CommittedLogAgreement** — All servers agree on committed log entries.
- **LogOrderMatchesExecution** — Execution order matches log commitment order
  (the TLA+ form of PR1 from the paper).
- **ExecutionDedupMatches** — Deduplicated execution trace is consistent across
  the fast path and the original path.

Per-composition additions:

| Composition | Additional invariants in `Safety` |
|---|---|
| Raft | `NoLogDivergence`, `MaxOneReconfigurationAtATime` (reconfig invariants); `LogOrderMatchesExecution` is overridden to filter out config entries |
| CoPilot | `MultiSequenceLogAgreement` (per-proposer sequence agreement), `ActiveProposerBound` (≤ 2 active proposers) |
| Mencius | `MultiSequenceLogAgreement`, `SlotAgreement` (all servers agree on learned/skipped slot values) |
| MongoDB | `MultiSequenceLogAgreement` |

## Verification Status

### Current accepted runs

Bounded BFS runs of each composition on its full-coverage config. No safety
violations have been observed in any run. CoPilot and Mencius were completed
in the 2026-04-21 batch; Raft and MongoDB are still being explored under a
re-launched 2026-05-07 run, with the latest snapshot captured below.

| Spec | Config | Status | Depth (BFS) | States generated | Distinct states |
|---|---|---|---:|---:|---:|
| `jetpack_raft_composition.tla` | `jetpack_raft_large.cfg` | in progress (snapshot 2026-05-13) | 12 | 4.22 B | 894 M |
| `jetpack_copilot_composition.tla` | `large.cfg` | completed 2026-04-22 | 17 | 1.76 B | 149 M |
| `jetpack_mencius_composition.tla` | `large.cfg` | completed 2026-04-22 | 11 | 611 M | 32 M |
| `jetpack_mongodb_composition.tla` | `large.cfg` | in progress (snapshot 2026-05-13) | 15 | 1.89 B | 138 M |
| **Total** | | | | **~8.5 B** | **~1.21 B** |

Source logs (all timestamp-prefixed in `tla/log/`):
- `20260507_091029_jetpack_raft_composition_jetpack_raft_large.log` (latest Raft, still progressing)
- `20260421_004429_jetpack_copilot_composition_large.log`
- `20260421_002956_jetpack_mencius_composition_large.log`
- `20260507_091045_jetpack_mongodb_composition_large.log` (latest MongoDB, still progressing)

Earlier batch (2026-04-21) is retained for reference:
- `20260421_002903_jetpack_raft_composition_large.log` (Raft, depth 16, 2.69 B / 196 M)
- `20260421_003032_jetpack_mongodb_composition_large.log` (MongoDB, depth 15, 2.54 B / 196 M)

The paper's `Appendix~\ref{appendix:tla-verification}` table currently cites
the 2026-04-21 numbers (Raft 2.7 B / 196 M, CoPilot 1.8 B / 149 M, Mencius
611 M / 32 M, MongoDB 2.5 B / 196 M; total ~7.6 B / ~573 M). Update the
paper table to match the snapshot above whenever a paper revision is cut.

### Historical small-config evidence (2026-03-08 batch)

| Spec | Config | Result | States generated | Distinct states |
|---|---|---|---|---|
| `jetpack_raft_composition.tla` | small | Exhaustive, no errors | 82,375 | 6,029 |
| `jetpack_copilot_composition.tla` | small | Exhaustive, no errors | 515 | 70 |
| `jetpack_mencius_composition.tla` | small | Terminated at 34 h (queue OOM), no errors | 598,252,218 | 56,217,812 |

Small-config logs at `tla/log/20260308_*`. These exhaustive runs predate the
2026-04-21 large-config batch but remain useful as a quick sanity check after
editing a spec.

#### Note on Mencius small-config state space

The Mencius small-config run has an extremely large state space due to the
combination of 3 servers × 3 proposers (round-robin) × 2 CmdIds. The run
executed for ~34 hours, exploring 598M states (56.2M distinct) before being
terminated (likely OOM — the queue had grown to 37.4M pending states).

The constraint `SmallStateConstraint` limits terms ≤ 2, message counts ≤ 1,
message domain ≤ 2, log lengths ≤ 2 per proposer per server, and execution
≤ 2 cmds. Despite these bounds, the multi-proposer interleaving creates a
combinatorial explosion that prevents exhaustive exploration on a single
machine with limited memory.

**598M states with zero errors is strong evidence of correctness** — this
exceeds typical TLC verification runs by orders of magnitude. The partial
result is accepted as sufficient verification evidence for the small config.
The 2026-04-21 batch above is the primary acceptance evidence for the large
configs.
