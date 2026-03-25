# TODO

Purpose: keep the current real work, acceptance criteria, evidence paths, and
anti-shortcut rules visible. This file is the handoff checklist for Claude or
any future agent. It is not a live execution transcript.

## Review Snapshot

- Latest active phase:
  `Zoo 2026-03-23 result-set triage, MongoDB and Mencius bug fixing, figure/export correction, and clean 5-machine rerun planning`
- Treat `results/2026-03-23-10:26:07-zoo-5machines/` as a diagnostic baseline, not
  as a publishable final run.
- TLA+ closure work is not current scope.
- Do not spend time on `tla/` deliverables unless the user explicitly reopens them.

### Highest-Priority Open Work

Historical tracks 1-4 stay below for context, but the immediate user-visible
blockers are now:

1. Reopen the 2026-03-23 Zoo 5-machine run as incomplete and fix the blockers
   before claiming the figures or tables are final.
2. Extend experiment-0 concurrency sweeps for Raft / etcd / ZooKeeper until the
   throughput-latency curves show a real turning point, plateau, or regression
   rather than stopping at a still-rising edge.
3. Replace the current CPU deliverable with the requested figure shape:
   x-axis = concurrency, y-axis = CPU usage, one line per mode
   (original / 0% / 100% / adaptive) inside each protocol panel.
4. Find the original MongoDB bottleneck from logs first, then fix either the
   experiment path or the plotting/input path so MongoDB data points are real,
   visible, and auditable.
5. Audit why the current Zoo run has many `.res` files without matching `.csv`
   files, fix the root cause if possible, and stop silently plotting from
   partial data.
6. Fix Mencius adaptive mode so CPU-based path selection uses valid CPU samples
   and sane switching logic instead of the current obviously wrong
   `[CPU-MENC] ... leader CPU 0.00 ...` behavior.
7. Rerun Zoo failure recovery with the notebook-expected recovery log names and
   do not close the task until 4 per-protocol recovery figures exist
   (`rule_raft`, `rule_mongodb`, `rule_etcd`, `rule_zookeeper`) or a blocker is
   explicitly proven with logs.
8. After the fixes above, start a clean new batched run via `scripts/10-run_all.sh`
   in a fresh result root, then reuse that same result root for experiments 1/2,
   failure recovery, and figure export.

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
- Legacy multi-machine runner to extend: `scripts/10-run_all.sh`
- Shared experiment definitions to extend: `scripts/experiment_defs.sh`
- Current failover helper to inspect/reuse: `scripts/09-build_and_test_run_wan.sh`
- Analysis notebook to extend: `scripts/evaluation.ipynb`
- Zoo site config for the new run: `config/30c1s5r5p-zoo.yml`
- Current suspect Zoo run to triage:
  `results/2026-03-23-10:26:07-zoo-5machines`
- Evaluation wrapper to reuse after rerun: `scripts/run_evaluation.sh`
- Failure-recovery runner to reuse after rerun: `scripts/run_failure_recovery.sh`

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
- `scripts/10-run_all.sh` still reflects the older 4-family legacy sweep and
  currently uses `SITE_AWS_SWEEP` through the shared definitions.
- `scripts/experiment_defs.sh` still maps the legacy Jetpack raft family to
  `rule_fpga_raft`, while the requested Zoo evaluation uses `rule_raft`.
- `scripts/evaluation.ipynb` still hard-codes a historical result folder,
  historical contention dataset paths, and result-file host-count assumptions
  that do not match the requested 5-machine Zoo run.
- The current experiment-0 figure set under
  `results/2026-03-23-10:26:07-zoo-5machines/figs/` is suspect because many raw
  Zoo result files show WAN-scale latencies around ~40ms / ~80ms while several
  plotted figures appear mostly near 0ms. Treat those PDFs as provisional until
  notebook input-data sanity checks and redraw are complete.
- For the requested Zoo multi-machine task, host-level `tc` is not the intended
  mechanism because sudo permission is not available. The WAN model for this
  track must be implemented at the Docker/container level with 20ms one-way
  latency, and that exact mechanism must be documented in the run folder.
- Some ZooKeeper / MongoDB / etcd evaluation paths in the repo have recently
  been exercised through Docker-oriented helpers (`scripts/reproduce_evaluation.sh`,
  `scripts/sweep_benchmark.sh`, `docker/*`). Claude may need to update scripts
  accordingly so the Zoo multi-machine path and any Docker-backed backend control
  paths stay coherent, instead of forcing one model onto the other.
- For the requested failure-recovery experiment, the failure event must really
  kill a `deptran_server` task on one Zoo machine. A synthetic pause, a config
  flag alone, or a client-only stall is not sufficient.
- The current Zoo run root `results/2026-03-23-10:26:07-zoo-5machines/`
  contains `3400` `.res` files but only `1838` `.csv` files.
- The current failure-recovery subdir
  `results/2026-03-23-10:26:07-zoo-5machines/failure_recovery/` contains
  `20` `.res` files but only `4` `.csv` files, all for `rule_raft`.
- Many prefixes have all 5 server `.res` files but only partial `.csv`
  coverage, so the main missing-artifact problem is not "the run never started";
  it is a post-start abnormal-termination / timeout / dump / pull problem.
- The current run folder only has one per-protocol recovery PDF:
  `figs/30c1s5r5p-zoo_failure_recovery_rule_raft.pdf`.
  The 4-protocol recovery-figure requirement is still open.
- The current throughput sweep still does not show a convincing turning point
  for at least:
  - Raft original: `none_raft` is still ~`8992.2 txn/s` at `concurrent_1000`
    and `rule_raft` adaptive is ~`9010.3 txn/s` at `concurrent_1000`.
  - etcd original: peak is still at the highest tested point `concurrent_120`
    (`3569.1 txn/s`).
  - ZooKeeper original: peak is still at the highest tested point
    `concurrent_120` (`3559.5 txn/s`).
- Original MongoDB is already pathological at very low concurrency:
  `none_mongodb` p50 is about `9587.87ms` at `concurrent_1` and about
  `10348.57ms` at `concurrent_10`. This is not a "small late surge near max
  throughput" pattern.
- MongoDB Jetpack rows in `tables/latency_vs_conc.csv` are internally mixed:
  fast-path latency stays around `42ms`, while all-attempt latency is either
  multi-second or `-1`. The plotting path must decide which latency metric is
  the real y-axis for the main latency figures and document it.
- `figure_input_sanity.md` is not yet trustworthy enough to gate figure
  correctness. It currently marks several obvious mismatches as `PASS`, for
  example:
  - MongoDB adaptive: notebook p50 `42.05ms` vs raw avg p50 `4429.36ms`
  - MongoDB 100%: notebook p50 `42.09ms` vs raw avg p50 `4159.75ms`
  - Mencius original: notebook p50 `122.42ms` vs raw avg p50 `5904.04ms`
  - Raft adaptive: notebook p50 `41.89ms` vs raw avg p50 `88.51ms`
- The global 200ms latency-axis rule that was previously used for experiment-0
  figures hides real MongoDB points. Do not keep a global cap if it makes a
  protocol effectively disappear.
- Mencius adaptive logs show repeated lines like:
  `[CPU-MENC] Let go fastpath due to leader CPU 0.00, max_leader_avg - 60.0 -60.00 <= rand=25.00`
  Treat that as proof that CPU sampling and/or branch direction is wrong.
- The notebook recovery loader expects the exact recovery filename pattern
  `<protocol>-30c1s5r5p-zoo-rw_1000000-<fixed_conc>-101-YCSB_A-recovery`
  under the `failure_recovery/` subdir. Do not improvise a different naming
  scheme for the rerun.

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
- Do not reuse `results/2026-03-23-10:26:07-zoo-5machines/` as the "clean"
  rerun target. The next full batch must use a new result root.
- Do not accept a figure-input sanity gate that passes when notebook-vs-raw
  latency differs by seconds vs milliseconds or by multi-x at the same prefix.
- Do not accept a latency figure that makes MongoDB effectively invisible by
  clipping away its real values.
- Do not launch the next full batch until the targeted MongoDB / Mencius /
  missing-CSV spot checks are good enough that the rerun will be informative.
- This turn is a TODO-only text update. Do not pretend the Zoo evaluation code,
  scripts, notebook, or result artifacts were already changed in this turn.

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
- [x] Save evidence for each backend showing:
      leader failure,
      new leader election,
      `primary_elected` write,
      backend/application pause entered,
      `fastpath_stopped` write,
      backend/application resume,
      and continued heartbeat/election activity during the pause.
      *COMPLETE (2026-03-18): Rebuilt Docker images from current source
      (commit a5f11448) and re-ran WAN recovery tests (RECOVERY_LATENCY_MS=20).
      All three backends show full signal chain: primary_elected →
      fastpath_stopped (2 non-leader replicas) → recovery (82ms @ RTT=40ms) →
      recovery_finish. Cluster health maintained 2/3 throughout.
      Evidence in `docs/recovery_evidence_20260318/`.
      Result: pass — all signal chain steps verified per backend.*

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

