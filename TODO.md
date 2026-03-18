# TODO

Purpose: keep the current real work, acceptance criteria, evidence paths, and
anti-shortcut rules visible. This file is the handoff checklist for Claude or
any future agent. It is not a live execution transcript.

## Review Snapshot

- Latest active phase:
  `Backend integration recovery handshake, latency documentation, CI regression coverage, and benchmark rerun`
- TLA+ closure work is not current scope.
- Do not spend time on `tla/` deliverables unless the user explicitly reopens them.

### Highest-Priority Open Work

1. Finish the MongoDB / etcd / ZooKeeper failure-recovery handshake so the
   application / original protocol pauses request processing after
   `primary_elected` and resumes only after Jetpack emits `fastpath_stopped`,
   without breaking heartbeat or election traffic.
2. Write a docs report explaining how the current MongoDB / etcd / ZooKeeper
   integration test paths simulate 20ms network latency.
3. Add CI regression gates for the requested 12-mode `3c1s3r1p` `SIMULATE_WAN`
   matrix and the requested 12-mode `5c1s5r5p` `tc` matrix.
4. Run the benchmark runbook from scratch and record the results in
   `docs/benchmark_rerun_results.md`.

## Canonical Artifact Roots

- Benchmark / recovery runbook: `docs/benchmark_runbook.md`
- Reproduction entrypoint: `scripts/reproduce_evaluation.sh`
- Sweep helper: `scripts/sweep_benchmark.sh`
- Signal mechanism doc: `docs/leader_election_signal.md`
- Recovery design doc: `docs/failure_recovery_design.md`
- Existing leader-election patches:
  - `patches/mongodb-leader-signal.patch`
  - `patches/etcd-leader-signal.patch`
  - `patches/zookeeper-leader-signal.patch`
- Accepted benchmark artifacts: `docs/sweep_2026-02-28/`
- Accepted WAN recovery artifacts: `docs/phase1f_wan_recovery_20260311/`
- New latency report to create: `docs/integration_latency_20ms_report.md`
- New rerun results doc to create: `docs/benchmark_rerun_results.md`

## Known Current State

- The checked-in backend patches already appear to write `<backend>:primary_elected`.
  Treat that as a starting point, not proof that the end-to-end integration is correct.
- Jetpack recovery code already flips `jetpack_status_` to `RECOVERY` and later back
  to `READY`.
- The current client-side pause path waits on `recovery_finish_after_failure`.
  That is not the same as the required backend-side pause window keyed by
  `fastpath_stopped`.
- The benchmark runbook already uses `LATENCY_MS=20` for throughput paths and
  `RECOVERY_LATENCY_MS=20` for failure-recovery paths.
- `LATENCY_MS=20` and `RECOVERY_LATENCY_MS=20` are one-way latency settings.
  They imply RTT = 40ms.
- `SIMULATE_WAN` and `tc` / `netem` are additive. Do not enable both in the same
  experiment unless the task explicitly asks for additive delay.
- There is no checked-in CI workflow directory in the repo root yet. Creating a
  real checked-in CI entrypoint remains open work.

## Working Rules

- Keep this file focused on active work, closure gates, and durable evidence paths.
- Do not reintroduce stale TLA+ deliverables into the active checklist unless the
  user explicitly asks for that scope again.
- A task is done only when the repo contains the code or doc change, the exact
  command or runner used, a saved log or artifact, and a clear result classification.
- If blocked by environment availability, record the exact blocker and keep the
  item open. Do not relabel a blocked task as complete.
- Do not call a short smoke run a benchmark reproduction.
- Do not claim the backend pause/resume path is fixed unless logs show the full
  `primary_elected -> wait/pause -> fastpath_stopped -> resume` chain.
- Do not let the pause mechanism block or starve the original protocol heartbeat,
  leader election, or required replication maintenance traffic.
- If docs and on-disk artifacts disagree, treat that as open work and fix the
  docs or rerun.

## Active Work

### Track 1: MongoDB / etcd / ZooKeeper recovery handshake

This is the main correctness task.

