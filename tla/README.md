# TLA+ specifications

The Jetpack shim is specified once, in `jetpack.tla`, line by line from
[`docs/pseudocode.md`](../docs/pseudocode.md) (the line tags N1–N25, T1–T2, L1–L54 appear in the
comments), and composed with one base protocol per wrapper module:

| Composition | Base module | Proposers per view | View id (pseudocode §0) |
|---|---|---|---|
| `jetpack_raft_composition.tla` | `base_raft.tla` (Raft with single-server add/remove) | 1 | (term, index of the latest config entry) |
| `jetpack_mongodb_composition.tla` | `base_mongodb.tla` (MongoDB replication with single-server reconfig) | 1 | (term, index of the latest config entry) |
| `jetpack_copilot_composition.tla` | `base_copilot.tla` | 2 (pilot, copilot) | (ballot of pilot 0, ballot of pilot 1) |
| `jetpack_mencius_composition.tla` | `base_mencius.tla` | all servers | one static view (no recovery; the fast path needs every server) |

A wrapper declares the variables, INSTANCEs its base module and `jetpack.tla`, wraps each
action with the UNCHANGED of the other side, and supplies the base-specific pieces: the view a
new proposer starts (`ViewOf`), the trigger (T1: a proposer that became `ToBeLeader` starts a
coordinator before appending anything else, and becomes `Leader` again when its own
`Recovered(S)` entry commits, T2), and the execution order across sequences
(`ApplyCommitted`). While a proposer is paused (`ToBeLeader`) the base keeps replicating and
committing but proposes no client command.

`raft.tla`, `raft_ongaro.tla`, `copilot.tla`, `mencius.tla` and `mongodb.tla` are standalone
base protocols kept for reference. `archive/` holds the pre-reconfiguration Raft files.
In the Copilot composition every pilot change pauses both pilots (T1 for both), each runs a
coordinator, and a pilot resumes only when its own Recovered entry of the current view is
committed (T2); execution follows Copilot's dependency order through `jetpack.tla`'s
per-sequence `applied` counters.

## What `jetpack.tla` models

- Replica state `rstate[i]`: `lnv` (last normal view), `nv` (new view), `mode`, the pool of
  the current last normal view, `max_seen_ballot` and `accepted` per recovered view; the
  `join` and `learn` rules of pseudocode §0.
- Coordinator state `cstate[i]` (one per proposer of the new view): phase, view, v_n, ballot,
  recovery set, replies. Several coordinators of one view are allowed; ballots order them.
- Messages FastCmd / FastAck / FastNack, BeginRecovery / BeginRecoveryOK, Prepare / PrepareOK,
  Accept / AcceptOK, Nack, FinishRecovery(v, S) / FinishRecoveryOK, in a message bag.
- Recovered(S) as one log entry per proposer (L47, L53); execution expands it and
  deduplicates by command (N25, L50); GC of executed commands only while Normal (N21, N24);
  Restart keeps Jetpack's state (it is persisted with the base's, §0).
- Modeling choices that are not protocol changes are listed in the module header (no return
  values, an explicit FastNack on a conflict so the client's timeout is a step, no client
  resends, no backoff, FinishRecovery carries v_n as metadata).

## Properties

Checked as invariants in every composition unless noted:

| Invariant | Meaning |
|---|---|
| `CommittedLogAgreement` | committed entries agree across servers, per sequence |
| `LogOrderMatchesExecution` | committed log order and the execution trace agree on conflicting commands (Mencius checks `SlotOrderMatchesExecution` instead) |
| `ExecutionDedupMatches` | the fast-path and original-path execution traces agree on conflicting commands |
| `ReplicaInvariants` | pseudocode §0: `lnv ≤ nv`, `mode = Recovery ⟺ nv > lnv` |
| `RecoveredAgreement` | all Recovered entries for one recovered view carry the same set |
| `FastCommitDurability` | once some replica's last normal view is past the view a command was fast-committed in, that command is committed on the original path (paper C1) |
| `PoolsConflictFree` | pools are pairwise conflict-free |
| `Principle2Raft` / `Principle2MongoDb` / Copilot's equivalent | before any client command of a view comes that view's Recovered entry |
| `EpochDeterminesMembership` | one view id names one membership and proposer set |
| base-specific | `NoLogDivergence`, `MaxOneReconfigurationAtATime`, `ElectionSafety` (Raft, MongoDB); `SlotAgreement`, `LogMatchesSlots`, `StaticView` (Mencius) |