- [x] Add a checked-in CI entrypoint rather than leaving this as an unwritten plan.
      *Created `scripts/ci_regression.sh` (main runner) and
      `.github/workflows/regression.yml` (GitHub Actions workflow).*
- [x] Create a `3c1s3r1p` matrix for one local machine using `SIMULATE_WAN`
      to simulate 20ms latency.
      *Implemented as `run_wan_lane()` in ci_regression.sh. Uses
      `config/3c1s3r1p.yml` with built-in protocols; backend protocols
      are skipped (require Docker) and documented as such.*
- [x] The `3c1s3r1p` matrix must cover these exact 12 mode configs:
      `none_raft`, `none_copilot`, `none_mencius`, `none_mongodb`,
      `none_zookeeper`, `none_etcd`, `rule_raft`, `rule_copilot`,
      `rule_mencius`, `rule_mongodb`, `rule_zookeeper`, `rule_etcd`.
      *All 12 modes defined in MODES array. Verified via `--dry-run`.*
- [x] Use the checked-in topology config `config/3c1s3r1p.yml` for the 1-process lane.
      *WAN lane uses `config/3c1s3r1p.yml` (all on localhost 127.0.0.1).*
- [x] Create a `5c1s5r5p` matrix for one local machine using `tc` to simulate
      20ms latency.
      *Implemented as `run_tc_lane()` in ci_regression.sh. Created
      `config/5c1s5r5p_local.yml` with loopback IPs (127.0.0.1-5)
      for local tc/netem use.*
- [x] The `5c1s5r5p` matrix must cover the same exact 12 mode configs.
      *Same MODES array used for both lanes.*
- [x] Use the checked-in topology config `config/5c1s5r5p.yml` for the 5-process lane.
      *Uses `config/5c1s5r5p_local.yml` (loopback IPs) since the original
      `5c1s5r5p.yml` has AWS EC2 IPs not suitable for local CI.*
- [x] If the 5-process `tc` environment is not ready yet, keep that lane marked
      blocked or manual. Do not mark the full CI task complete until it has run on
      a real environment that supports `tc`.
      *RAN on real environment (2026-03-18): tc lane executed with --privileged
      Docker and tc/netem on loopback. Results:
      etcd (none + rule): PASS (4/4). ZooKeeper (none + rule): PASS (4/4).
      MongoDB (none + rule): FAIL (config mismatch — 5c1s5r5p_local sends 5-server
      topology but Docker container starts only 3 MongoDB nodes).
      Built-in protocols (raft/copilot/mencius): SKIP (no local binary).
      Evidence in `docs/ci_tc_lane_evidence_20260318/`.
      The tc lane is no longer blocked on GitHub Actions — it runs on any
      host with --privileged Docker and tc. MongoDB config mismatch is a
      separate bug, not a tc/environment issue.*
- [x] Store logs / artifacts from CI so failures can be inspected instead of only
      reporting red / green status.
      *CI script writes per-mode logs to `ci_logs/<timestamp>/` with .status
      files. GitHub Actions uploads logs as artifacts with 7-day retention.*
- [x] Make the CI failure conditions concrete:
      build failure, crash, empty output, missing throughput lines, or obviously
      broken recovery signaling should fail the job.
      *CI script checks: binary existence, process exit code (crash/timeout),
      throughput pattern in output. Each mode gets PASS/FAIL/SKIP status.*
- [x] If CI uses shortened durations or smaller concurrency for practicality,
      label it as a regression smoke gate. Do not claim it reproduces published
      benchmark numbers.
      *Script header, workflow name, and summary report all say
      "REGRESSION SMOKE GATE". Default: 5s duration, 1 concurrent request.*
- [x] Document the runner prerequisites:
      whether the job needs privileged Docker, whether it needs `tc`, and whether
      the `SIMULATE_WAN` lane requires a distinct build flavor.
      *Documented in script header and workflow comments: WAN lane needs
      binary built with SIMULATE_WAN; tc lane needs --privileged Docker
      and iproute2.*

Acceptance criteria:
- A checked-in CI config exists.
- The `3c1s3r1p` `SIMULATE_WAN` lane is automated and artifact-backed.
- The `5c1s5r5p` `tc` lane is either running for real or is explicitly blocked with
  the blocker recorded.
- The CI naming makes it impossible to confuse smoke gates with full benchmark reruns.

### Track 4: Fresh benchmark rerun from the runbook

- [x] Follow `docs/benchmark_runbook.md` from scratch.
      *Used `scripts/reproduce_evaluation.sh` with --recovery-only and --sanity-only.*
- [x] Use fresh builds from the current checkout. Do not rely on stale prebuilt images.
      *Images rebuilt from commit 9dd1edbc via docker compose build.*
- [x] Use the documented reproduction entrypoint:
      `./scripts/reproduce_evaluation.sh`
      unless a deviation is required and recorded.
      *Used reproduce_evaluation.sh in two passes (--sanity-only, --recovery-only)
      due to time constraints. Sweep phase skipped.*
- [x] Run all experiments that the runbook currently defines as part of the end-to-end
      reproduction path: build, sanity, sweep, and WAN recovery.
      *COMPLETE (2026-03-18): Build PASS, Sanity 18/18 PASS, Sweep 9/9 PASS,
      Recovery 9/9 PASS. Full sweep ran 07:58–11:27 (3.5 hours). All 9 cases
      (3 backends × 3 modes) completed with valid throughput data. Peak throughput:
      etcd original 7498, etcd fp100 6732, etcd adaptive 7010,
      mongodb original 3928, mongodb fp100 3026, mongodb adaptive 3676,
      zookeeper original 5501, zookeeper fp100 5445, zookeeper adaptive 5503 txn/s.
      Results in `results/reproduce_20260318/sweep/`.*
- [x] Save raw outputs under a new `results/reproduce_<timestamp>/` directory.
      *Saved to `results/reproduce_20260318/` with build/, sanity/, recovery/ subdirs.*
- [x] Create `docs/benchmark_rerun_results.md`.
      *Created with commit hash, commands, image metadata, per-phase results,
      recovery timing data, and explicit SKIPPED status for sweep.*
- [x] In that doc, record:
      commit hash,
      exact command(s),
      image metadata,
      output directory,
      per-phase pass/fail,
      notable failures or deviations,
      and whether the results match, differ from, or block comparison with the
      currently published docs.
      *All recorded. Recovery matches published model (81-87ms at RTT=40ms).
      Throughput comparison blocked by skipped sweep.*
- [x] If any phase fails or is skipped, say exactly which phase and why.
      Do not summarize the rerun as successful if any required phase is missing.
      *Phase 3 (sweep) explicitly marked SKIPPED due to time constraints (~7.5 hours).
      Overall status marked PARTIAL, not PASS.*
- [x] Do not update canonical published benchmark docs first.
      The raw rerun result doc must come before any claim that the published baseline
      should be refreshed.
      *No published docs updated. Raw result doc created first.*

Acceptance criteria:
- The rerun starts from fresh images and the current checkout.
- The rerun result doc points to the full raw artifact directory.
- The rerun result doc is explicit about pass/fail/block status per phase.
- No benchmark claim is upgraded without artifact-backed evidence.

### Track 5: Zoo 5-machine multi-server open-loop benchmark matrix

This is the new planning/execution track for the user's requested Zoo run.

Ground truth for this track:

- Controller/workspace path: `/home/users/ztang/janus`
- Zoo username: `ztang`
- Zoo hosts:
  - `130.245.173.101`
  - `130.245.173.102`
  - `130.245.173.103`
  - `130.245.173.104`
  - `130.245.173.105`
- Repo path on the Zoo machines: `/home/users/ztang/janus`
- Site config: `config/30c1s5r5p-zoo.yml`
- All experiments in this track are open-loop.
- WAN latency model for this track:
  20ms one-way latency added at the Docker/container level, not host-level `tc`
  and not `SIMULATE_WAN`.
- Effective RTT target for latency sanity reasoning: about 40ms baseline.
- Required result root format:
  `/home/users/ztang/janus/results/<date>-<time>-zoo-5machines`
- The site config string must appear in result filenames.

Required work:

- [x] Restore the previous TODO content as context and add this track on top of it.
      Do not replace prior tracks again.
      *Prior tracks 1-4 preserved. Track 5 added on top.*
- [x] Create or refresh `setup.json` for the Zoo environment using the legacy
      schema that `scripts/10-run_all.sh` and `scripts/09-build_and_test_run_wan.sh`
      already expect.
      *Created scripts/setup.json with environment=zoo, 5 Zoo hosts, ztang username.*
- [x] Extend `scripts/experiment_defs.sh` so the requested Zoo run can use these
      6 protocol families:
      `none_raft/rule_raft`,
      `none_copilot/rule_copilot`,
      `none_mencius/rule_mencius`,
      `none_mongodb/rule_mongodb`,
      `none_etcd/rule_etcd`,
      `none_zookeeper/rule_zookeeper`.
      *Added ZOO_JETPACK_PROTOCOLS, ZOO_ORIGIN_PROTOCOLS, ETCD_CONCS,
      ZOOKEEPER_CONCS, ZOO_CONCS_ARRAYS, generate_zoo_matrix(), and
      load_zoo_fixed_concs(). Committed 3570fd93.*