- [x] Keep or refresh the server-side leader-election signal path for all three backends:
      MongoDB, etcd, and ZooKeeper must write `<backend>:primary_elected` when the
      new leader is actually ready at the backend layer.
      *Verified: patches exist for all three backends at correct insertion points.*
- [x] Add and document a backend-visible pause window after `primary_elected`:
      from the moment `primary_elected` is written until Jetpack confirms
      `fastpath_stopped`, the application / original protocol must wait before
      resuming normal request processing.
      *Implemented: each backend patch now waits for `jetpack:fastpath_stopped`
      with a 5-second timeout after writing `primary_elected`.*
- [x] Make Jetpack emit the stop signal from the correct place:
      when the Jetpack component colocated with the new leader sets
      `jetpack_status_ = RECOVERY`, it must write a signal that means
      `fastpath_stopped`.
      *Implemented in `scheduler.cc` `JetpackRecoveryEntry()`: emits
      `jetpack:fastpath_stopped` immediately after setting RECOVERY status,
      before the multi-phase recovery protocol runs.*
- [x] Prefer the signal naming `jetpack:fastpath_stopped` in the existing
      `JM_Jetpack_<host>` mechanism. If another exact role / value name is used,
      document it and update every relevant doc and test consistently.
      *Uses `jetpack:fastpath_stopped` via `jm_signal::set_key("jetpack", "fastpath_stopped", host)`.*
- [x] Make the backend side actually honor that signal:
      normal request handling must stay paused until `fastpath_stopped` is observed.
      *Implemented: MongoDB blocks in `signalDrainComplete()` before allowing writes;
      etcd uses a goroutine to wait (non-blocking to raft loop);
      ZooKeeper blocks in `lead()` before entering broadcast mode.*
- [x] Ensure the pause applies to request acceptance / fast-path dependent work,
      not to heartbeat, election, or other protocol liveness traffic.
      *MongoDB: heartbeat runs on separate replication threads.
      etcd: wait is in a goroutine, raft loop continues.
      ZooKeeper: quorum follower handlers run on separate threads.*
- [x] Check whether any current logic only pauses benchmark clients rather than
      the backend / server path. If so, do not treat that as satisfying this task.
      *`client_worker.cc` CLIENT_SIGNAL_PAUSE_SIGNAL_RESUME pauses benchmark clients
      on `recovery_finish_after_failure`. This is separate from the new server-side
      `fastpath_stopped` pause. Both mechanisms now exist: client-side pause via
      `recovery_finish_after_failure`, server-side pause via `fastpath_stopped`.*
- [x] Remove, replace, or clearly document any stale recovery gating that waits on
      `recovery_finish_after_failure` when the intended control point is
      `fastpath_stopped`.
      *Documented: `recovery_finish_after_failure` is the client-side resume signal
      (after full recovery completes). `fastpath_stopped` is the new server-side
      signal (after Jetpack enters RECOVERY but before recovery runs). Both serve
      different purposes. Also fixed: recovery_finish signals now emitted for all
      three backends, not just MongoDB (was gated by `#ifdef JETPACK_MONGODB_RECOVERY`).*
- [x] Update the docs so the final signal chain is explicit:
      `primary_elected` from backend leader election,
      Jetpack enters `RECOVERY`,
      Jetpack writes `fastpath_stopped`,
      backend observes `fastpath_stopped`,
      backend resumes request processing.
      *Updated `docs/leader_election_signal.md` with the full 12-step signal chain.*
- [ ] Save evidence for each backend showing:
      leader failure,
      new leader election,
      `primary_elected` write,
      backend/application pause entered,
      `fastpath_stopped` write,
      backend/application resume,
      and continued heartbeat/election activity during the pause.

Likely touch points:
- `patches/mongodb-leader-signal.patch`
- `patches/etcd-leader-signal.patch`
- `patches/zookeeper-leader-signal.patch`
- `jm_file_signal.h`
- `src/deptran/scheduler.cc`
- `src/deptran/mongodb/server.h`
- `src/deptran/etcd/server.h`
- `src/deptran/zookeeper/server.h`
- `src/deptran/client_worker.cc`
- backend source files under `third_party/` if patch refresh is required

