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
| `jetpack_*_n5.cfg` / `jetpack_*_n5_staged.cfg` | 5 servers, 2 clients, 3 commands, 2 keys, 2 elections (Copilot: 2 pilot changes), 1 restart | `N5StateConstraint`; `_staged` also issues at most 2 commands before a view after the initial one is installed | the smallest n where the fast quorum (4) is smaller than n; long simulation runs |
| `jetpack_raft_ci.cfg` | as small, but `MaxElections = 0` | `CiStateConstraint` (term ≤ 1, ≤ 10 messages, log ≤ 2) | the fast path without an election, exhaustive in under a minute (CI) |
| `jetpack_raft_probe_ci_NoFastCommittedInRecovered.cfg` | as small | `CiProbeConstraint` (see the module) | a Recovered(S) containing the fast-committed command, submitted by the new leader while the old leader's proposal is uncommitted; reached in about a minute (CI) |

`.github/workflows/formal.yml` runs, on every push and pull request, SANY on the four
compositions and `jetpack_raft_ci.cfg` exhaustively: that run has no election, so it checks
the fast path only. Recovery coverage on every push comes from the two probe steps
(`jetpack_raft_probe_recovery_NoViewInstalled.cfg`: a complete recovery with the view
installed; the CI probe above: the recovery set carrying the fast-committed command), whose
invariants are expected to be violated (TLC exit code 12). The `_small` / recovery
configurations run nightly (`workflow_dispatch` with `set=nightly` until the file is on the
default branch), with the logs of each run as artifacts.

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
| Raft, `jetpack_raft_ci.cfg` (CI) | exhaustive, 31,702 distinct states (221,205 generated), no violation; 34 s with 2 workers on the shared 64-core server (`log/20261031_191441_*_jetpack_raft_ci.log`) |
| Raft, `jetpack_raft_probe_ci_NoFastCommittedInRecovered.cfg` (CI) | trace found (33 states): fast commit, election, BeginRecovery/Prepare/Accept, Recovered(S) with the command submitted by the new leader; 56 s with 2 workers on the same server, 112,275 distinct states explored (`log/20261031_191445_*_probe_ci_NoFastCommittedInRecovered.log`) |
| Raft, `jetpack_raft_probe_recovery_NoViewInstalled.cfg` (CI) | the 28-state trace above; 2 min 45 s with 2 workers on the same server, 627,427 distinct states explored (`log/20261031_191310_*_probe_recovery_NoViewInstalled.log`) |
| Raft, `jetpack_raft.cfg` (reconfiguration, restart) | simulation, depth 150, 4 h with 3 workers: 122,939,232 states checked over 2,973,131 traces, no violation (`log/20261031_160602_*_jetpack_raft.log`). The first simulation (`log/20261031_160047_*`) stopped after 15 states on `MaxOneReconfigurationAtATime`, which compared a leader's config entries with its own commitIndex; `Restart` resets that index, so a re-elected leader reported a long-committed `InitCluster` entry as pending. The invariant now uses `ConfigEntryCommitted`: a config entry is committed once a majority of the members it names hold it, which is how Raft commits it. |
| Copilot, `jetpack_copilot_probe_NoViewInstalled.cfg` under `SmallStateConstraint` (simulation) | trace found in 1 s (72 states): fast commit, `FastTakeover`, BeginRecovery/Prepare/Accept, Recovered committed, pilot resumed (`log/20261031_164442_*`); so the small configuration's message bound does not prune the recovery. The breadth-first search of the same probe explored 14.3 M distinct states to depth 18 in 45 min without reaching it and was stopped. |
| MongoDB, `jetpack_mongodb_small.cfg` | the first exhaustive run reached depth 28 (97 M distinct states, 7 h 14 min) and stopped while evaluating `CommittedLogAgreement` over a log emptied by a rollback (`log/20261031_160043_*`): a member that had voted in a newer term pulled an entry from the previous primary, which then counted it toward commitment, and the new term rolled the entry back. `base_mongodb.tla` now counts a member toward commitment only in the primary's term, the rule of the MongoDB specifications (MongoStaticRaft / MongoRaftReconfig). The exhaustive run was restarted with that module; the recovery probe still finds a complete recovery (48 states, simulation). |
| Raft `jetpack_raft_small.cfg`, Copilot `jetpack_copilot_small.cfg`, Mencius `jetpack_mencius_small.cfg`, MongoDB `jetpack_mongodb_small.cfg` | breadth-first, stopped after about 4 days without completing (the state space under the ≤ 10 message bound does not close in that time), no violation: Raft 1,966 M distinct states to depth 42 (527 M left on the queue); Copilot 2,170 M to depth 30 (727 M left); MongoDB (same-term commit rule) 1,097 M to depth 35 (344 M left); Mencius 209 M to depth 23 (77 M left). Logs `log/20261031_1600{40,41,45}_*_small.log`, `log/20261031_232140_*_small.log` |

`LogOrderMatchesExecution` deduplicates a committed sequence before comparing it with the
execution trace: a command may recur in a sequence (proposed at ack time and again inside a
Recovered entry, or by two proposers), and only its first occurrence executes.

Earlier results (the pre-pseudocode specifications, up to 2026-10-02) are in the older logs
and in the git history of this directory.
