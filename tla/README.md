# TLA+ specs — how to run

Four Jetpack composition specs live here:

| Composition | Base protocol | Proposers | Reconfig? |
|---|---|---|---|
| `jetpack_raft_composition.tla`     | Raft (Vanlightly add/remove)   | 1 (`"sole"`)        | ✅ Add + Remove via Jetpack-recovery-gated two-step |
| `jetpack_copilot_composition.tla`  | CoPilot                        | 2 (pilot + copilot) | ⚠️ **Empty view change only** (no real membership change — see below) |
| `jetpack_mencius_composition.tla`  | Mencius                        | N (one per server)  | ⚠️ **Empty view change only** (no real membership change — see below) |
| `jetpack_mongodb_composition.tla`  | MongoDB-flavored Raft          | 1 (`"sole"`)        | ✅ Single-server Add/Remove (Raft-style), routed through Jetpack recovery |

Each composition extends or instances exactly one `base_*` module
(`base_raft.tla`, `base_copilot.tla`, `base_mencius.tla`, `base_mongodb.tla`)
and the shared Jetpack core `jetpack.tla`, then does only the glue needed to
wire `Init`, `Next`, `Spec`, `Safety`, `UNCHANGED`, and any protocol-specific
execution-ordering helper such as `ApplyCommitted`.

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
> remove) at the base-protocol layer — see the per-composition rows below.

## Verified properties

Shared invariants checked by all four compositions (`Safety = [](…)`):

- **CommittedLogAgreement** — all servers agree on committed log entries.
- **LogOrderMatchesExecution** — execution order matches log commitment
  order (the TLA+ form of PR1 from the paper).
- **ExecutionDedupMatches** — the deduplicated execution trace is consistent
  across the fast path and the original path.

Per-composition additions inside `Safety`:

| Composition | Additional invariants |
|---|---|
| Raft     | `NoLogDivergence`, `MaxOneReconfigurationAtATime` (reconfig invariants); `LogOrderMatchesExecution` is overridden to filter out config entries |
| CoPilot  | `MultiSequenceLogAgreement`, `ActiveProposerBound` (≤ 2 active proposers) |
| Mencius  | `MultiSequenceLogAgreement`, `SlotAgreement` (all servers agree on learned/skipped slot values) |
| MongoDB  | `MultiSequenceLogAgreement`; reconfig itself fires through `BeginReconfig` + composition-level `WFinishReconfig`. Recovery runs in the OLD config; the new config entry is appended atomically when ostate flips `ToBeLeader → Leader`. Each reconfig is a single-server add/remove gated on `PrevConfigCommitted + SomeEntryCommittedInCurrentTerm`. `Len(configs) ≤ 2` in `StateConstraint` caps the run to one reconfig. |

## Architecture: the base protocol owns the 3-D log

The shared log shape is `log[i][j][k]`:

- `i`: replica storing the copy
- `j`: logical proposer or sequence owner
- `k`: position inside that sequence

So `log[i][i][k]` is replica `i`'s own logical sequence, and `log[i][j][k]`
for `i ≠ j` is replica `i`'s copy of proposer `j`'s sequence.

Per-protocol interpretation:
- Raft: one active logical sequence
- CoPilot: two active logical sequences (pilot + copilot)
- Mencius: one logical sequence per server
- MongoDB: one active logical sequence (Raft-style)

The base protocol must adapt upward to Jetpack — each `base_*` module
maintains a genuine 3-D log in its TLA+ state, and `jetpack.tla` consumes
that interface directly. Acceptable: extra internal helper state, thin
wiring in the composition wrapper, unused logical sequences left as `Nil`.
Not acceptable: keeping a flatter base log and reconstructing `j` or local
`k` in `jetpack.tla`, projection operators that fake a 3-D interface from
a 2-D state, or moving heavy protocol logic into the `*_composition.tla`
wrappers.

## Prereqs

- `tla/tla2tools.jar` (v1.7.1, Java 8 compatible). Re-fetch with:
  ```bash
  wget -O tla/tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.7.1/tla2tools.jar
  ```