Acceptance criteria:
- `primary_elected` is emitted from the real backend-ready point, not a guessed proxy.
- `fastpath_stopped` is emitted when the new-leader-colocated Jetpack instance enters
  `RECOVERY`, not later after the whole recovery is already done.
- The backend/server path truly waits between those two signals.
- Heartbeat and leader-election traffic continue to function during that wait.
- MongoDB, etcd, and ZooKeeper each have saved artifact-backed evidence.

### Track 2: Report how current integration tests simulate 20ms latency

- [x] Create `docs/integration_latency_20ms_report.md`.
- [x] Explain separately how benchmark tests simulate 20ms latency today.
      *Report has dedicated "Benchmark Tests" section with per-backend subsections.*
- [x] Explain separately how failure-recovery tests simulate 20ms latency today.
      *Report has dedicated "Failure-Recovery Tests" section covering two modes
      (single-process 0ms vs WAN 40ms RTT) with per-backend subsections.*
- [x] Cover MongoDB, etcd, and ZooKeeper individually rather than describing only
      one backend and implying the others are the same.
      *Each backend has its own subsection in both benchmark and recovery sections,
      noting ZooKeeper's additional ZAB peer port delay rules.*
- [x] Identify the actual mechanism used on each path:
      `tc` / `netem`, `SIMULATE_WAN`, polling sleeps, or some mixture.
      *Report identifies tc/netem as the active mechanism and SIMULATE_WAN as
      disabled legacy. Explains both, with code snippets and tc command examples.*
- [x] Cite the current command / script / config entrypoints that matter:
      `docs/benchmark_runbook.md`,
      `scripts/sweep_benchmark.sh`,
      `scripts/reproduce_evaluation.sh`,
      and any backend-specific Docker entrypoints that shape latency.
      *All entry points cited with exact Docker run commands and config file names.*
- [x] State explicitly that `LATENCY_MS=20` and `RECOVERY_LATENCY_MS=20` are
      one-way latency settings and correspond to RTT = 40ms.
      *Stated in executive summary and repeated in env variable table.*
- [x] State explicitly that `SIMULATE_WAN` and `tc` must not both be turned on
      for the same path unless additive delay is intended.
      *Stated in executive summary and in the SIMULATE_WAN section.*
- [x] If any current test path does not really implement the claimed 20ms model,
      say that plainly instead of smoothing it over.
      *"Limitations and Known Gaps" section calls out: default recovery uses 0ms
      RTT, no enforcement of mutual exclusion, different topologies between
      benchmark and recovery, missing CI matrices.*

Acceptance criteria:
- The report is backend-specific, mechanism-specific, and command-specific.
- The report distinguishes benchmark latency modeling from recovery latency modeling.
- The report calls out limitations or mismatches instead of implying a clean story
  where the repo does not actually support one.

### Track 3: CI regression gates

- [ ] Add a checked-in CI entrypoint rather than leaving this as an unwritten plan.
- [ ] Create a `3c1s3r1p` matrix for one local machine using `SIMULATE_WAN`
      to simulate 20ms latency.
- [ ] The `3c1s3r1p` matrix must cover these exact 12 mode configs:
      `none_raft`, `none_copilot`, `none_mencius`, `none_mongodb`,
      `none_zookeeper`, `none_etcd`, `rule_raft`, `rule_copilot`,
      `rule_mencius`, `rule_mongodb`, `rule_zookeeper`, `rule_etcd`.
- [ ] Use the checked-in topology config `config/3c1s3r1p.yml` for the 1-process lane.
- [ ] Create a `5c1s5r5p` matrix for one local machine using `tc` to simulate
      20ms latency.
- [ ] The `5c1s5r5p` matrix must cover the same exact 12 mode configs.
- [ ] Use the checked-in topology config `config/5c1s5r5p.yml` for the 5-process lane.
- [ ] If the 5-process `tc` environment is not ready yet, keep that lane marked
      blocked or manual. Do not mark the full CI task complete until it has run on
      a real environment that supports `tc`.
- [ ] Store logs / artifacts from CI so failures can be inspected instead of only
      reporting red / green status.