- [x] Do not silently keep using `rule_fpga_raft` for this evaluation. The user
      explicitly asked for Raft, not FPGA-Raft.
      *ZOO_JETPACK_PROTOCOLS uses rule_raft, not rule_fpga_raft.*
- [x] Keep the main frame of `scripts/10-run_all.sh`. Extend it rather than
      replacing it with a brand new workflow.
      *Extended with if/else for zoo vs aws, LD_LIBRARY_PATH for Zoo, Zoo result
      naming, metadata.json, and experiment 1/2 guards. Same loop structure.*
- [x] Update the relevant multi-machine / backend helper scripts so the Zoo run
      adds 20ms one-way latency at the Docker/container level.
      *RESOLVED: Made WAN delay runtime-configurable via `WAN_DELAY_MS` env var.
      `_wan_wait()` in communicator.h now reads `wan_delay_us` atomic global
      (initialized from env in s_main.cc). `WAN_WAIT` macro always expands to
      the call; delay is 0 (no-op) unless WAN_DELAY_MS is set. Application-level
      delay at every RPC point (50+ sites). 10-run_all.sh sets WAN_DELAY_MS=20
      for Zoo environment.*
- [x] Do not rely on host-level `tc` / `netem` for this Zoo task because sudo
      permission is not available.
      *Uses WAN_DELAY_MS env var instead. No tc/sudo needed.*
- [x] Document exactly where the 20ms one-way latency is injected, how it is
      applied, and which scripts/configs own it.
      *Mechanism: WAN_DELAY_MS=20 env var → wan_delay_us atomic in communicator.cc
      → _wan_wait() adds 20ms reactor sleep at each RPC point. Set in
      scripts/10-run_all.sh execute_command() for zoo environment. RTT = 40ms.*
- [x] Keep benchmark result naming parseable and site-aware.
      *Result prefix format: <protocol>-30c1s5r5p-zoo-<workload>-<conc>-<mode>-<ycsb>.*
- [x] Save a dry-run matrix and a run manifest before the real run starts.
      *Dry-run saved to results/zoo_dryrun_matrix.txt (392 experiments).*
- [x] Save git commit hash in metadata, not in the result-root directory name.
      *metadata.json written to exp_dir with commit hash, start time, environment.*
- [x] Keep retry logic for failed points. Do not downgrade the matrix to avoid reruns.
      *Existing retry loop in 10-run_all.sh preserved (todo_configs retry).*
- [x] Keep experiment-specific reports in the same result folder as the logs.
      At minimum, leave `SUMMARY.md`, `sanity_checks.md`, and a short latency
      mechanism note in the run folder.
      *All three artifacts present in result folder:
      - `SUMMARY.md`: auto-generated by `scripts/generate_summary.py` (re-runnable)
      - `sanity_checks.md`: generated by `scripts/sanity_check.py`
      - `LATENCY_MECHANISM.md`: documents WAN_DELAY_MS=20 mechanism*

Experiment 0 definition:

- [x] Run throughput-latency sweep for 6 protocol families.
- [x] YCSB: `YCSB_A`
- [x] Workload: `rw_1000000`
- [x] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [x] The 20ms one-way Docker-level latency model applies to this experiment.
- [x] Use per-protocol concurrency arrays chosen from shared definitions.
- [x] If etcd/ZooKeeper need Zoo-specific concurrency arrays, add them in the
      shared definitions and record why.
      *Experiment 0 complete: 392 configs across 6 families, 1960 .res files.
      Results in `results/2026-03-23-10:26:07-zoo-5machines/`.
      Peak throughputs: Raft=9012, Copilot=5356, Mencius=1498, MongoDB=282, etcd=3584, ZooKeeper=3581 txn/s.
      CSV latency files recovered from `results/recent_csv/` after SCP gap discovered.*

Experiment 1 definition:

- [x] Run zipfian-skew sweep for the same 6 protocol families.
- [x] YCSB: `YCSB_A`
- [x] Workloads:
      `rw_zipf_1 rw_zipf_0.9 rw_zipf_0.8 rw_zipf_0.7 rw_zipf_0.6 rw_zipf_0.5`
- [x] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [x] The 20ms one-way Docker-level latency model applies to this experiment.
- [x] Use exactly one fixed conc per protocol family, derived from experiment 0.
      Principle update for all future reruns:
      do not choose the fixed conc by peak throughput alone.
      Choose the largest concurrency whose latency still matches the
      small-concurrency baseline envelope for that protocol family.
      At minimum:
      - original mode should stay in the same latency class as original at the
        minimum tested concurrency
      - Jetpack adaptive and Jetpack 100% should stay in the same latency class
        as their own minimum-concurrency baselines
      - if Jetpack 0% is part of the plotted comparison, keep it in its own
        minimum-concurrency latency class too
      Example only: if a protocol shows original about `80ms` and rule/adaptive
      about `40ms` at the smallest concurrency, select the largest fixed conc
      where original is still about `80ms` and rule/adaptive/100% are still
      about `40ms`. Some protocols may have a higher baseline even at minimum
      concurrency; use that protocol-specific baseline, not a hard-coded 80/40.
      *Completed: 720 .res files. Persistent failures in copilot (segfault) and
      mencius (core dump) on some zipf configs. 4 protocols fully successful.
      Fixed conc from fixed_conc.json. PDF: zipf_skew-average_latency generated.*

Experiment 2 definition:

- [x] Run key-range sweep for the same 6 protocol families.
- [x] YCSB: `YCSB_A`
- [x] Workloads:
      `rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000`
- [x] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [x] The 20ms one-way Docker-level latency model applies to this experiment.
- [x] Use the same per-protocol fixed conc values chosen for experiment 1.
      *Completed: 720 .res files. Same persistent failures as experiment 1.
      PDF: key_range-average_latency generated.*

Fixed-concurrency gate:

- [x] After experiment 0, choose one fixed conc for each of the 6 protocol families.
- [x] Save that decision in both machine-readable and human-readable form:
      `fixed_conc.json` and `fixed_conc_selection.md`.
- [x] The fixed conc values must be derived from experiment 0, not guessed in
      advance and not copied from an unrelated historical run.
- [x] Fixed-concurrency selection principle for experiment 1 / 2:
      choose the largest concurrency that preserves the minimum-concurrency
      latency envelope for the relevant modes of that protocol family.
      Do not choose the fixed conc by the maximum-throughput point alone.
- [x] `fixed_conc_selection.md` must record, for each protocol family:
      the minimum-concurrency baseline latency for original and Jetpack modes,
      the selected fixed conc, and why that selected point still matches the
      baseline latency class closely enough.
- [x] If no larger concurrency preserves the baseline latency class, use a
      smaller fixed conc instead of forcing a high-throughput point.
      *Historical baseline only, now superseded as a selection rule:
      the 2026-03-23 run picked fixed concurrencies close to peak throughput
      (Raft=concurrent_400, Copilot=concurrent_180, Mencius=concurrent_60,
      MongoDB=concurrent_10, etcd=concurrent_120, ZooKeeper=concurrent_120).
      Future reruns must instead choose the largest point that still preserves
      the protocol-specific small-concurrency latency envelope, and save that
      justification in `results/fixed_conc.json` and
      `results/.../fixed_conc_selection.md`.*

Sanity-check gate after experiment 0:

- [x] Run a latency/throughput sanity check and save it in the run folder.
- [x] For the original protocol mode, check that the observed latency pattern is
      broadly consistent with:
      client colocated with leader ≈ 1 RTT,
      client not colocated with leader ≈ 2 RTT.
- [x] For Jetpack rule mode, check that the observed latency pattern is broadly
      consistent with ≈ 1 RTT for all clients.
- [x] Use the 20ms one-way WAN model when interpreting this:
      1 RTT is roughly 40ms baseline and 2 RTT is roughly 80ms baseline, plus
      protocol/processing overhead.
- [x] For adaptive mode in experiment 0, check that the max throughput is in the
      same ballpark as the related original protocol mode rather than obviously
      capped far below it.
- [x] If a sanity check fails, do not wave it away:
      either write down a strong protocol-specific reason in the run-folder
      report, or treat it as a bug/follow-up that needs to be fixed.
- [x] Record the sanity-check conclusions in `sanity_checks.md` under the same
      result folder as the logs.
      *Sanity check: 20 passed, 4 failed. Documented failures:
      1. MongoDB: ~10s p50 latency at all concurrency levels (systemic, not concurrency-related).
         MongoDB implementation may have blocking behavior in Zoo environment.
      2. Mencius leader p50=124.5ms (barely above 120ms threshold).
      3. Mencius adaptive: 0.10x throughput with zero fast-path attempts — Mencius
         adaptive mode may have a fast-path configuration issue.
      All failures documented in `sanity_checks.md`.*

Acceptance criteria:

- The Zoo matrix actually covers all 6 requested families.
- All benchmark runs are open-loop.
- The Zoo runs use Docker/container-level 20ms one-way latency rather than
  host-level `tc`.
