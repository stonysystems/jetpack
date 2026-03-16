# TODO

<!-- NOTE: The old doc/ folder has been merged into docs/. All documentation is now in docs/. -->

Purpose: keep current work, acceptance criteria, and evidence pointers visible. Do not use
this file as a live execution transcript.

## Review Snapshot

- Latest active phase: `Phase 2I: TLA+ 3-D base-log verification`

### Highest-Priority Open Work

1. Re-establish accepted big-run evidence for `jetpack_raft.tla` and `jetpack_mencius.tla`.
   Current repo state has the accepted `jetpack_copilot.tla` big-run logs on disk, but
   `tla/VERIFICATION.md` still references timestamped Raft big-run artifacts that are not
   present under `tla/log/`, and Mencius big-run evidence is still open.
2. Update `tla/VERIFICATION.md` and this TODO from the actual on-disk evidence only.
3. Close Phase 2I only after all three Jetpack/base combinations have accepted small and
   12-hour big timestamped logs plus aligned docs.

### Current Phase Status

- Phase 0: done
- Phase 1: done for local Docker reproducibility
- Phase 1H remote validation: deferred until AWS / Zoo access returns
- Phase 2: open only on final big-run evidence / closure
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
- A task is done only when the repo contains the code/doc change, the exact command or runner
  used, a saved log or artifact, and a clear result classification.
- If docs and on-disk artifacts disagree, treat that as open work and fix the docs or rerun.

## Goal

Jetpack is a plugin consensus protocol layered on top of a base protocol. The TLA+ end goal is
one shared `jetpack.tla` composed with protocol-specific base modules that expose a real
Jetpack-facing 3-D log `log[i][j][k]`:

- `i`: replica storing the copy
- `j`: logical proposer / sequence
- `k`: position inside that proposer's sequence

The accepted proof story is:

- the base protocol owns the 3-D log
- `jetpack.tla` consumes that 3-D interface directly
- wrappers stay thin and do wiring only

## Phase 0: Documentation Foundations

- [x] Documentation was consolidated under `docs/`
- [x] Leader-election signaling was documented
- [x] Jetpack pseudocode docs were refreshed and validated

## Phase 1: Evaluation Reproducibility

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

## Phase 2: TLA+ Specifications and Verification

### Accepted Phase 2I Constraints

- The base protocol owns the real 3-D log.
- `jetpack.tla` must not reconstruct the proposer dimension from a flatter log.
- Accepted big config is fixed at:
  - 5 servers
  - 1 client
  - 3 commands
  - 2 keys
- Accepted big evidence is a 12-hour bounded run with a timestamp-prefixed log in `tla/log/`.

### Completed Core Refactor

- [x] `tla/TLA_PLUS_BIG_PICTURE.md` explicitly rejects the projection shortcut
- [x] `base_raft.tla`, `base_copilot.tla`, and `base_mencius.tla` now expose real 3-D log state
- [x] `jetpack.tla` consumes the shared 3-D interface directly
- [x] Wrappers remain thin composition drivers
- [x] `tla/run-tlc.sh` saves timestamp-prefixed logs and supports local Java or Docker
- [x] `tla/VERIFICATION.md` documents the reproducible workflow

### Current Verification Evidence

Small-config evidence on disk:

- [x] `tla/log/20260308_101528_jetpack_raft_small.log`
- [x] `tla/log/20260308_101541_jetpack_copilot_small.log`
- [x] `tla/log/20260308_101553_jetpack_mencius_small.log`

Big-config evidence currently on disk:

- [x] `tla/log/20260311_102514_jetpack_copilot.log`
- [x] `tla/log/20260311_102513_jetpack_copilot_big_launcher.log`
- Missing on disk: timestamped accepted `jetpack_raft.tla` big-run artifacts under `tla/log/`
- Missing on disk: timestamped accepted `jetpack_mencius.tla` big-run artifacts under `tla/log/`

### Open Work

- [ ] Re-run or restore the accepted 12-hour big-config evidence for `jetpack_raft.tla`,
      then update `tla/VERIFICATION.md` and this TODO to match what is actually on disk.
- [ ] Run the accepted 12-hour big-config verification for `jetpack_mencius.tla`,
      save timestamp-prefixed logs under `tla/log/`, and update `tla/VERIFICATION.md`.
- [ ] Consolidate the three big-run outcomes in `tla/VERIFICATION.md` and this TODO with
      one concise result line per spec instead of polling history.
- [ ] Do not close Phase 2I until all of the following are true:
  - `tla/TLA_PLUS_BIG_PICTURE.md` clearly states that the base protocol owns the 3-D log
  - `jetpack.tla` no longer depends on a projection from a 2-D base log
  - `base_raft.tla`, `base_copilot.tla`, and `base_mencius.tla` expose a real
    Jetpack-facing `log[i][j][k]`
  - all three Jetpack/base combinations have one accepted small run with saved log
  - all three Jetpack/base combinations have one accepted 12-hour big run with saved log
  - every accepted log filename starts with the run timestamp
  - `tla/VERIFICATION.md` and this TODO agree with the on-disk artifacts

## Phase 3: Jetpack + Industry Applications

Integration work is complete for the current scope.

- [x] MongoDB integration
- [x] etcd integration
- [x] ZooKeeper integration
- [x] Docker-based benchmark and recovery paths for all three backends

## Phase 4: Supporting Docs and Project Alignment

Supporting documentation and alignment work is complete.

- [x] Leader watcher analysis docs
- [x] TLA config alignment
- [x] README and operator docs refresh
- [x] TLA debugging / supporting notes