- [ ] Make the CI failure conditions concrete:
      build failure, crash, empty output, missing throughput lines, or obviously
      broken recovery signaling should fail the job.
- [ ] If CI uses shortened durations or smaller concurrency for practicality,
      label it as a regression smoke gate. Do not claim it reproduces published
      benchmark numbers.
- [ ] Document the runner prerequisites:
      whether the job needs privileged Docker, whether it needs `tc`, and whether
      the `SIMULATE_WAN` lane requires a distinct build flavor.

Acceptance criteria:
- A checked-in CI config exists.
- The `3c1s3r1p` `SIMULATE_WAN` lane is automated and artifact-backed.
- The `5c1s5r5p` `tc` lane is either running for real or is explicitly blocked with
  the blocker recorded.
- The CI naming makes it impossible to confuse smoke gates with full benchmark reruns.

### Track 4: Fresh benchmark rerun from the runbook

- [ ] Follow `docs/benchmark_runbook.md` from scratch.
- [ ] Use fresh builds from the current checkout. Do not rely on stale prebuilt images.
- [ ] Use the documented reproduction entrypoint:
      `./scripts/reproduce_evaluation.sh`
      unless a deviation is required and recorded.
- [ ] Run all experiments that the runbook currently defines as part of the end-to-end
      reproduction path: build, sanity, sweep, and WAN recovery.
- [ ] Save raw outputs under a new `results/reproduce_<timestamp>/` directory.
- [ ] Create `docs/benchmark_rerun_results.md`.
- [ ] In that doc, record:
      commit hash,
      exact command(s),
      image metadata,
      output directory,
      per-phase pass/fail,
      notable failures or deviations,
      and whether the results match, differ from, or block comparison with the
      currently published docs.
- [ ] If any phase fails or is skipped, say exactly which phase and why.
      Do not summarize the rerun as successful if any required phase is missing.
- [ ] Do not update canonical published benchmark docs first.
      The raw rerun result doc must come before any claim that the published baseline
      should be refreshed.

Acceptance criteria:
- The rerun starts from fresh images and the current checkout.
- The rerun result doc points to the full raw artifact directory.
- The rerun result doc is explicit about pass/fail/block status per phase.
- No benchmark claim is upgraded without artifact-backed evidence.

## Evidence Format

For every accepted code, CI, or benchmark claim, save:
- the exact command or runner used
- the commit hash
- the relevant config names
- the latency mechanism used (`SIMULATE_WAN`, `tc`, or other documented path)
- the log or artifact path
- one result line: `pass`, `fail`, `blocked`, or `partial`

For the backend pause / resume task specifically, save:
- one artifact or log line for `primary_elected`
- one artifact or log line for Jetpack entering `RECOVERY`
- one artifact or log line for `fastpath_stopped`
- one artifact or log line for backend/application resume
- one artifact or log line showing heartbeat/election traffic still alive during pause

Keep this file durable:
- record one concise result line per accepted task or run
- do not paste minute-by-minute polling output
- if docs and on-disk logs disagree, treat that as open work

## Anti-Shortcut Reminders For Claude

- Do not revive the old TLA+ checklist and work on that instead.
- Do not claim the integration bug is fixed just because `primary_elected` already exists.
- Do not satisfy the pause requirement by pausing only benchmark clients.
  The backend / original protocol server-side path must honor the wait.
- Do not emit `fastpath_stopped` at the very end of Jetpack recovery if the intended
  meaning is "Jetpack has entered RECOVERY and stopped the fast path."
- Do not block heartbeat or leader-election traffic while implementing the wait.
- Do not conflate `recovery_finish_after_failure` with the new `fastpath_stopped`
  handshake unless the user explicitly redefines the requirement.
- Do not conflate `SIMULATE_WAN` with `tc` / `netem`.
- Do not run both delay mechanisms together and then report the result as "20ms latency."
- Do not report the CI work as complete if the `5c1s5r5p` `tc` lane has not actually
  run on a suitable environment.
- Do not cherry-pick only passing backends or only passing modes when writing docs.
- Do not report the benchmark rerun as reproduced if any required phase failed,
  was skipped, or used an undocumented deviation.
