# Jetpack + Mencius TLA+ Debug Report

## Summary

The `jetpack_mencius.tla` composition spec initially failed TLC model checking with
a Safety violation. The root cause was using `LogAgreement` (unrestricted log equality
across all servers at every index) instead of `CommittedLogAgreement` (log equality only
at committed indices). Mencius is a multi-leader protocol where servers independently
propose to their own round-robin slots, so uncommitted log entries legitimately diverge
across servers. The fix was to replace `LogAgreement` with `CommittedLogAgreement` in the
Safety property.

## Bug Discovery

### Failing run

- **Log file**: `tla/log/mencius_run.log`
- **Config**: `tla/jetpack_mencius.cfg` (5 servers, 3 CmdIds, 2 Keys, StateConstraint)
- **Date**: 2026-02-09 23:54 EST
- **Spec version**: commit `70f11721` (before the fix)
- **Result**: `Error: Invariant Safety is violated.` at depth 4 (4-state counterexample)

### Safety property at time of failure

```tla
Safety == [](LogAgreement /\ SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)
```

Where `LogAgreement == J!LogAgreement`, which checks:

```tla
LogAgreement ==
    \A i, j \in Server :
        \A k \in 1..MaxLogLen :
            \/ k > Len(log[i])
            \/ k > Len(log[j])
            \/ log[i][k] = log[j][k]
```

This requires that whenever two servers both have a log entry at index `k`, those
entries must be identical. This is correct for Raft (single leader) but not for Mencius.

## Counterexample Trace Analysis

TLC produced a 4-state counterexample:

### State 1 (Initial)

All 5 servers start as `Leader` (correct for Mencius multi-leader). All logs empty,
all slots Empty, commitIndex = 0 for all servers.

- `ostate = s1:Leader, s2:Leader, s3:Leader, s4:Leader, s5:Leader`
- `log = s1:<<>>, s2:<<>>, ..., s5:<<>>`
- Round-robin slot assignment: s1 owns slot 1, s2 owns slot 2, s3 owns slot 3, etc.

### State 2: Restart(s1)

Server s1 restarts, transitioning to `Follower`. No other state changes.

- `ostate[s1] = Follower` (was Leader)

### State 3: Suggest(s2, [cmd_id=id1, key=k1])

