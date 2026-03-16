# TODO

<!-- NOTE: The old doc/ folder has been merged into docs/. All documentation is now in docs/. -->

Purpose: keep current work, acceptance criteria, and evidence pointers visible. This file
should carry both the broader project big picture and the detailed active TLA+ closure
checklist. Do not use it as a live execution transcript.

## Review Snapshot

- Latest active phase: `Phase 2I: TLA+ decoupled composition and monolithic closure`

### Highest-Priority Open Work

1. Close the decoupled composition deliverables:
   `jetpack_raft_composition.tla`, `jetpack_copilot_composition.tla`,
   and `jetpack_mencius_composition.tla`.
2. Reconfirm that `base_raft.tla`, `base_copilot.tla`, and `base_mencius.tla`
   pass their own protocol-needed checks rather than relying only on wrapper results.
3. Recover or recreate the real monolithic deliverables:
   `jetpack_raft_monolithic.tla`, `jetpack_copilot_monolithic.tla`,
   and `jetpack_mencius_monolithic.tla`.
4. Keep docs aligned so future agents cannot cut corners on naming, cfg usage,
   runtime windows, or the 3-D log ownership rule.

### Current Phase Status

- Phase 0: done
- Phase 1: done for local Docker reproducibility
- Phase 1H remote validation: deferred until AWS / Zoo access returns
- Phase 2: active
- Phase 3: done
- Phase 4: done

### Canonical Artifact Roots

- Benchmark / recovery runbook: `docs/benchmark_runbook.md`
- Benchmark sweep artifacts: `docs/sweep_2026-02-28/`
- WAN recovery artifacts: `docs/phase1f_wan_recovery_20260311/`
- TLA design target: `tla/TLA_PLUS_BIG_PICTURE.md`
- TLA verification guide: `tla/VERIFICATION.md`
- TLA logs: `tla/log/`

## Working Rules

- Keep this file focused on active work, closure gates, and durable evidence paths.
- For long-running jobs, record only:
  1. launch command and log path,
  2. one health check,
  3. final outcome.
- Do not append minute-by-minute polling history here.
- A task is done only when the repo contains the code or doc change, the exact command or
  runner used, a saved log or artifact, and a clear result classification.
- If docs and on-disk artifacts disagree, treat that as open work and fix the docs or rerun.

## Project Big Picture

### Phase 0: Documentation Foundations

- [x] Documentation was consolidated under `docs/`
- [x] Leader-election signaling was documented
- [x] Jetpack pseudocode docs were refreshed and validated

### Phase 1: Evaluation Reproducibility

Local Docker reproducibility is complete. The canonical local evidence is:

- [x] Fresh-image build gate and build metadata capture
- [x] Runbook-backed low-concurrency sanity reruns
- [x] Fresh-image 9-case throughput sweep rerun
- [x] Runbook-backed 3-backend WAN recovery rerun
- [x] Published docs reconciled to accepted local artifacts
- [x] Codex-runnable end-to-end recipe in `docs/benchmark_runbook.md`

Primary evidence roots:

- `docs/sweep_2026-02-28/`
- `docs/phase1d_low_concurrency_runs.md`
- `docs/phase1f_wan_recovery_20260311/`
- `result.md`
- `docs/latency_analysis.md`
- `docs/failure_recovery_evaluation.md`

### Phase 1H: Deferred AWS / Zoo Automation Validation

Script refactoring and dry-run validation are complete, but real remote validation remains
deferred until AWS / Zoo access returns.

- [x] `scripts/experiment_defs.sh` centralized the experiment matrix
- [x] Legacy CLIs and naming were kept compatible
- [x] Dry-run / self-check support was added
- Deferred: remote cluster validation is still pending environment availability

### Phase 2: TLA+ Specifications and Verification

This is the active phase. The detailed closure checklist remains below.

### Phase 3: Jetpack + Industry Applications

Integration work is complete for the current scope.

- [x] MongoDB integration
- [x] etcd integration
- [x] ZooKeeper integration
- [x] Docker-based benchmark and recovery paths for all three backends

### Phase 4: Supporting Docs and Project Alignment

Supporting documentation and alignment work is complete.

- [x] Leader watcher analysis docs
- [x] TLA config alignment
- [x] README and operator docs refresh
- [x] TLA debugging / supporting notes

## Active TLA+ Closure Work

The active TLA+ goal is now split into two deliverable families:

- Part 1: standalone base protocols plus real monolithic Jetpack integrations
- Part 2: decoupled `base_*` + shared `jetpack.tla` + thin `*_composition.tla` wrappers

## Current Naming Status

- [x] Thin wrapper specs were renamed to:
  - `tla/jetpack_raft_composition.tla`
  - `tla/jetpack_copilot_composition.tla`
  - `tla/jetpack_mencius_composition.tla`