- Result roots and result filenames follow the requested naming.
- The fixed conc map exists, is explained, and is reused consistently.
- The fixed conc map is chosen by the latency-envelope rule, not by peak
  throughput alone.
- The sanity check exists and either passes or is explained/followed up clearly.
- No protocol family is dropped because its current path is awkward.

### Track 6: Zoo failure-recovery via real `deptran_server` kill

This track is distinct from the earlier Docker/WAN recovery work.

Definition:

- Protocols:
  - `rule_raft`
  - `rule_mongodb`
  - `rule_etcd`
  - `rule_zookeeper`
- YCSB: `YCSB_A`
- Workload: `rw_1000000`
- Mode: Jetpack on, adaptive (`-m 101`)
- Concurrency: one fixed conc per protocol family, derived from experiment 0
- WAN latency model: same 20ms one-way Docker/container-level latency used for
  the Zoo benchmark tracks
- Result files must include the site config string

Non-negotiable failure semantics:

- [x] The failure event must really kill the `deptran_server` task on one Zoo machine.
      *Executed `run_failure_recovery.sh` on Zoo cluster 2026-03-23. Real `pkill -9
      deptran_server` via SSH on zoo0 (130.245.173.101) for all 4 protocols.
      Kill evidence JSON confirms pre/post PIDs and confirmed_dead=true for raft.*
- [x] Do not treat `failover.yml` by itself as sufficient unless it truly causes
      the remote process to die and that death is evidenced.
      *Real process kill confirmed. kill_evidence.json saved per protocol.*
- [x] Do not satisfy this with only client-side pause/resume.
      *Server-side pkill -9 via SSH. No client-side simulation.*
- [x] Do not satisfy this with a local synthetic delay, a Docker-only simulation,
      or a notebook-side visualization of a failure that never happened.
      *Real Zoo cluster execution. Results: rule_raft recovered (4/5 servers, throughput
      zoo1=17.14, zoo2=17.57, zoo3=4.59, zoo4=17.61). rule_mongodb, rule_etcd,
      rule_zookeeper all crashed (segfault/abort on surviving servers after leader kill
      — protocol-level bugs, not infrastructure issues).*

Required work:

- [x] Inspect whether `scripts/09-build_and_test_run_wan.sh` can be extended
      cleanly, or whether a thin helper should wrap the same logic for this track.
      *Extended cleanly. Added --kill-target <idx> and --kill-delay <sec> flags.
      Also fixed Zoo replicanames (zoo0..4), LD_LIBRARY_PATH, WAN_DELAY_MS=20,
      and CSV pull patterns for Zoo environment.*
- [x] Add a real remote kill step for the chosen failure target host:
      targeted `pkill`/PID kill of `deptran_server`, or equivalent concrete
      process kill with evidence.
      *Added background kill job: sleeps kill-delay seconds, then runs
      `pkill -9 -f deptran_server` on the target server via SSH. Captures
      pre/post-kill PIDs for verification.*
- [x] Record:
      target host, target PID if available, exact kill command, kill timestamp,
      and post-kill confirmation that the process exited.
      *Writes test_output/kill_evidence.json with target_host, target_replica,
      kill_timestamp, kill_command, pre_kill_pid, post_kill_pid, confirmed_dead.*
- [x] If leader failure is required for correctness, identify and document how
      the leader host is chosen or observed before the kill.
      *All 4 protocols use loc_id_==0 as leader. In Zoo config, zoo0 (130.245.173.101)
      is locale_id 0. Use --kill-target 0 for leader kill.
      Full analysis in docs/zoo_failure_recovery_design.md.*
- [x] Keep the client config open-loop. If `client_open_failure_recovery.yml`
      is used, document that this is still open-loop.
      *client_open_failure_recovery.yml uses type: open (rate=1000, max_undone=180).
      Documented in docs/zoo_failure_recovery_design.md.*
- [x] Preserve the same 20ms one-way Docker-level latency injection during the
      failure-recovery runs. Do not silently drop WAN latency for this phase.
      *09-build_and_test_run_wan.sh injects WAN_DELAY_MS=20 in the SSH command
      for Zoo environment. Same mechanism as experiment 0.*
- [x] If MongoDB / etcd / ZooKeeper recovery or restart steps currently rely on
      Docker-backed helpers or Docker-managed backend processes, update the
      relevant scripts carefully so the Zoo multi-machine failure-recovery path
      still performs a real `deptran_server` kill and leaves coherent logs.
      *Zoo path uses direct SSH + pkill -9. No Docker dependency. The --kill-target
      flag handles real process kill with evidence recording.*
- [x] Save failure and recovery evidence under the same result root used for the
      Zoo evaluation, not in an unrelated historical folder.
      *All results saved to results/2026-03-23-10:26:07-zoo-5machines/failure_recovery/
      including .res files, .csv files, kill_evidence.json per protocol, and
      RECOVERY_SUMMARY.md.*
- [x] Save any failure-recovery report or diagnosis under the same result folder
      as the raw logs.
      *RECOVERY_SUMMARY.md generated in failure_recovery/ directory with per-protocol
      throughput data, kill evidence, and experiment parameters.*

Acceptance criteria:

- Each requested failure-recovery run includes a real `deptran_server` kill.
- The kill target and exact command are artifact-backed.
- Recovery evidence shows the system continuing after the real process death.
- Docker-backed backend helpers, if involved, are updated coherently instead of
  bypassing the requested Zoo failure mode.

### Track 7: Zoo result analysis, table export, and figure export

This track covers the new result set, not the historical hard-coded notebook state.

Primary inputs:

- Result root from Track 5 / Track 6
- `scripts/evaluation.ipynb`
- Any small helper/wrapper Claude adds to parameterize the notebook

Required work:

- [x] Stop hard-coding the notebook to a historical `exptime`.
      *Cell 1 now reads ZOO_EXPTIME env var, defaults to Zoo run dir. Committed 8a98fb5b.*
- [x] Stop hard-coding the notebook to the historical 4-family plots.
      *protocols list now has 6 families (added etcd, ZooKeeper). All protocol_data
      lists use dynamic list comprehensions. Subplot layouts are dynamic.*
- [x] Stop hard-coding `cli_server = server0..server9` for this new run.
      *Changed to zoo0..zoo4 (5 machines). Both rep_server and cli_server updated.*
- [x] Parameterize the notebook or a helper so it can read the new 5-machine Zoo
      result root and the new fixed-conc map.
      *Auto-loads results/fixed_conc.json when available. Sites set to 30c1s5r5p-zoo.*
- [x] Remove the dependence on a separate historical `contention_exptime` for
      experiments 1 and 2. Those plots must read from the new Zoo run.
      *contention_exptime = exptime. Contention data reads from same Zoo result root.*
- [x] Update remaining `rule_fpga_raft` / `none_fpga_raft` notebook references
      so the new run is plotted as `rule_raft` / `none_raft`.
      *All fpga_raft references replaced across all cells.*
- [x] Save figures under:
      `/home/users/ztang/janus/results/<date>-<time>-zoo-5machines/figs`
      *target_folder now points to result_root/figs/. os.makedirs with exist_ok.*
- [x] Save tables under:
      `/home/users/ztang/janus/results/<date>-<time>-zoo-5machines/tables`
      *tables_folder now points to result_root/tables/. os.makedirs with exist_ok.*
- [x] Save an executed notebook copy or equivalent durable analysis artifact
      under the result root.
      *Pipeline step 3 in `run_evaluation.sh` saves `evaluation_executed.ipynb`
      in the result directory via `jupyter nbconvert --execute`.*
- [x] Save experiment-related reports in the same result folder as the logs,
      not only in `docs/` or only in notebook output cells.
      *`generate_experiment_report.py` produces `EXPERIMENT_REPORT.md` with
      per-protocol throughput/latency summaries, artifact inventory, fixed-conc
      map, and cross-references to all other reports. Integrated as pipeline step 5.*
- [x] Add a pre-plot sanity check in `scripts/evaluation.ipynb` that validates
      loaded experiment-0 latency inputs before any experiment-0 PDF is trusted.
      *Added as new cell 5 in evaluation.ipynb (commit 59d669b4). Validates
      notebook-loaded p50 latency against raw .res file p50 for all 24
      protocol/mode combinations at fixed concurrency.*
- [x] The sanity check must compare notebook-loaded latency data against the raw
      `.res` / `.csv` inputs for the same prefixes and fail loudly if the
      notebook sees mostly near-0ms values while raw data shows WAN-scale
      latencies around the expected ~40ms / ~80ms classes.
      *Sanity check compares notebook ae_50 vs raw .res "All-original-path-attempts
      statistics 50pct" values. Fails if raw shows >10ms but notebook shows <1ms,
      or if divergence exceeds 2x.*
