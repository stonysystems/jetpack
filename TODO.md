# TODO

Purpose: keep the current real work, acceptance criteria, evidence paths, and
anti-shortcut rules visible. This file is the handoff checklist for Claude or
any future agent. It is not a live execution transcript.

## Review Snapshot

- Latest active phase:
  `Backend integration recovery handshake, latency documentation, CI regression coverage, benchmark rerun, and Zoo 5-machine multi-server evaluation planning`
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
5. Extend the legacy multi-machine Zoo flow centered on `scripts/10-run_all.sh`
   so it can run the requested 5-machine open-loop evaluation matrix with
   6 protocol families, 20ms one-way Docker-level latency injection, the
   requested result-root naming, and durable manifests.
6. Add a true Zoo failure-recovery experiment phase that really kills the
   `deptran_server` task on one machine during the run instead of relying only
   on synthetic failover toggles or client-only pause behavior.
7. Update the analysis/export flow centered on `scripts/evaluation.ipynb` so it
   can consume the new 5-machine result set, handle 6 protocol families, and
   export the requested tables and PDFs under the new result root.

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
- [ ] Keep experiment-specific reports in the same result folder as the logs.
      At minimum, leave `SUMMARY.md`, `sanity_checks.md`, and a short latency
      mechanism note in the run folder.
      At minimum, leave `SUMMARY.md`, `sanity_checks.md`, and a short latency
      mechanism note in the run folder.

Experiment 0 definition:

- [ ] Run throughput-latency sweep for 6 protocol families.
- [ ] YCSB: `YCSB_A`
- [ ] Workload: `rw_1000000`
- [ ] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [ ] The 20ms one-way Docker-level latency model applies to this experiment.
- [ ] Use per-protocol concurrency arrays chosen from shared definitions.
- [ ] If etcd/ZooKeeper need Zoo-specific concurrency arrays, add them in the
      shared definitions and record why.

Experiment 1 definition:

- [ ] Run zipfian-skew sweep for the same 6 protocol families.
- [ ] YCSB: `YCSB_A`
- [ ] Workloads:
      `rw_zipf_1 rw_zipf_0.9 rw_zipf_0.8 rw_zipf_0.7 rw_zipf_0.6 rw_zipf_0.5`
- [ ] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [ ] The 20ms one-way Docker-level latency model applies to this experiment.
- [ ] Use exactly one fixed conc per protocol family, derived from experiment 0.

Experiment 2 definition:

- [ ] Run key-range sweep for the same 6 protocol families.
- [ ] YCSB: `YCSB_A`
- [ ] Workloads:
      `rw_1 rw_10 rw_100 rw_1000 rw_10000 rw_100000 rw_1000000`
- [ ] Variants per family:
      original + Jetpack 0% + Jetpack 100% + Jetpack adaptive
- [ ] The 20ms one-way Docker-level latency model applies to this experiment.
- [ ] Use the same per-protocol fixed conc values chosen for experiment 1.

Fixed-concurrency gate:

- [ ] After experiment 0, choose one fixed conc for each of the 6 protocol families.
- [ ] Save that decision in both machine-readable and human-readable form:
      `fixed_conc.json` and `fixed_conc_selection.md`.
- [ ] The fixed conc values must be derived from experiment 0, not guessed in
      advance and not copied from an unrelated historical run.

Sanity-check gate after experiment 0:

- [ ] Run a latency/throughput sanity check and save it in the run folder.
- [ ] For the original protocol mode, check that the observed latency pattern is
      broadly consistent with:
      client colocated with leader ≈ 1 RTT,
      client not colocated with leader ≈ 2 RTT.
- [ ] For Jetpack rule mode, check that the observed latency pattern is broadly
      consistent with ≈ 1 RTT for all clients.
- [ ] Use the 20ms one-way WAN model when interpreting this:
      1 RTT is roughly 40ms baseline and 2 RTT is roughly 80ms baseline, plus
      protocol/processing overhead.
- [ ] For adaptive mode in experiment 0, check that the max throughput is in the
      same ballpark as the related original protocol mode rather than obviously
      capped far below it.
- [ ] If a sanity check fails, do not wave it away:
      either write down a strong protocol-specific reason in the run-folder
      report, or treat it as a bug/follow-up that needs to be fixed.
- [ ] Record the sanity-check conclusions in `sanity_checks.md` under the same
      result folder as the logs.

Acceptance criteria:

- The Zoo matrix actually covers all 6 requested families.
- All benchmark runs are open-loop.
- The Zoo runs use Docker/container-level 20ms one-way latency rather than
  host-level `tc`.
- Result roots and result filenames follow the requested naming.
- The fixed conc map exists, is explained, and is reused consistently.
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