Server s2 proposes command `[cmd_id=id1, key=k1]` for slot 2 (s2's first owned slot).
s2 appends to its local log and sends SuggestRequest to all other servers.

- `log[s2] = <<[term=1, value=[cmd_id=id1, key=k1]]>>`
- `slotState[s2][2] = Proposed`
- `slotValue[s2][2] = [cmd_id=id1, key=k1]`
- `localIndex[s2] = 7` (next owned slot: 2 + 5 = 7)

### State 4: Suggest(s3, [cmd_id=id2, key=k1])

Server s3 proposes command `[cmd_id=id2, key=k1]` for slot 3 (s3's first owned slot).
s3 appends to its local log.

- `log[s3] = <<[term=1, value=[cmd_id=id2, key=k1]]>>`
- `slotState[s3][3] = Proposed`

### Violation

At State 4, `LogAgreement` fails because:
- `log[s2][1] = [term=1, value=[cmd_id=id1, key=k1]]`
- `log[s3][1] = [term=1, value=[cmd_id=id2, key=k1]]`
- Both servers have a log entry at index 1, but the entries differ (`id1` vs `id2`)

This is **correct Mencius behavior**: s2 and s3 proposed different commands to different
slots (slot 2 and slot 3), and each appended to position 1 of their own log. The logs
will eventually converge when committed entries are applied, but uncommitted entries can
legitimately differ.

## Root Cause

### Why LogAgreement is wrong for Mencius

In Raft, there is exactly one leader at a time, and the leader replicates its log to all
followers. Uncommitted entries may be overwritten by a new leader, but at any given term,
all servers with an entry at index `k` must have gotten it from the same leader, so they
agree on the value. Hence `LogAgreement` (unrestricted) holds for Raft.

In Mencius, **all servers are leaders** of their own round-robin slots. Server s2 proposes
to slot 2 and appends to `log[s2]`, while s3 proposes to slot 3 and appends to `log[s3]`.
These are independent proposals that haven't been replicated yet. The logs at index 1
contain different commands because they correspond to different Mencius slots.

Committed entries, however, must agree: once a slot value is learned by a majority and
committed, all servers that have committed up to that index must have the same log entries.

### Why it was masked with 1 CmdId

The bug was not caught during initial development because the `SmallStateConstraint` config
used only 1 CmdId (`{id1}`). With a single command ID, all proposals produce the same
command, so even divergent logs agree on values. When the config was expanded to 3 CmdIds
(`{id1, id2, id3}`) for the 5-server alignment, the divergence became visible.

## Fix

### Commit

`9952f714` — `[TLA+] Align CoPilot/Mencius configs to 5 servers, fix Mencius LogAgreement bug`

### Change

Replaced `LogAgreement` with `CommittedLogAgreement` in the Safety property:

**Before** (buggy):
```tla
LogAgreement == J!LogAgreement

Safety == [](LogAgreement /\ SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)
```

**After** (fixed):
```tla
CommittedLogAgreement ==
    \A i, j \in Server :
        LET ci == commitIndex[i]
            cj == commitIndex[j]
            limit == J!Min({ci, cj} \cup {0})
        IN \A k \in 1..limit :
            log[i][k] = log[j][k]

Safety == [](CommittedLogAgreement /\ SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)
```

`CommittedLogAgreement` only compares log entries up to `min(commitIndex[i], commitIndex[j])`,
which are entries that have been committed by the Mencius consensus protocol. Uncommitted
entries (which may diverge) are not compared.

## Verification Results

### Before fix (5 servers, 3 CmdIds)
- **mencius_run.log**: `Error: Invariant Safety is violated.` at depth 4 (immediate failure)

### After fix

| Config | Servers | CmdIds | Keys | States Generated | Distinct | Depth | Result |
|---|---|---|---|---:|---:|---:|---|
| SmallStateConstraint | 3 | 1 | 1 | 6.4M+ | 728K+ | 10 | No violations (partial) |
| SmallStateConstraint | 3 | 1 | 1 | 5.7M+ | 206K+ | 9 | No violations (partial, prior run) |
| StateConstraint | 5 | 3 | 2 | 14M+ | 1.9M+ | 10 | No violations (partial, prior run) |
| SmallStateConstraint | 3 | 1 | 1 | 37M+ | 3.6M+ | — | No violations (longest run, from TODO.md) |

The 3-server small config was re-verified (2026-02-16) with 6.4M+ states explored and no
violations. The state space is too large for exhaustive checking (the queue keeps growing),
but the partial verification with millions of states strongly suggests the fix is correct.

## Broader Pattern

This same issue — `LogAgreement` vs `CommittedLogAgreement` — applies to all multi-leader
or multi-proposer protocols:

| Protocol | Leaders | LogAgreement | CommittedLogAgreement |
|---|---|---|---|
| Raft | 1 leader | Holds | Holds |
| CoPilot | 2 proposers | Does NOT hold | Holds |
| Mencius | N leaders (round-robin) | Does NOT hold | Holds |

The standalone `mencius.tla` and `copilot.tla` already use `CommittedLogAgreement` in their
Safety properties. The bug was in the composed `jetpack_mencius.tla` wrapper, which initially
copied the `LogAgreement` property from `jetpack_raft.tla` without adapting it for Mencius.

## Key Files

- `tla/jetpack_mencius.tla` — composed Jetpack + Mencius spec (fixed)
- `tla/jetpack_mencius.cfg` — 5-server config for model checking
- `tla/jetpack_mencius_small.cfg` — 3-server config for quick verification
- `tla/mencius.tla` — standalone Mencius spec (uses CommittedLogAgreement, correct)
- `tla/jetpack.tla` — Jetpack plugin module (defines LogAgreement, CommittedLogAgreement helpers)
- `tla/log/mencius_run.log` — counterexample trace (pre-fix, 5 servers, LogAgreement violation)
- `tla/log/mencius_3server_test.log` — partial verification (post-fix, 3 servers, no violations)
- `tla/log/mencius_5server_fixed.log` — partial verification (post-fix, 5 servers, no violations)