Each wrapper also defines `Probe_*` operators that are EXPECTED to be violated
(`Probe_NoFastCommit`, `Probe_NoViewInstalled`, `Probe_NoRecoveredCommitted`, …). Checking one
as an INVARIANT makes TLC print a trace that reaches the behavior, which shows the model
exercises it; the `jetpack_*_probe_*.cfg` files do this.

## Running TLC

`run-tlc.sh` runs TLC locally when `tla2tools.jar` is in this directory (TLC 1.7.1 works with
Java 8; `wget https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar`), and
otherwise in Docker (`Dockerfile`, TLC 1.8.0). Logs go to `log/`.

```bash
cd tla
TLC_MODE=local ./run-tlc.sh jetpack_raft_composition.tla small -workers 4        # jetpack_raft_small.cfg
TLC_MODE=local ./run-tlc.sh jetpack_raft_composition.tla jetpack_raft_recovery.cfg -workers 4
TLC_MODE=local ./run-tlc.sh jetpack_raft_composition.tla jetpack_raft_probe_NoViewInstalled.cfg
TLC_MODE=local ./run-tlc.sh jetpack_raft_composition.tla small -coverage 1       # action coverage
```

Configurations (Raft; the other compositions have the same `_small` / default pair):

| Config | Constants | Constraint | Purpose |
|---|---|---|---|
| `jetpack_raft_small.cfg` | 3 servers, 1 client, 1 command, 1 key, 1 election, no reconfig | `SmallStateConstraint` (term ≤ 2, ≤ 10 messages, log ≤ 3) | fast path + one recovery |
| `jetpack_raft_recovery.cfg` | 3 servers, no clients, 1 election | `RecoveryStateConstraint` (≤ 12 messages) | the recovery protocol alone (Recovered(∅) marker, Nack/learn paths) |
| `jetpack_raft.cfg` | 4 servers (3 initial), 2 commands, 1 election, 1 restart, 1 add + 1 remove | `StateConstraint` | reconfiguration |
| `jetpack_raft_probe_*.cfg` | as small / recovery | | reachability traces |

The message bound matters: a recovery phase broadcasts to every replica, so below about 10
messages in flight TLC prunes the states in which recovery completes. The probes show where
the bound is sufficient: with `RecoveryStateConstraint`, `Probe_NoViewInstalled` is violated by
a 28-state trace (election → BeginRecovery → Prepare → Accept → Recovered committed → resume →
FinishRecovery → view installed; `log/20261031_104739_*_probe_recovery_NoViewInstalled.log`).

## Results recorded in `log/`

| Run | Result |
|---|---|
| Raft, `jetpack_raft_small.cfg` with the earlier bound of 4 messages | exhaustive, 32,150 distinct states, no violation (recovery not reached under that bound) |
| Raft, `jetpack_raft_probe_*` | traces found: fast commit (10 states), Recovered submitted (22), Recovered committed, proposer resumed and view installed (28) |
| Raft, `jetpack_raft_recovery.cfg` | exhaustive run in progress at the time of writing; see the newest `*_jetpack_raft_recovery.log` |
| MongoDB, `jetpack_mongodb_probe_NoViewInstalled.cfg` | trace found (42 states, simulation mode) |
| Mencius, `jetpack_mencius_probe_NoFastCommit.cfg` | trace found (8 states): every server acks and proposes the command in its own slot |
| Copilot, `jetpack_copilot_probe_NoViewInstalled_sim.cfg` | trace found (53 states, simulation mode): a pilot raises its ballot, both pilots pause, Recovered(∅) commits, the pilot resumes and installs the view |
| Copilot, `jetpack_copilot_small.cfg` / `jetpack_copilot.cfg` | simulation sweeps (depth 100, 150 s each): 491,458 and 285,748 states, no violation; bounded BFS stopped after 10 min without violation |

`LogOrderMatchesExecution` deduplicates a committed sequence before comparing it with the
execution trace: a command may recur in a sequence (proposed at ack time and again inside a
Recovered entry, or by two proposers), and only its first occurrence executes.

Earlier results (the pre-pseudocode specifications, up to 2026-10-02) are in the older logs
and in the git history of this directory.