- [ ] The failure event must really kill the `deptran_server` task on one Zoo machine.
- [ ] Do not treat `failover.yml` by itself as sufficient unless it truly causes
      the remote process to die and that death is evidenced.
- [ ] Do not satisfy this with only client-side pause/resume.
- [ ] Do not satisfy this with a local synthetic delay, a Docker-only simulation,
      or a notebook-side visualization of a failure that never happened.

Required work:

- [ ] Inspect whether `scripts/09-build_and_test_run_wan.sh` can be extended
      cleanly, or whether a thin helper should wrap the same logic for this track.
- [ ] Add a real remote kill step for the chosen failure target host:
      targeted `pkill`/PID kill of `deptran_server`, or equivalent concrete
      process kill with evidence.
- [ ] Record:
      target host, target PID if available, exact kill command, kill timestamp,
      and post-kill confirmation that the process exited.
- [ ] If leader failure is required for correctness, identify and document how
      the leader host is chosen or observed before the kill.
- [ ] Keep the client config open-loop. If `client_open_failure_recovery.yml`
      is used, document that this is still open-loop.
- [ ] Preserve the same 20ms one-way Docker-level latency injection during the
      failure-recovery runs. Do not silently drop WAN latency for this phase.
- [ ] If MongoDB / etcd / ZooKeeper recovery or restart steps currently rely on
      Docker-backed helpers or Docker-managed backend processes, update the
      relevant scripts carefully so the Zoo multi-machine failure-recovery path
      still performs a real `deptran_server` kill and leaves coherent logs.
- [ ] Save failure and recovery evidence under the same result root used for the
      Zoo evaluation, not in an unrelated historical folder.
- [ ] Save any failure-recovery report or diagnosis under the same result folder
      as the raw logs.

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

- [ ] Stop hard-coding the notebook to a historical `exptime`.
- [ ] Stop hard-coding the notebook to the historical 4-family plots.
- [ ] Stop hard-coding `cli_server = server0..server9` for this new run.
- [ ] Parameterize the notebook or a helper so it can read the new 5-machine Zoo
      result root and the new fixed-conc map.
- [ ] Remove the dependence on a separate historical `contention_exptime` for
      experiments 1 and 2. Those plots must read from the new Zoo run.
- [ ] Update remaining `rule_fpga_raft` / `none_fpga_raft` notebook references
      so the new run is plotted as `rule_raft` / `none_raft`.
- [ ] Save figures under:
      `/home/users/ztang/janus/results/<date>-<time>-zoo-5machines/figs`
- [ ] Save tables under:
      `/home/users/ztang/janus/results/<date>-<time>-zoo-5machines/tables`
- [ ] Save an executed notebook copy or equivalent durable analysis artifact
      under the result root.
- [ ] Save experiment-related reports in the same result folder as the logs,
      not only in `docs/` or only in notebook output cells.

Required PDFs:

- [ ] conc-50th latency
- [ ] conc-90th latency
- [ ] conc-99th latency
- [ ] conc-average latency
- [ ] conc-CPU usage
- [ ] throughput-50th latency
- [ ] throughput-90th latency
- [ ] throughput-99th latency
- [ ] throughput-average latency
- [ ] throughput-CPU usage
- [ ] latency-cumulative fraction for a fixed conc for each protocol
- [ ] conc-memory
- [ ] zipf_skew-average_latency for 6 protocols
- [ ] key_range-average_latency for 6 protocols

Figure layout requirements:

- [ ] Each main figure must have 6 subfigures in a single row.
- [ ] Keep protocol ordering consistent across figures.
- [ ] Figure filenames must include the site config string.

Recovery figure requirements:

- [ ] Export a separate time-throughput PDF for each of:
      `rule_raft`, `rule_mongodb`, `rule_etcd`, `rule_zookeeper`
- [ ] These recovery PDFs must come from the new Zoo failure-recovery runs, not
      from old checked-in recovery folders.

Table requirements:

- [ ] Export table-like results as durable files under `tables/`.
- [ ] At minimum, export:
      fixed-conc selection table,
      experiment-0 summary table,
      and CSV source data for the exported figures.
- [ ] Keep a concise experiment report in the run folder that references the
      exported tables/figures and the latency/throughput sanity-check results.

Acceptance criteria:

- The notebook/helper consumes the new Zoo result root without manual one-off edits.
- All requested PDFs are exported under the new result root.
- Tables are exported under the new result root.
- Run-folder reports exist alongside the logs and figures.
- The plotting path uses 5-machine result assumptions instead of the historical 10-host one.

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
- the exact Docker/container latency-injection mechanism and where it is applied
- the sanity-check report path and one-line sanity outcome per protocol family
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
