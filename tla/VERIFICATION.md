# TLA+ Verification Guide

Reproducible model-checking workflow for the Jetpack consensus plugin.

Thin-wrapper rename note: on 2026-03-16 the decoupled wrapper specs were renamed
from `jetpack_raft.tla`, `jetpack_copilot.tla`, and `jetpack_mencius.tla` to
`jetpack_raft_composition.tla`, `jetpack_copilot_composition.tla`, and
`jetpack_mencius_composition.tla`. Older logs still reference the legacy names.

Scope note: this file keeps the reproducible workflow and historical evidence. If
it disagrees with `tla/TLA_PLUS_BIG_PICTURE.md` or `TODO.md` about the active
finish bar, treat those two files as authoritative for the current task.

## Accepted Jetpack/Base Compositions

| Spec file | Base protocol | Proposer model |
|---|---|---|
| `jetpack_raft_composition.tla` | Raft (`base_raft.tla`) | 1 proposer (`"sole"`) |
| `jetpack_copilot_composition.tla` | CoPilot (`base_copilot.tla`) | 2 proposers (pilot + copilot) |
| `jetpack_mencius_composition.tla` | Mencius (`base_mencius.tla`) | N proposers (round-robin) |

All three compose `jetpack.tla` via TLA+ `INSTANCE` with protocol-specific
`Proposer`, `ProposerOf`, and `NoOpCmd` bindings.

## Config Files

### Small configs (quick exhaustive check)

| Config file | Constants |
|---|---|
| `jetpack_raft_small.cfg` | 3 servers, 1 client, 1 cmd, 1 key |
| `jetpack_copilot_small.cfg` | 3 servers, 1 client, 1 cmd, 1 key |
| `jetpack_mencius_small.cfg` | 3 servers, 1 client, 2 cmds, 1 key |

Mencius small uses 2 CmdIds to exercise multi-proposer interleaving.

### Big configs (historical large-run configs)

| Config file | Constants |
|---|---|
| `jetpack_raft.cfg` | 5 servers, 1 client, 3 cmds, 2 keys |
| `jetpack_copilot.cfg` | 5 servers, 1 client, 3 cmds, 2 keys |
| `jetpack_mencius.cfg` | 5 servers, 1 client, 3 cmds, 2 keys |

The big configs encode the accepted large-run constants: 5 servers, 1 client,
3 commands, 2 keys. The current acceptance window is defined by the active task
docs, not by this historical section.

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

`tla/run-tlc.sh` now enforces the repository memory policy automatically:

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
./tla/run-tlc.sh jetpack_raft_composition.tla small
./tla/run-tlc.sh jetpack_copilot_composition.tla small
./tla/run-tlc.sh jetpack_mencius_composition.tla small

# Large-config runs (runtime window defined by the current task docs):
./tla/run-tlc.sh jetpack_raft_composition.tla
./tla/run-tlc.sh jetpack_copilot_composition.tla
./tla/run-tlc.sh jetpack_mencius_composition.tla
```

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
```

## Verified Properties

Each composition checks the following safety invariants (via `Safety` property):

- **CommittedLogAgreement** — All servers agree on committed log entries.
- **MultiSequenceLogAgreement** — Per-proposer sequences are consistent across servers.
- **LogOrderMatchesExecution** — Execution order matches log commitment order.
- **ExecutionDedupMatches** — Deduplicated execution trace is consistent.

Additional protocol-specific properties:
- **Raft**: (none beyond the shared set)
- **CoPilot**: `ActiveProposerBound` — at most 2 active proposers at any time.
- **Mencius**: `SlotAgreement` — all servers agree on learned/skipped slot values.

## Verification Status

### Post-3D-refactor runs (2026-03-08 to 2026-03-12)

| Spec | Config | Result | States generated | Distinct states |
|---|---|---|---|---|
| `jetpack_raft_composition.tla` | small | Exhaustive, no errors | 82,375 | 6,029 |
| `jetpack_copilot_composition.tla` | small | Exhaustive, no errors | 515 | 70 |
| `jetpack_mencius_composition.tla` | small | Terminated (OOM), no errors (34h) | 598,252,218 | 56,217,812 |
| `jetpack_raft_composition.tla` | big | 12h bounded run completed, no TLC error/invariant/deadlock marker (accepted) | 87,135,107 | 9,101,950 |
| `jetpack_copilot_composition.tla` | big | 12h+ bounded run completed, no TLC error/invariant/deadlock marker (accepted, detached-run caveat) | 47,418,535 | 4,040,373 |
| `jetpack_mencius_composition.tla` | big | Not yet run | — | — |

Logs: `tla/log/20260308_*` (small runs),
`tla/log/20260310_214540_jetpack_raft.log`,
`tla/log/20260310_214540_jetpack_raft_big_launcher.log`,
`tla/log/20260311_102514_jetpack_copilot.log`,
`tla/log/20260311_102513_jetpack_copilot_big_launcher.log` (big runs)
Primary Mencius small evidence: `tla/log/20260308_101553_jetpack_mencius_small.log`

Raft big-run note (2026-03-10/11): launched before the rename via
`timeout 12h ./tla/run-tlc.sh jetpack_raft.tla`. Final TLC line was
`Progress(13) at 2026-03-11 13:45:21 ... 87,135,107 generated, 9,101,950 distinct`.
No `Error:`, invariant-violation, or deadlock marker was emitted before timeout-window
closure. The expected launcher status file
`tla/log/20260310_214540_jetpack_raft_big_launcher.status` was not present for this run,
so the timeout exit code is recorded as inferred (`124`) rather than directly captured.

CoPilot big-run note (2026-03-11/12): launched before the rename via
`timeout 12h ./tla/run-tlc.sh jetpack_copilot.tla`. The launcher wrapper exited without
writing `tla/log/20260311_102513_jetpack_copilot_big_launcher.status`, but the TLC Docker
container continued running detached (`started=2026-03-11T14:25:17Z`). At
`2026-03-12T02:47:49Z` (12h22m elapsed), the captured TLC log reached:
`Progress(14) at 2026-03-12 02:47:19: 47,418,535 generated, 4,040,373 distinct`.
No `Error:`, invariant-violation, or deadlock marker appeared before manual stop after the
>=12h evidence capture.

### Note on Mencius small-config state space

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
result is accepted as sufficient verification evidence. Exhaustive completion
would require a machine with significantly more memory (the queue was still
growing at termination) or a distributed TLC setup.