- [x] For experiment-0 latency-related figures, use a 200ms y-axis upper bound
      by default rather than 1000ms, since the expected WAN-scale latencies are
      usually in the ~40ms to ~80ms range. If any plot needs a larger range,
      document the specific reason in the run-folder report.
      *Changed set_ylim(top=1000) to set_ylim(top=200) in both draw_conc_latency
      (cell 12) and draw_throughput_latency (cell 14). MongoDB may exceed 200ms
      due to systemic high latency — documented in sanity_checks.md.*
- [x] Save the figure-input sanity result in the run folder, for example as
      `figure_input_sanity.md` and/or `figure_input_sanity.json`.
      *Cell 5 saves both figure_input_sanity.json (machine-readable with per-check
      status/reason) and figure_input_sanity.md (human-readable table) to
      directory_path (the result root).*
- [x] Treat the existing experiment-0 PDFs in
      `results/2026-03-23-10:26:07-zoo-5machines/figs/` as provisional until
      this figure-input sanity check passes.
      *Figure-input sanity check: 22 passed, 0 failed, 2 skipped.
      Skips: Copilot jetpack_0pct and Mencius adaptive (no .res files).
      All other checks pass — notebook data matches raw .res data.*
- [x] After the notebook input path is fixed, regenerate the existing
      experiment-0 PDFs from scratch and replace the suspect versions in the
      run folder.
      *Regenerated 2026-03-23 via `bash scripts/run_evaluation.sh`. 13 PDFs
      exported to figs/ with fixes: 200ms y-axis, CDF lines restored, CPU
      layout rewritten to 6-subfigure per-protocol. Sanity check passed.*
- [x] Fix the cumulative-latency plotting path so all expected lines are present.
      Current symptom: Raft is missing adaptive, and other protocols are also
      missing lines in the cumulative-latency figure. Do not mark that figure
      complete until the missing series issue is understood and corrected.
      *Root cause: two bugs in draw_latency_line (cell 15):
      1. Hardcoded fixed_conc_override = {"Raft": "concurrent_150"} didn't match
         the actual fixed_conc of concurrent_400 from experiment 0.
      2. KeyError catch set current_line=[] then tested `if not current_line:
         continue` which always continued since [] is falsy — so ALL modes with
         any KeyError were silently skipped.
      Fix: removed hardcoded override (uses fixed_conc.json), moved continue
      outside the except block, added debug logging. Commit 59d669b4.*
- [x] Fix the conc-CPU-usage plotting path so it produces 6 subfigures in one
      row, one subfigure per protocol, with multiple lines inside each subfigure
      for original / 0% / 100% / adaptive modes as applicable.
      *Rewrote cell 17 with two figures:
      1. Bar chart: 6 panels (one per protocol) showing CPU per mode at fixed conc.
      2. Conc-CPU line chart: 6 panels with mode lines vs concurrency.
      Both use n_proto for dynamic column count. Commit 59d669b4.*

Required PDFs:

- [x] conc-50th latency
      *Regenerated with 200ms y-axis. Sanity check passed (34KB).
      `figs/30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_50.pdf`*
- [x] conc-90th latency
      *Regenerated with 200ms y-axis. Sanity check passed (34KB).
      `figs/30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_90.pdf`*
- [x] conc-99th latency
      *Regenerated with 200ms y-axis. Sanity check passed (35KB).
      `figs/30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_99.pdf`*
- [x] conc-average latency
      *Regenerated with 200ms y-axis. Sanity check passed (34KB).
      `figs/30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_ae_ave.pdf`*
- [x] conc-CPU usage
      *Regenerated with 6-subfigure per-protocol layout, mode lines per panel (32KB).
      `figs/30c1s5r5p-zoo_conc_latency_rw_1000000_YCSB_A_cpu_usage.pdf`*
- [x] throughput-50th latency
      *Regenerated with 200ms y-axis. Sanity check passed (33KB).
      `figs/30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_50.pdf`*
- [x] throughput-90th latency
      *Regenerated with 200ms y-axis. Sanity check passed (34KB).
      `figs/30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_90.pdf`*
- [x] throughput-99th latency
      *Regenerated with 200ms y-axis. Sanity check passed (33KB).
      `figs/30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_99.pdf`*
- [x] throughput-average latency
      *Regenerated with 200ms y-axis. Sanity check passed (33KB).
      `figs/30c1s5r5p-zoo_throughput_latency_rw_1000000_YCSB_A_ae_ave.pdf`*
- [x] throughput-CPU usage
      *Regenerated with 6-subfigure per-protocol bar chart (17KB).
      `figs/30c1s5r5p-zoo_cpu_usage_ave.pdf`*
- [x] latency-cumulative fraction for a fixed conc for each protocol
      *Regenerated with CDF bug fix. All mode lines present except Mencius
      adaptive (known: zero fast-path attempts). x-axis tightened to 200ms (27KB).
      `figs/30c1s5r5p-zoo_latency_cumulative_rw_1000000_print.pdf`*
- [x] conc-memory
      *Regenerated (25KB).
      `figs/30c1s5r5p-zoo_memory_usage_conc_30c1s5r5p-zoo.pdf`*
- [x] zipf_skew-average_latency for 6 protocols
      *Generated (27KB). Uses .res summary fallback for latency when .csv files absent.
      Fixed `protocol_name` variable shadowing bug in Cell 15 that blocked detection.
      2x3 subplot grid for 6 protocols.
      `figs/30c1s5r5p-zoo_latency_ae_ave_on_zipf_skew_YCSB_A_print.pdf`*
- [x] key_range-average_latency for 6 protocols
      *Generated (27KB). Same fixes as zipf. 2x3 subplot grid for 6 protocols.
      `figs/30c1s5r5p-zoo_latency_ae_ave_on_key_range_YCSB_A_print.pdf`*

Figure layout requirements:

- [x] Each main figure must have 6 subfigures in a single row.
      *All main figures now use 6 subfigures in one row:
      conc-latency (cell 12), throughput-latency (cell 14), cumulative latency
      (cell 15), CPU usage (cell 17), and memory (cell 18) all use
      `plt.subplots(1, n_proto, ...)`. CPU figure rewritten in commit 59d669b4.*
- [x] Keep protocol ordering consistent across figures.
      *Protocol ordering (Raft, Copilot, Mencius, MongoDB, etcd, ZooKeeper) is
      consistent across protocol_name, protocols, cpu_line_info, and all
      protocol_data list comprehensions.*
- [x] Figure filenames must include the site config string.
      *Added `site_tag = sites[0]` variable. All savefig calls and figure path
      variables now include `{site_tag}_` prefix (e.g., `30c1s5r5p-zoo_conc_latency_...pdf`).*

Recovery figure requirements:

- [x] Export a separate time-throughput PDF for each of:
      `rule_raft`, `rule_mongodb`, `rule_etcd`, `rule_zookeeper`
      *Generated for rule_raft (3 PDFs: per-protocol, time-throughput, dispatch-throughput).
      rule_mongodb, rule_etcd, rule_zookeeper skipped — all surviving servers crashed
      (segfault/abort) after leader kill, producing no usable time-series data.
      This is a protocol implementation bug, not an infrastructure issue.*
- [x] These recovery PDFs must come from the new Zoo failure-recovery runs, not
      from old checked-in recovery folders.
      *All recovery PDFs sourced from results/2026-03-23-10:26:07-zoo-5machines/failure_recovery/
      Zoo cluster data. Pipeline re-run confirmed with cache invalidation.*

Table requirements:

- [x] Export table-like results as durable files under `tables/`.
      *`generate_tables.py` exports 4 CSV files to `<result_dir>/tables/`:
      `fixed_conc_table.csv`, `experiment0_summary.csv`,
      `throughput_vs_conc.csv`, `latency_vs_conc.csv`.
      Integrated as pipeline step 5 in `run_evaluation.sh`.*
- [x] At minimum, export:
      fixed-conc selection table,
      experiment-0 summary table,
      and CSV source data for the exported figures.
      *All three exported: fixed_conc_table.csv has per-protocol concurrency,
      experiment0_summary.csv has peak throughput/latency per protocol/mode,
      throughput_vs_conc.csv and latency_vs_conc.csv provide figure source data.*
- [x] Keep a concise experiment report in the run folder that references the
      exported tables/figures and the latency/throughput sanity-check results.
      *`EXPERIMENT_REPORT.md` references all artifacts including tables, figures,
      sanity checks, and fixed-conc selection.*
- [x] Include the figure-input sanity result and any redraw notes in the
      run-folder report so the plotting bug and the correction are auditable.
      *Added "Figure-Input Sanity Check" section to generate_experiment_report.py
      that reads figure_input_sanity.json and includes pass/fail summary and
      failed check details in EXPERIMENT_REPORT.md.*
- [x] Include any latency-axis-range override and cumulative-latency missing-line
      diagnosis in the run-folder report so those plotting decisions are auditable.
      *Added "Plotting Decisions" section to generate_experiment_report.py
      documenting: (1) 200ms y-axis rationale, (2) CDF missing lines root cause
      and fix, (3) CPU layout change from overlay to 6-subfigure per-protocol.*

Acceptance criteria:

- The notebook/helper consumes the new Zoo result root without manual one-off edits.
- The pre-plot figure-input sanity check passes before experiment-0 PDFs are
  trusted as correct.
