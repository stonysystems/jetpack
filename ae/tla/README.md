# TLA+ specs — how to run

Four Jetpack composition specs live here:

| Composition | Base protocol | Proposers | Reconfig? |
|---|---|---|---|
| `jetpack_raft_composition.tla`     | Raft (Vanlightly add/remove)   | 1 (`"sole"`)        | ✅ Add + Remove via Jetpack-recovery-gated two-step |
| `jetpack_copilot_composition.tla`  | CoPilot                        | 2 (pilot + copilot) | ⚠️ **Empty view change only** (no real membership change — see below) |
| `jetpack_mencius_composition.tla`  | Mencius                        | N (one per server)  | ⚠️ **Empty view change only** (no real membership change — see below) |
| `jetpack_mongodb_composition.tla`  | MongoDB-flavored Raft          | 1 (`"sole"`)        | ✅ Single-server Add/Remove (Raft-style), routed through Jetpack recovery |

> ### ⚠️ Why CoPilot and Mencius have only an "empty" reconfig
>
> Membership reconfiguration is outside the scope of the original CoPilot
> and Mencius papers, which focus on the steady-state protocol; we are also
> not aware of a publicly available TLA+ specification of reconfig for
> either one that we could vendor or port. To still exercise the Jetpack
> recovery path on these compositions, each base spec defines an
> `EmptyViewChange(i)` action ([base_copilot.tla:317](base_copilot.tla#L317),
> [base_mencius.tla:432](base_mencius.tla#L432)) that bumps the term and
> forces `ostate[i] := ToBeLeader` **without** mutating any membership state
> at the base-protocol layer. From the composition's view this looks
> identical to an election — Jetpack recovery fires (`SendBeginRecovery → …
> → FinishRecovery`) and ostate flips back to `Leader`. So Jetpack's
> recovery-on-reconfig logic is covered here, while the base-protocol
> reconfig itself is left as a placeholder rather than a faithful
> implementation.
>
> CoPilot's variant is restricted to `role[i] ∈ {Pilot, Copilot}` so the
> pilot/copilot swap preserves the 2-proposer invariant
> (`ActiveProposerBound`); promoting an Acceptor would yield three
> proposers. Mencius's variant has no such restriction.
>
> By contrast, Raft and MongoDB carry **real** membership change (add /
> remove) at the base-protocol layer — see below.

All four are checked against the shared Jetpack safety properties
(`CommittedLogAgreement`, `LogOrderMatchesExecution`, `ExecutionDedupMatches`,
plus `MultiSequenceLogAgreement` on the multi-proposer specs). The Raft and
MongoDB compositions additionally exercise real membership change:

- **Raft:** adds `NoLogDivergence` and `MaxOneReconfigurationAtATime`
  (declared in the spec, asserted via `INVARIANTS` in the `.cfg`).
- **MongoDB:** reconfig fires through `BeginReconfig` + composition-level
  `WFinishReconfig`. Recovery runs in the OLD config; the new config entry is
  appended atomically when ostate flips `ToBeLeader → Leader`. Each reconfig
  is a single-server add or remove gated on `PrevConfigCommitted` +
  `SomeEntryCommittedInCurrentTerm`. `Len(configs) <= 2` in the spec's
  `StateConstraint` caps the run to one reconfig.

## Prereqs

- `tla/tla2tools.jar` (v1.7.1, Java 8 compatible). Re-fetch with:
  ```bash
  wget -O tla/tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar
  ```
- `java` on `$PATH`. **64-bit Java strongly preferred** — 32-bit caps the JVM heap at ~1.4 GB regardless of `TLC_MEMORY_MB`. Large configs will explore very slowly under that cap.

## Quickstart

Always run from the **repo root** (`/home/users/ztang/janus`). The runner script resolves paths relative to that.

### Small (quick exhaustive — finishes in seconds to minutes)

```bash
bash tla/run-tlc.sh jetpack_raft_composition.tla    small
bash tla/run-tlc.sh jetpack_copilot_composition.tla small
bash tla/run-tlc.sh jetpack_mencius_composition.tla small
bash tla/run-tlc.sh jetpack_mongodb_composition.tla tla/jetpack_mongodb_small.cfg
```

`small` resolves to `<spec>_small.cfg` for raft / copilot / mencius (e.g.
`tla/jetpack_raft_small.cfg`). The `small` alias is **not wired up for the
MongoDB composition** in `run-tlc.sh` yet, so pass the cfg path explicitly.
Use these to confirm a spec is healthy after edits.

### Large (full-coverage run — may not terminate; safe to interrupt)

```bash
bash tla/run-tlc.sh jetpack_raft_composition.tla    tla/jetpack_raft_large.cfg
bash tla/run-tlc.sh jetpack_copilot_composition.tla tla/large.cfg
bash tla/run-tlc.sh jetpack_mencius_composition.tla tla/large.cfg
bash tla/run-tlc.sh jetpack_mongodb_composition.tla tla/large.cfg
```

**Why Raft uses a separate `_large.cfg`:** the Raft composition needs reconfig
constants (`InitialMembers`, `MinClusterSize`, `MaxClusterSize`, `MaxElections`,
`MaxRestarts`, `MaxAddReconfigs`, `MaxRemoveReconfigs`, `IncludeThesisBug`)
that the shared `tla/large.cfg` doesn't carry. It also drops `SYMMETRY` —
member set is dynamic and `InitialMembers` is a strict subset of `Server`, so
`Permutations(Server)` is unsafe. The other three compositions reuse
`tla/large.cfg` directly: copilot and mencius have static membership;
MongoDB's reconfig knobs (single-server change, gated on previous-config-
commit) are baked into the spec rather than exposed as `CONSTANTS`, and its
initial config is `Server` itself, so `Permutations(Server)` remains sound.

## Pinning CPU + capping memory

```bash
TLC_CPUSET=65-96  TLC_MEMORY_MB=40000 \
    bash tla/run-tlc.sh jetpack_raft_composition.tla    tla/jetpack_raft_large.cfg

TLC_CPUSET=97-128 TLC_MEMORY_MB=40000 \
    bash tla/run-tlc.sh jetpack_mongodb_composition.tla tla/large.cfg
```

Linux `taskset` is **0-indexed**; on a 128-core box valid range is `0-127`. If
a CPU-set value gets rejected, drop each end of the range by 1.

To run all four in parallel with disjoint CPU sets, see [RUNBOOK.md](RUNBOOK.md).

## Logs

Every run auto-saves a timestamped log to `tla/log/`:
```
tla/log/<YYYYMMDD_HHMMSS>_<spec>[_<config_label>].log
```
The runner prints the exact path on its last line. To also redirect a copy
to a predictable filename for `tail -f`:

```bash
bash tla/run-tlc.sh jetpack_raft_composition.tla tla/jetpack_raft_large.cfg \
  2>&1 | tee tla/log/jetpack_raft_large.log
```

## Config files

**Primary configs — these are the ones you actually run:**

| File | Used by | Purpose |
|---|---|---|
| `tla/large.cfg`              | copilot / mencius / mongodb  | 5 servers / 3 clients / 3 cmds / 2 keys, `SYMMETRY` on. The shared full-coverage config for the three statically-/symmetric-membership specs. |
| `tla/jetpack_raft_large.cfg` | Raft only                    | Same dimensions as `large.cfg`, plus the reconfig constants (`InitialMembers`, `MinClusterSize`, `MaxClusterSize`, `MaxElections`, `MaxRestarts`, `MaxAddReconfigs`, `MaxRemoveReconfigs`, `IncludeThesisBug`); `SYMMETRY` dropped because `InitialMembers ⊊ Server`. |

<details>
<summary>Secondary / legacy configs (rarely needed)</summary>

| File | Used by | Purpose |
|---|---|---|
| `tla/jetpack_<spec>_small.cfg`  | raft / copilot / mencius (`small` keyword) | 3 servers, tiny bounds — quick sanity check after editing a spec, finishes in seconds. |
| `tla/jetpack_mongodb_small.cfg` | MongoDB (pass cfg path explicitly)         | Same role as the others' `_small.cfg`; `Len(configs) <= 2` (one reconfig allowed). |
| `tla/jetpack_raft.cfg`          | Raft (legacy default)                      | 5 servers, narrower than `_large` (1 client, 2 keys). Pre-dates `_large`; kept for the legacy default path. |
| `tla/raft.cfg`                  | standalone vendored `tla/raft.tla`         | Vanlightly's upstream cfg + `MaxClusterSize`. Only for the no-Jetpack standalone Raft spec. |

</details>

To shrink Raft's reconfig state space for a given run, edit
`MaxAddReconfigs` / `MaxRemoveReconfigs` down to 0 in
`tla/jetpack_raft_large.cfg` (state-space drops by ~10× per knob). MongoDB's
reconfig budget is controlled instead by the `Len(configs) <= N` clause in
`StateConstraint` / `SmallStateConstraint` inside
`jetpack_mongodb_composition.tla` (default cap = 2, i.e. one reconfig).

## Standalone Raft spec (no Jetpack)

[`tla/raft.tla`](raft.tla) is the upstream Vanlightly
`RaftWithReconfigAddRemove.tla` vendored verbatim (only the MODULE name was
changed). Useful to verify a Raft-layer fix in isolation before testing it
through the Jetpack composition:

```bash
bash tla/run-tlc.sh raft.tla
```

The legacy Ongaro-derived spec lives at [`tla/raft_ongaro.tla`](raft_ongaro.tla),
and the previous (no-reconfig) Jetpack-Raft files are preserved under
[`tla/archive/`](archive/).

## See also

- [TLA_PLUS_BIG_PICTURE.md](TLA_PLUS_BIG_PICTURE.md) — module architecture and the 3-D log convention
- [VERIFICATION.md](VERIFICATION.md) — what each spec verifies
- [RUNBOOK.md](RUNBOOK.md) — running all four compositions in parallel on a 128-core host