- [ ] Confirm that the separate monolithic integrated specs exist under:
  - `tla/jetpack_raft_monolithic.tla`
  - `tla/jetpack_copilot_monolithic.tla`
  - `tla/jetpack_mencius_monolithic.tla`
- [ ] If any monolithic file is missing, recover or recreate the real monolithic model.
      Do not satisfy this by copying or relabeling a `*_composition.tla` wrapper.

## Hard Rules

- Never modify `tla/raft.cfg`, `tla/copilot.cfg`, or `tla/mencius.cfg`.
- Use those three cfgs whenever the target base or base-adapted spec can consume them directly.
- Any Jetpack-specific cfg is an explicit exception only. If used for a finish run, it must
  preserve the same `Server`, `CmdId`, and `Key` cardinalities as the canonical base cfg.
- Before every TLC run, inspect system memory and cap TLC to at most one third of total RAM.
- A claimed pass requires a saved log, the exact spec name, the exact cfg name, the runtime,
  and the memory cap used.
- Debug or small runs do not satisfy the final finish bar unless the task explicitly says so.
- Historical logs that mention the old wrapper filenames are reference material only. They do
  not automatically close the renamed deliverables.

## Acceptance Matrix

### Prerequisite A: Standalone base protocols

- [ ] `tla/raft.tla` passes `CommittedLogAgreement`, `ElectionSafety`, and
      `LogOrderMatchesExecution` with immutable `tla/raft.cfg`.
- [ ] `tla/copilot.tla` passes `CommittedLogAgreement`, `ActiveProposerBound`, and
      `LogOrderMatchesExecution` with immutable `tla/copilot.cfg`.
- [ ] `tla/mencius.tla` passes `SlotAgreement`, `CommittedLogAgreement`, and
      `LogOrderMatchesExecution` with immutable `tla/mencius.cfg`.

### Prerequisite B: Decoupled base modules

- [ ] `tla/base_raft.tla` passes the Raft-side invariants needed for composition.
- [ ] `tla/base_copilot.tla` passes the CoPilot-side invariants needed for composition.
- [ ] `tla/base_mencius.tla` passes the Mencius-side invariants needed for composition.
- [ ] For these base-module runs, do not weaken the invariant set just because the
      composition wrappers are the current focus.

### Highest Priority: Composition Runs

Target runtime:
- 1 hour per spec

Required deliverables:
- [ ] `tla/jetpack_raft_composition.tla` passes a 1-hour bounded run.
- [ ] `tla/jetpack_copilot_composition.tla` passes a 1-hour bounded run.
- [ ] `tla/jetpack_mencius_composition.tla` passes a 1-hour bounded run.

Each composition pass must cover:
- [ ] the relevant base-protocol properties
- [ ] the Jetpack properties
- [ ] a thin wrapper only; no heavy protocol logic moved into `*_composition.tla`

Composition-specific guardrails:
- [ ] Keep `tla/jetpack_raft_composition.tla`, `tla/jetpack_copilot_composition.tla`, and
      `tla/jetpack_mencius_composition.tla` as glue modules only.
- [ ] Keep `tla/jetpack.tla` shared across all three compositions.
- [ ] Keep the base protocol as the owner of the real 3-D log `log[i][j][k]`.

### Lowest Priority: Monolithic Runs

Target runtime:
- 1 hour per spec

Required deliverables:
- [ ] `tla/jetpack_raft_monolithic.tla` exists as a real monolithic integration and passes a
      1-hour bounded run.
- [ ] `tla/jetpack_copilot_monolithic.tla` exists as a real monolithic integration and passes
      a 1-hour bounded run.
- [ ] `tla/jetpack_mencius_monolithic.tla` exists as a real monolithic integration and passes
      a 1-hour bounded run.

Monolithic-specific guardrails:
- [ ] Do not claim success by pointing at the composition wrappers.
- [ ] Do not relax the monolithic property set relative to the corresponding base protocol
      plus Jetpack expectations.

## Evidence Format

For every accepted run, save:
- the command or runner invocation
- the log path under `tla/log/`
- the spec filename
- the cfg filename
- the memory cap used
- one result line: `pass`, `fail`, `timeout-no-error`, or `crash`

Keep this file durable:
- record one concise result line per accepted run
- do not paste minute-by-minute polling output
- if docs and on-disk logs disagree, treat that as open work

## Anti-Shortcut Reminders For Claude

- Do not rename a composition wrapper to `*_monolithic.tla` unless its contents are actually
  monolithic.
- Do not merge Jetpack internals into `*_composition.tla` to make the wrapper "pass".
- Do not modify the immutable base cfg files.
- Do not shorten the 1-hour run window and then report the task as complete.
- Do not reduce the memory cap rule from one third of system RAM.
- Do not weaken invariants, constants, or state constraints just to get a clean run.