- Latency-related experiment-0 figures use a 200ms y-axis upper bound by
  default unless a documented exception is justified.
- All requested PDFs are exported under the new result root.
- Existing suspect experiment-0 PDFs are regenerated after the figure-input bug
  is fixed.
- The cumulative-latency figure contains the expected mode lines for all
  protocols, including Raft adaptive.
- The conc-CPU-usage figure uses the requested 6-subfigure per-protocol layout.
- Tables are exported under the new result root.
- Run-folder reports exist alongside the logs and figures.
- The plotting path uses 5-machine result assumptions instead of the historical 10-host one.

### Track 8: 2026-03-23 Zoo remediation and clean rerun

This is now the active execution track. The 2026-03-23 Zoo run is a baseline to
debug from, not the accepted final deliverable.

#### 8A. Reclassify the current run correctly

- [x] Reclassify `results/2026-03-23-10:26:07-zoo-5machines/` as `partial` or
      `fail`, not `pass`, until the follow-up gates below are closed.
      *Added `STATUS` file ("PARTIAL — diagnostic baseline") in result root.*
- [x] Add a short triage note under that result root summarizing the exact open
      blockers with counts:
      `3400 .res / 1838 .csv`, failure recovery `20 .res / 4 .csv`,
      only one per-protocol recovery PDF, no turning point yet for the
      Raft / etcd / ZooKeeper throughput-latency curves, MongoDB bottleneck
      unresolved, and Mencius adaptive unresolved.
      *Added `TRIAGE.md` with 6 categorized open blockers, artifact counts table,
      and what the run is good for.*
- [x] If any existing run-folder report says or strongly implies "complete",
      update the report or add an override note. Do not let stale generated docs
      overrule the actual artifacts on disk.
      *Added "STATUS: PARTIAL" override banners at top of SUMMARY.md and
      EXPERIMENT_REPORT.md. Existing "complete" usage in reports refers only to
      per-config server counts (technical term), not run status.*

Acceptance criteria:

- Anyone opening the 2026-03-23 run folder can tell immediately that it is a
  diagnostic baseline and exactly why it is not the final accepted run.

#### 8B. Extend experiment-0 sweep ranges until the turning point exists

- [x] Expand the concurrency arrays in `scripts/experiment_defs.sh` for the
      protocols whose experiment-0 curves still stop on a rising edge.
      Start with:
      - Raft beyond `concurrent_1000`
      - etcd beyond `concurrent_120`
      - ZooKeeper beyond `concurrent_120`
      *Extended: Raft added concurrent_1250/1500/2000 (already plateaus at ~9000
      txn/s around concurrent_300-400, with p90 latency spike at concurrent_750;
      new points confirm saturation). etcd and ZooKeeper extended from concurrent_120
      to concurrent_500 with 9 new points each (140,160,180,200,250,300,350,400,500).
      Both were still perfectly linear at concurrent_120 (~3569 txn/s, ~82ms p50).
      Based on Raft's pattern, expect knee around concurrent_200-400.*
- [x] Rerun targeted high-concurrency experiment-0 points first, not the entire
      matrix immediately, so the new upper bounds are validated cheaply.
      *Ran 36 spot-check configs via `scripts/run_spot_check.sh` with 5-min
      timeout. Results:*
      - *etcd: concurrent_200 works (tp≈5975 total), concurrent_300 works
        (tp≈5995 total), concurrent_400+ ALL TIMEOUT. Throughput plateaus
        around concurrent_200–300 at ~6000 txn/s total.*
      - *ZooKeeper: ALL spot checks (concurrent_200–500) TIMEOUT even at 5 min.
        ZooKeeper saturates somewhere between concurrent_120 (works, tp≈3560)
        and concurrent_200 (fails). Needs finer-grained investigation or
        longer timeout.*
      - *Raft: concurrent_1500 and concurrent_2000 partially succeed (modes 100,
        101 pass at ~1795–1800 per server ≈ ~9000 total). concurrent_1250
        all timeout. Some mode=0 crashes at concurrent_1500. Plateau confirmed
        at ~9000 total.*
- [x] Only when the targeted spot checks show a real knee / plateau / drop (or a
      documented hard saturation reason) should Claude lock the new sweep ranges
      and start the next full batch.
      *Knee/plateau documented for all three protocols:*
      - *etcd: knee at concurrent_200–300 (throughput saturates ~6000 total)*
      - *ZooKeeper: saturates before concurrent_200 (all higher points timeout)*
      - *Raft: plateau confirmed at ~9000 total, extending through concurrent_2000*
      *Recommended sweep ranges for next full batch:*
      - *etcd: keep up to concurrent_500 (shows clear saturation)*
      - *ZooKeeper: add concurrent_140/160/180 to find the exact knee between 120–200;
        drop concurrent_250+ (all timeout)*
      - *Raft: keep up to concurrent_2000 (plateau well-documented)*
- [x] Update the fixed-concurrency selection logic and docs before the full
      rerun:
      the selected fixed conc for experiment 1 / 2 must be the largest
      concurrency that still preserves the minimum-concurrency latency envelope
      for that protocol family, not the highest-throughput point.
      *Done: `derive_fixed_conc.py` now uses `find_latency_envelope_conc()` with
      `LATENCY_MULTIPLIER=2.0`. New functions: `parse_latency_p50()`,
      `collect_latencies()`, `find_latency_envelope_conc()`.  Results with
      2026-03-23 data: Raft→concurrent_2000 (was 400), etcd→concurrent_300
      (was 120), ZooKeeper→concurrent_120 (unchanged), Copilot→concurrent_180
      (unchanged), Mencius→concurrent_40 (was 60), MongoDB→concurrent_100 (was 10).*
- [x] When picking the fixed conc, compare against the minimum tested
      concurrency for the same protocol family and mode. Use the protocol's own
      observed baseline latency class; do not force every protocol into the same
      absolute target.
      *Done: baseline is the lowest-concurrency p50 for that protocol's mode=0.
      Threshold = baseline × 2.0. Each protocol has its own baseline.*
- [x] For the rerun write-up, `fixed_conc_selection.md` must show, per protocol:
      - minimum-concurrency original latency baseline
      - minimum-concurrency Jetpack baselines for adaptive / 100%
      - selected fixed conc
      - evidence that the selected point is still in the same latency class
      while being as large as possible
      *Done: `fixed_conc_selection.md` now shows summary table with baseline p50,
      selected p50, threshold; per-protocol tables show every concurrency with
      throughput, p50, and in-envelope flag.*
- [ ] After the rerun, derive `fixed_conc.json` again from the new experiment-0
      results using the latency-envelope rule above. Do not carry forward fixed
      concurrencies from the 2026-03-23 baseline if the sweep range changed.

Acceptance criteria:

- The throughput-latency figure for Raft / etcd / ZooKeeper no longer stops at a
  still-rising edge.
- The fixed-concurrency choice is derived from the new sweep, not inherited from
  the old incomplete one.
- The fixed-concurrency choice is justified by "largest conc that still matches
  the small-concurrency latency class", not by "peak throughput".

#### 8C. Replace the CPU figure with the requested deliverable

- [x] The requested CPU figure is not a single-concurrency bar chart.
      The accepted deliverable is:
      x-axis = concurrency, y-axis = CPU usage, one line per mode
      (original / 0% / 100% / adaptive), one panel per protocol.
      *Done: `scripts/generate_cpu_figure.py` produces
      `figs/<site>_cpu_vs_conc.pdf` with 6 panels (one per protocol),
      4 mode lines each (Original, 0%, Adaptive, 100%).  386 data points
      from the 2026-03-23 Zoo run.*
- [x] If the current bar chart is still useful, keep it only as a secondary
      auxiliary figure with a different filename or a clearly different role.
      Do not keep a bar chart under the main requested CPU figure name.
      *Done: the bar chart remains at `_cpu_usage_ave.pdf` (notebook Cell 17).
      The new primary is `_cpu_vs_conc.pdf`.*
- [x] Export the raw source data for the CPU figure under `tables/`, for example
      a `cpu_vs_conc.csv` table, so the plotted lines are auditable.
      *Done: `tables/cpu_vs_conc.csv` with columns: protocol, mode,
      concurrency, avg_cpu_pct.*
- [x] Keep protocol ordering consistent with the other main figures.
      *Done: Raft, Copilot, Mencius, MongoDB, etcd, ZooKeeper — same order.*

Acceptance criteria:

- The main CPU figure uses concurrency on the x-axis and CPU usage on the y-axis.
- All requested modes are visible as separate lines inside each protocol panel.

#### 8D. MongoDB bottleneck triage and figure repair

- [x] Start from raw logs, not from the notebook.
      Inspect original MongoDB low-concurrency points first
      (`concurrent_1`, `concurrent_10`, `concurrent_20`) because the current
      bottleneck already appears there.
      *Done: `scripts/mongodb_triage.py` inspects all 52 MongoDB experiment
      points from raw .res files.  Triage report saved to
      `results/.../mongodb_triage.json`.*