- `java` on `$PATH`. **64-bit Java strongly preferred** — 32-bit caps the JVM heap at ~1.4 GB regardless of `TLC_MEMORY_MB`. Large configs will explore very slowly under that cap.

`tla/run-tlc.sh` enforces the repository memory policy automatically: it
detects total system memory (or the active cgroup/container limit if
smaller) and caps TLC to at most one third of that total — applied as a JVM
heap cap (`-Xmx`) in local mode, and as both container limits
(`--memory` / `--memory-swap`) and the same JVM heap cap via
`JAVA_TOOL_OPTIONS` in Docker mode. The runner logs the detected total,
the one-third cap, the configured cap, the enforced cap after any 32-bit
JVM clamp, and the final JVM heap cap. Optional lower overrides:

```bash
TLC_MEMORY_MB=8192                   bash tla/run-tlc.sh jetpack_raft_composition.tla    # lower the total budget
TLC_MEMORY_MB=8192 TLC_HEAP_MB=7168  bash tla/run-tlc.sh jetpack_raft_composition.tla    # lower only the JVM heap
```

The runner rejects values above the automatic one-third cap. The runner
auto-detects local vs Docker mode; override with `TLC_MODE=docker` or
`TLC_MODE=local`.

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

## Current verification status

Bounded BFS runs of each composition on its full-coverage config. No safety
violations have been observed in any run. CoPilot and Mencius completed in
the 2026-04-21 batch; Raft and MongoDB are still being explored under a
re-launched 2026-05-07 run, with the latest snapshot captured below.

| Spec | Config | Status | Depth (BFS) | States generated | Distinct states |
|---|---|---|---:|---:|---:|
| `jetpack_raft_composition.tla`    | `jetpack_raft_large.cfg` | in progress (snapshot 2026-05-13) | 12 | 4.22 B | 894 M |
| `jetpack_copilot_composition.tla` | `large.cfg`              | completed 2026-04-22 | 17 | 1.76 B | 149 M |
| `jetpack_mencius_composition.tla` | `large.cfg`              | completed 2026-04-22 | 11 |  611 M |  32 M |
| `jetpack_mongodb_composition.tla` | `large.cfg`              | in progress (snapshot 2026-05-13) | 15 | 1.89 B | 138 M |
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

A small-config exhaustive baseline from 2026-03-08 is also on file (Raft
82 K / 6 K exhaustive, CoPilot 515 / 70 exhaustive, Mencius 598 M / 56 M at
34 h before OOM) — useful as a quick sanity reference but superseded by the
large-config evidence above for acceptance.

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

## What counts as a finished run

A claimed-finished run satisfies all of the following:
- the spec filename matches one of the four composition wrappers
- the relevant invariants are enabled in `Safety` (see the per-composition
  table above)
- the run uses the canonical cfg (`large.cfg` or `jetpack_raft_large.cfg`)
  or an explicitly justified exception cfg
- the run respects the recorded time / depth window (do not silently shorten
  it; do not weaken the config to make it fit)
- the run respects the one-third-memory cap
- the log is saved under `tla/log/` and summarized with spec, cfg, memory
  cap, and outcome

The composition track is finished when each of the four `base_*.tla` modules
passes its own protocol-needed checks, and each of the four
`jetpack_<proto>_composition.tla` wrappers passes both the base and Jetpack
properties — with the wrappers remaining thin glue modules. The current
snapshot in the verification-status table above is the standing finish
evidence.

**Anti-shortcuts.** Do not claim the goal is done merely because `base_*`
and `jetpack.tla` exist. Do not move base-protocol or Jetpack core logic
into `*_composition.tla` just to make the composition pass. Do not weaken
invariants, reduce constants, or use a debug cfg for a claimed finish run
unless the exception is explicit and approved. Do not rely on legacy logs
under the pre-rename filenames as final evidence without clearly mapping
them to the current `*_composition.tla` filenames.

## See also

- [RUNBOOK.md](RUNBOOK.md) — running all four compositions in parallel on a 128-core host