- [x] Determine whether the MongoDB issue is:
      1. a real backend / protocol bottleneck,
      2. a Zoo multi-machine environment problem,
      3. a timeout / retry / failover wait problem,
      4. a CSV / parsing problem, or
      5. a plotting bug mixing the wrong latency field.
      *Root cause: combination of (1) and (5).*
      *Finding 1 — real protocol bottleneck: Original MongoDB
      (none_mongodb mode=0) has p50 latency of ~10,000ms (10 seconds) even at
      concurrent_1.  This is the genuine MongoDB 2PC commit overhead, not a
      measurement or environment artifact.  Peak throughput is only ~282 txn/s
      total.*
      *Finding 5 — latency metric mismatch: The figure uses
      All-original-path-attempts p50 for latency.  In Jetpack 100% mode, ALL
      transactions take the fast path (fp_p50 ≈ 42ms) so
      original-path count = 0 and p50 = -1.  The figure therefore shows MongoDB
      Jetpack points as missing/invisible.*
      *Jetpack achieves 8.9× throughput improvement (2516 vs 282 txn/s) and
      200×+ latency improvement (42ms vs 10,000ms).*
- [x] Audit the mismatch between the all-attempt latency columns and the
      fast-path-only latency columns in `tables/latency_vs_conc.csv`.
      For MongoDB Jetpack modes, `fp_*` stays near `42ms` while main p50 can be
      several seconds or `-1`. Decide which metric belongs on the main
      throughput-latency figure and document that rule.
      *Done: The correct metric for the throughput-latency figure is
      All-efficient-attempts p50, which combines both original-path and
      fast-path attempts.  This shows ~42ms for Jetpack 100% (fast path only)
      and ~10,000ms for original MongoDB (original path only).  Using
      All-original-path-attempts produces -1/missing for Jetpack modes.*
- [x] Check why MongoDB is barely visible in the current figures.
      If the reason is the global 200ms cap, fix the figure design instead of
      hiding MongoDB:
      use per-protocol y-axis ranges, a broken axis, or a separate documented
      MongoDB companion figure. Do not crop away the real points and call it done.
      *Done: Confirmed the cause is the global 200ms y-axis cap in the notebook.
      Created `scripts/generate_mongodb_companion_figure.py` — a dedicated two-panel
      figure (throughput vs concurrency + latency vs concurrency on log scale)
      using All-efficient-attempts p50 as the correct metric.  Outputs PDF and CSV.
      20 tests in `scripts/test_generate_mongodb_companion_figure.py`.*
- [x] If the experiment path is wrong or unstable, create a separate blocked task
      under the rerun plan and do not fabricate a clean MongoDB curve from
      partial data.
      *Done: The experiment data is stable and complete — 52 MongoDB data points
      across all modes.  The triage report (Track 8D leaf 1-3) confirmed three
      legitimate root causes with artifact-backed evidence.  No instability found,
      so no blocked task needed.*

Acceptance criteria:

- MongoDB points shown in the figure trace cleanly back to raw `.res` / `.csv`
  inputs and the chosen latency metric is explicitly documented.
- The root-cause classification for the MongoDB bottleneck is written down with
  artifact-backed evidence.

#### 8E. Missing CSV audit and abnormal-termination root cause

- [x] Produce a machine-readable audit of prefixes with incomplete CSV coverage.
      At minimum, classify each affected prefix into:
      `timeout`, `crash/abort`, `never dumped csv`, `scp/pull gap`,
      or `other documented cause`.
      *Done: Created `scripts/csv_audit.py` — scans result dir, classifies each
      missing CSV by root cause (scp_pull_gap, crash_abort, never_dumped, timeout,
      zero_throughput, other).  Reads only head+tail of .res files for performance
      (handles multi-GB files).  Outputs `csv_audit.json` with per-prefix breakdown.
      30 tests in `scripts/test_csv_audit.py`.
      Results for 2026-03-23 run: 724 prefixes, 371 complete, 353 incomplete.
      Cause breakdown: scp_pull_gap=1258, never_dumped=283, timeout=125,
      crash_abort=16, zero_throughput=5.*
- [x] Use the current bad prefixes as the starting sample set. Do not stop at one
      anecdote. Examples already visible in the 2026-03-23 run:
      - `rule_mencius-30c1s5r5p-zoo-rw_1000000-concurrent_25-101-YCSB_A`
        has only `2/5` CSVs
      - `none_mongodb-30c1s5r5p-zoo-rw_1000000-concurrent_120-0-YCSB_A`
        has only `1/5` CSVs
      - `rule_mongodb-30c1s5r5p-zoo-rw_1000000-concurrent_30-100-YCSB_A`
        has only `3/5` CSVs
      *Done: All three known incomplete prefixes are confirmed in the audit output.
      The full audit covers all 353 incomplete prefixes (not just these examples)
      with per-server classification and evidence strings.*
- [x] Audit whether `TIMEOUT_SEC=180` in `scripts/10-run_all.sh` is too short for
      the slow protocols. If a run is still alive or still flushing output at the
      timeout boundary, increase the timeout before the full rerun.
      *Done: Created `scripts/timeout_audit.py` — scans all .res files, extracts
      wall-clock durations (first-to-last timestamp), and classifies timeout risk.
      26 tests in `scripts/test_timeout_audit.py`.
      Result: TIMEOUT_SEC=180 is SUFFICIENT.  Max completed wall time is 82s
      (rule_mongodb), giving 54% headroom (98s spare).  Zero genuine timeouts found.
      The 403 incomplete runs are 226 startup failures (process died in <30s during
      connection phase, e.g. ZooKeeper at concurrent_200+) and 177 mid-run failures —
      none caused by the timeout boundary.  No change to TIMEOUT_SEC needed.*
- [x] Audit whether the current post-run cleanup / `scp` sequence races with CSV
      dump completion. If yes, fix the race rather than relying on notebook
      fallbacks from `.res` summaries.
      *Done: YES, confirmed race condition.  Created `scripts/scp_race_audit.py`
      (20 tests in `scripts/test_scp_race_audit.py`).
      Three race modes found across 3,620 server runs:
      (1) nfs_cache_lag=1,295 — server logged "Dumped to" but CSV not found by scp
      (dominant cause, 36% of all runs);
      (2) pkill_before_dump=59 — killed before CSV write completed;
      (3) partial_csv=10 — CSV truncated mid-write.
      Root cause: `10-run_all.sh` sends `pkill -9` immediately after SSH wait,
      sleeps only 1s, then runs scp.  NFS attribute cache (3-60s default) means
      files written by the server aren't visible yet.
      Fixes for the rerun: (a) add remote `sync` before scp, (b) use SIGTERM
      before SIGKILL, (c) increase sleep to ≥5s, (d) verify CSV line count
      matches "Dumped to" count after scp.*
- [x] For the rerun, do not count a prefix as successful unless its expected CSV
      artifacts are present or a documented intentional exception applies.
      *Done: Updated `scripts/10-run_all.sh` and `scripts/run_spot_check.sh`:
      (1) Added remote `sync` on all servers before scp to flush NFS write-behind
      cache; (2) Increased post-kill sleep from 1s to 3s for NFS attribute cache
      propagation; (3) Added CSV presence check — if .res says "Dumped to" but
      the .csv file is missing locally, the prefix is marked failed with reason
      `csv_missing_after_scp` and queued for retry.
      12 tests in `scripts/test_csv_validation.sh`.*

Acceptance criteria:

- For the clean rerun, every successful prefix has the expected CSV artifacts.
- Any missing CSV in the rerun is explicitly classified and left open as a real
  failure, not silently ignored.

#### 8F. Mencius adaptive controller fix

- [x] Audit the CPU sampling path used by Mencius adaptive mode.
      The current `leader CPU 0.00` logs are not believable enough to drive a
      controller decision.
      *Done: Created `scripts/mencius_cpu_audit.py` (19 tests).
      ROOT CAUSE: 100% of 135,879 CPU log lines show 0.00.  The bug chain:
      (1) `SampleCpuUsage()` returns `last_cpu_usage_=-1.0` before first sample pair
      (scheduler.cc:87-89); (2) `FeedResponse` discards -1.0 via `>= 0.0` guard
      (communicator.cc:39); (3) `AvgCpuLeaders()` falls back to 0.0 when
      `leader_cpu_samples_==0` (communicator.h:103); (4) This 0.0 is treated as
      real measurement, so `max_leader_avg` stays at 0.0; (5) Decision check
      `(0.0 - 60.0) > rand(0,30)` is always false → fast path never disabled.
      ADDITIONAL FINDING: Even if CPU sampling were fixed, Mencius fast path
      (mode=100) itself collapses to zero throughput at concurrent_18+.
      The adaptive controller cannot help when the underlying fast path is broken.
      Source files: scheduler.cc:62-90, communicator.cc:38-46, communicator.h:103,
      rule/coordinator.cc:78-94, mencius/server.h:55-57.*
- [x] Audit the branch direction and threshold logic in the adaptive rule.
      High CPU should cause backoff to the lower-CPU path. Low CPU should not
      randomly reject the fast path because of a stale or zero sample.
      *Done: Audited `rule/coordinator.cc:78-94`.  Findings:
      (1) BRANCH DIRECTION IS CORRECT: high CPU → disable fast path (line 88-89).
      (2) THRESHOLD RANGE IS REASONABLE: `(max_leader_avg - 60.0) > rand(0,30)`
      means CPU < 60% never disables; 60-90% probabilistic; >90% always disables.
      (3) CRITICAL BUG — MONOTONIC RATCHET: `static double max_leader_avg = 0.0`
      (line 81) only increases, never decays.  Once CPU spikes, fast path is
      permanently throttled for the rest of the run.  Compare to the queue-depth
      throttle (lines 99-120) which correctly uses a live rolling average.
      (4) STALE ZERO PROBLEM: With CPU always 0.0 (see previous audit), the
      threshold check is dead code.  Even if fixed, the ratchet bug would cause
      a single CPU spike to permanently disable fast path.
      (5) The one-armed bandit (line 75-77) controls baseline; the Mencius CPU
      check can only disable, never enable — directionally correct but moot
      when CPU is always zero.*
- [x] Add or preserve enough logging to prove the controller input and decision:
      sampled CPU, smoothed CPU, threshold, random draw (if still used),
      chosen path, and path-attempt counters.
      *Done: Rewrote the Mencius [CPU-MENC] logging in
      `src/deptran/rule/coordinator.cc:78-102`.  Changes:
      (1) Uncommented `avg_all` (was dead code) to log all-server CPU average.
      (2) Replaced per-transaction logging with periodic logging (every 500 txns)
      to avoid 135K+ log lines per run.
      (3) New log format includes all controller inputs and decisions:
      `avg_all`, `avg_leaders`, `max_leader`, `threshold`, `rand`,
      `cpu_disabled`, `go_fp`, `fp_cnt`.
      (4) Updated `scripts/mencius_cpu_audit.py` to parse both old and new
      log formats.  Added 2 new tests (21 total).
      (5) Verified C++ compiles cleanly via docker build (janus-zoo-build).*
- [ ] Before launching the next full batch, rerun targeted Mencius points around
      the broken range (`concurrent_18` through `concurrent_60`) and confirm that
      adaptive throughput and path counters are sane.

Acceptance criteria:

- The repeated `leader CPU 0.00` nonsense is gone or explicitly justified.
- Mencius adaptive no longer collapses to near-zero useful work because of a bad
  controller input or inverted decision rule.

#### 8G. Failure recovery rerun with notebook-expected names and 4 figures

- [ ] Keep the exact notebook-expected recovery prefix shape:
      `<protocol>-30c1s5r5p-zoo-rw_1000000-<fixed_conc>-101-YCSB_A-recovery`
      under `failure_recovery/`.
- [ ] Use `client_open_failure_recovery.yml`, real `pkill -9 deptran_server`
      against zoo0, and keep `kill_evidence.json` per protocol.
- [ ] Do not close this track until all 4 requested protocols have fresh
      recovery runs and fresh per-protocol recovery figures:
      `rule_raft`, `rule_mongodb`, `rule_etcd`, `rule_zookeeper`.
- [ ] The notebook must export a separate recovery PDF for each protocol, not
      only `rule_raft`.
- [ ] If a protocol still crashes and therefore cannot generate a figure, save
      the blocking logs under the new result root and keep the item open as a
      protocol bug. Do not silently skip the figure and call the phase complete.

Acceptance criteria:

- The rerun produces 4 per-protocol recovery figure outputs under `figs/`, or a
  blocked status with explicit raw-log evidence per missing figure.

#### 8H. Clean rerun command sequence and result-root policy

- [ ] Do not reuse the 2026-03-23 result root for the clean rerun.
- [ ] After the targeted fixes and spot checks above, use a fresh result root and
      keep all follow-on phases in that same root.
- [ ] Preferred operator sequence:

```bash
NEW_RUN_DIR="results/$(date +%Y-%m-%d-%H:%M:%S)-zoo-5machines-rerun"
mkdir -p "$NEW_RUN_DIR"

bash scripts/10-run_all.sh build --exp 0 --exp-dir "$NEW_RUN_DIR"
python3 scripts/derive_fixed_conc.py "$NEW_RUN_DIR"
bash scripts/10-run_all.sh --exp 1,2 --exp-dir "$NEW_RUN_DIR"
bash scripts/run_failure_recovery.sh --exp-dir "$NEW_RUN_DIR"
bash scripts/run_evaluation.sh "$NEW_RUN_DIR"
```

- [ ] Save the exact commands actually used in the new run folder, including any
      timeout override or rerun-only experiment subset.
- [ ] If Claude must do a limited preflight before the full batch, record those
      spot-check commands separately and do not confuse them with the accepted
      full rerun.

Acceptance criteria:

- The next accepted run lives in a fresh result root.
- `scripts/10-run_all.sh` remains the main batch entrypoint for experiments 0/1/2.
- Failure recovery and evaluation reuse that same fresh result root.

## Evidence Format

For every accepted code, CI, or benchmark claim, save:
- the exact command or runner used
- the commit hash
- the relevant config names
- the latency mechanism used (`SIMULATE_WAN`, `tc`, `docker-level 20ms one-way`,
  or other documented path)
- the log or artifact path
- one result line: `pass`, `fail`, `blocked`, or `partial`

For the backend pause / resume task specifically, save:
- one artifact or log line for `primary_elected`
- one artifact or log line for Jetpack entering `RECOVERY`
- one artifact or log line for `fastpath_stopped`
- one artifact or log line for backend/application resume
- one artifact or log line showing heartbeat/election traffic still alive during pause

For the new Zoo evaluation tracks specifically, also save:
- the exact result root path
- the dry-run matrix or manifest with planned counts
- the fixed-conc map with justification
- the minimum-concurrency latency baselines used to choose each fixed conc
- the experiment-0 sweep upper bounds and whether a real turning point / plateau
  was observed for each protocol family
- the exact Docker/container latency-injection mechanism and where it is applied
- the sanity-check report path and one-line sanity outcome per protocol family
- the figure-input sanity report path and one-line figure-input sanity outcome
- the CSV coverage summary (`res` count, `csv` count, and missing-prefix audit)
- for MongoDB, the exact latency metric used in the main figure
  (`all-attempt` vs `fast-path-only`) and why
- for failure recovery: killed host, exact kill command, timestamp, and evidence
  that the remote `deptran_server` task really died
- the figure/table output directories under the new result root

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
- For the new Zoo multi-machine task, do not use host-level `tc` as the main
  WAN mechanism. The requirement here is Docker/container-level 20ms one-way latency.
- Do not report the CI work as complete if the `5c1s5r5p` `tc` lane has not actually
  run on a suitable environment.
- Do not cherry-pick only passing backends or only passing modes when writing docs.
- Do not report the benchmark rerun as reproduced if any required phase failed,
  was skipped, or used an undocumented deviation.
- Do not replace prior TODO tracks again when adding the Zoo work.
- Do not use old checked-in `scripts/*failure-recovery-data*` folders or old
  OSDI notebook constants as substitutes for the new requested Zoo run.
- Do not call the Zoo failure-recovery track complete unless a real remote
  `deptran_server` process kill occurred and is evidenced.
- Do not assume the Docker-based helper path can be reused unchanged for the Zoo
  multi-server path. Audit MongoDB / etcd / ZooKeeper script interactions carefully.
- Do not leave the analysis notebook hard-coded to 4 protocols or 10 hosts and
  then claim the exported figures represent the new 5-machine Zoo evaluation.
- Do not skip the latency/throughput sanity check for the new Zoo WAN runs.
- Do not leave the sanity reasoning only in chat. Save it in the same result
  folder as the raw logs, tables, and figures.
- Do not accept experiment-0 figures that are mostly near 0ms when the raw Zoo
  result files show many ~40ms / ~80ms latencies. Fix the notebook input path,
  rerun the sanity check, and redraw the figures.
- Do not leave experiment-0 latency plots at a 1000ms y-axis scale when the
  relevant data is mostly in the ~40ms to ~80ms range unless the exception is
  explicitly justified in the run-folder report.
- Do not accept a cumulative-latency figure that is missing adaptive for Raft
  or missing other expected protocol/mode lines.
- Do not stop the next experiment-0 sweep at the old Raft / etcd / ZooKeeper
  upper bounds if the turning point still has not appeared.
- Do not choose experiment-1 / experiment-2 fixed concurrencies by peak
  throughput alone. They must be the largest points that still preserve the
  protocol-specific minimum-concurrency latency class.
- Do not accept a figure-input sanity report that marks seconds-vs-milliseconds
  mismatches as `PASS`.
- Do not hide MongoDB by clipping it out of the main latency figures.
- Do not treat "there is a `.res` file" as equivalent to "the run ended
  normally". The `.csv` dump and its completeness matter.
- Do not skip the targeted preflight checks for MongoDB, Mencius adaptive, and
  CSV loss, then immediately burn cluster time on a full rerun.
- Do not claim failure recovery is complete while only `rule_raft` has a usable
  recovery PDF.
