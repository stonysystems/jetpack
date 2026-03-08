# Codex Independent Evaluation Review Report

## 1. Scope

This report currently covers the first twenty-one high-priority leaf tasks from `TODO_codex.md`:

- `Phase 1A`: Low-concurrency latency sanity check.
- `Phase 1B`: Throughput sweep consistency check.
- `Phase 1C`: Failure-recovery sanity check.
- `Phase 2` first leaf: benchmark rerun prerequisites/build check.
- `Phase 2` next leaf: low-concurrency benchmark rerun (`etcd OFF`).
- `Phase 2` next leaf: low-concurrency benchmark rerun (`etcd ON` / rule mode).
- `Phase 2` next leaf: low-concurrency benchmark rerun (`mongodb OFF`).
- `Phase 2` next leaf: low-concurrency benchmark rerun (`mongodb ON` / rule mode).
- `Phase 2` next leaf: low-concurrency benchmark rerun (`zookeeper OFF`).
- `Phase 2` next leaf: low-concurrency benchmark rerun (`zookeeper ON` / rule mode).
- `Phase 2` next leaf: throughput sweep rerun (`etcd original` / `none_etcd.yml`).
- `Phase 2` next leaf: throughput sweep rerun (`etcd fastpath100` / `rule_etcd.yml -m 100`).
- `Phase 2` next leaf: throughput sweep rerun (`etcd adaptive` / `rule_etcd.yml`).
- `Phase 2` next leaf: throughput sweep rerun (`mongodb original` / `none_mongodb.yml`).
- `Phase 2` next leaf: throughput sweep rerun (`mongodb fastpath100` / `rule_mongodb.yml -m 100`).
- `Phase 2` next leaf: throughput sweep rerun (`mongodb adaptive` / `rule_mongodb.yml`).
- `Phase 2` next leaf: throughput sweep rerun (`zookeeper original` / `none_zookeeper.yml`).
- `Phase 2` next leaf: throughput sweep rerun (`zookeeper fastpath100` / `rule_zookeeper.yml -m 100`).
- `Phase 2` next leaf: throughput sweep rerun (`zookeeper adaptive` / `rule_zookeeper.yml`).
- `Phase 3` first leaf: failure-recovery rerun (`etcd`, WAN latency mode).
- `Phase 3` next leaf: failure-recovery rerun (`mongodb`, WAN latency mode).

Included in this pass:

- Internal consistency checks across `docs/latency_analysis.md`, `result.md`, and sweep artifacts.
- Numerical checks of latency deltas and sweep peak/status claims.
- Cross-check of canonical sweep files vs rerun/archive history for contradictions.
- Recovery-model checks against `docs/failure_recovery_evaluation.md`, `result.md`, and committed recovery logs.
- Phase-2 prerequisite verification (Docker, compose, submodules, ulimit, backend image build attempts).
- Low-concurrency rerun execution (`etcd OFF`, `etcd ON`, `mongodb OFF`, `mongodb ON`, `zookeeper OFF`, `zookeeper ON`) with captured command transcripts and per-run metrics.
- Throughput-sweep rerun execution (`etcd original`, `etcd fastpath100`, `etcd adaptive`, `mongodb original`, `mongodb fastpath100`, `mongodb adaptive`, `zookeeper original`, `zookeeper fastpath100`, `zookeeper adaptive`) with per-concurrency comparison to canonical sweep artifacts.
- Failure-recovery rerun execution (`etcd`, WAN latency mode) with extracted election/recovery timing and signal-chain evidence.
- Failure-recovery rerun attempts (`mongodb`, WAN latency mode) with startup-failure diagnostics and retry/cleanup evidence.

Not yet executed in this report:

- Remaining `Phase 3` recovery reruns (`zookeeper`; 1 of 3 matrix cases still pending).

## 2. Environment

- UTC timestamp (this iteration): 2026-03-08T02:13:19Z
- Git branch: `jetpack`
- Repository root: `/home/shuai/workspace/jetpack`
- Build/test environment blockers observed:
  - `./test_run.py` fails when `build/deptran_server` is missing, then hits a pre-existing `NameError` (`except Error`) in the script.
  - `python3 waf configure build -d` fails on Python 3.13 (`ModuleNotFoundError: imp` in waflib).
  - `python2 waf configure build -d -D` starts compiling but fails due missing backend client headers/libraries (`mongocxx/instance.hpp`, `zookeeper/zookeeper.h`, `etcd/SyncClient.hpp`).

## 3. Docs Reviewed

- `TODO_codex.md`
- `docs/benchmark_runbook.md`
- `docs/latency_analysis.md`
- `docs/failure_recovery_evaluation.md`
- `result.md`
- `docs/sweep_2026-02-28/README.md`
- `docs/sweep_2026-02-28/CANONICAL_INDEX.md`
- `docs/sweep_2026-02-28/FAILURE_LEDGER.md`
- `docs/sweep_2026-02-28/*.tsv`
- `docs/sweep_2026-02-28/rerun_results.tsv`
- `docs/sweep_2026-02-28/archive/*.tsv`
- `docs/sweep_2026-02-28/consolidated.csv`
- `docs/logs/*_recovery_gap_fix_wan_r*.txt`
- `docs/logs/*_recovery_v2.txt`
- `docs/logs/*_recovery.txt`
- `docker/etcd/docker-compose.yml`
- `docker/mongodb/docker-compose.yml`
- `docker/zookeeper/docker-compose.yml`

## 4. Existing Claims Checked

### A. Low-Concurrency Latency (Phase 1A)

Checked values in `docs/latency_analysis.md` and `result.md`:

- etcd OFF: `43.6 / 83.7`, ON: `40.4 / 40.7`
- MongoDB OFF: `47.7 / 88.0`, ON: `45.2 / 45.9`
- ZooKeeper OFF: `45.5 / 86.0`, ON: `40.3 / 40.5`

### B. Throughput Sweep (Phase 1B)

Checked claims in `docs/latency_analysis.md` and sweep docs:

- Peak summary:
  - etcd: `7687` (original), `6749` (fastpath-100), `7323` (adaptive)
  - MongoDB: `3799` (original), `3200` (fastpath-100), `3858` (adaptive)
  - ZooKeeper: `5648` (original), `5456` (fastpath-100), `5486` (adaptive)
- Status claim: `99/99 OK` points in canonical sweep.

Also checked throughput tables in `result.md` (high-concurrency and max-throughput sections) against canonical TSVs.

### C. Failure Recovery (Phase 1C)

Checked claims in `docs/failure_recovery_evaluation.md`, `result.md`, and committed recovery logs:

- Formula claim at RTT=40ms: expected Jetpack downtime/recovery duration near `1ms poll + 2*RTT = ~81ms`.
- Published 3x3 WAN repetitions (etcd/MongoDB/ZooKeeper, 3 reps each).
- Qualitative backend re-election claims:
  - etcd variable and can reach multi-second.
  - MongoDB around 10-13 seconds.
  - ZooKeeper sub-second to about 1 second.

### D. Phase 2 Prerequisites/Build Readiness

Checked prerequisite claims before reruns:

- `docker --version`: available.
- `docker compose version`: available.
- `git submodule status --recursive`: submodules present/initialized.
- `ulimit -n`: `524288` (well above `65536` guidance).
- Backend image build readiness:
  - etcd build attempt from runbook command did not reach compile stage within bounded window due very large Docker context transfer.
  - MongoDB build attempt likewise timed out during large context transfer.
  - ZooKeeper build failed quickly with upstream fetch error (`invalid response status 404` from `downloads.apache.org` URL in Dockerfile).

### E. Phase 2 Low-Concurrency Rerun: etcd OFF

Checked rerun target:

- `etcd OFF` low-concurrency sanity case using runbook-compatible command shape with explicit overrides to match documented topology (`60c1s5r5p.yml`, `concurrent_1.yml`, `none_etcd.yml`, `LATENCY_MS=20`).

### F. Phase 2 Low-Concurrency Rerun: etcd ON (rule mode)

Checked rerun target:

- `etcd ON` low-concurrency sanity case using the same topology/concurrency/latency settings, with `MODE_CONFIG=rule_etcd.yml` for Jetpack rule mode.

### G. Phase 2 Low-Concurrency Rerun: mongodb OFF

Checked rerun target:

- `mongodb OFF` low-concurrency sanity case under runbook-aligned settings (`none_mongodb.yml`, `60c1s5r5p.yml`, `concurrent_1.yml`, `LATENCY_MS=20`).
- Due deterministic pre-benchmark verification failures in default command when MongoDB primary was not `127.0.0.1`, I additionally used script-supported `MONGODB_ENDPOINTS` replica-set URI override for retry attempts.

### H. Phase 2 Low-Concurrency Rerun: mongodb ON (rule mode)

Checked rerun target:

- `mongodb ON` low-concurrency sanity case under runbook-aligned settings (`rule_mongodb.yml`, `60c1s5r5p.yml`, `concurrent_1.yml`, `LATENCY_MS=20`).
- Because default verification can be primary-dependent (`mongodb://127.0.0.1:27017`), I also tested script-supported `MONGODB_ENDPOINTS` replica-set URI override.

### I. Phase 2 Low-Concurrency Rerun: zookeeper OFF

Checked rerun target:

- `zookeeper OFF` low-concurrency sanity case under runbook-aligned settings (`none_zookeeper.yml`, `60c1s5r5p.yml`, `concurrent_1.yml`, `LATENCY_MS=20`).

### J. Phase 2 Low-Concurrency Rerun: zookeeper ON (rule mode)

Checked rerun target:

- `zookeeper ON` low-concurrency sanity case under runbook-aligned settings (`rule_zookeeper.yml`, `60c1s5r5p.yml`, `concurrent_1.yml`, `LATENCY_MS=20`).

## 5. Sanity Check Review

### A. Low-Concurrency Latency Verdict

Computed delta checks:

| Backend | OFF h1 | OFF h2-h5 | OFF delta | ON h1 | ON h2-h5 |
|---|---:|---:|---:|---:|---:|
| etcd | 43.6 | 83.7 | 40.1 | 40.4 | 40.7 |
| MongoDB | 47.7 | 88.0 | 40.3 | 45.2 | 45.9 |
| ZooKeeper | 45.5 | 86.0 | 40.5 | 40.3 | 40.5 |

Findings:

- OFF mode matches `h2-h5 ~= h1 + 40ms` for all three backends.
- ON mode etcd/ZooKeeper stays near 40ms.
- ON mode MongoDB is consistently +5 to +6ms above the 40ms idealized model.

### B. Throughput Sweep Consistency Verdict

Canonical TSV verification (`docs/sweep_2026-02-28/{backend}_{mode}.tsv`):

- Each canonical file has `11/11` rows with `status=OK`.
- Total canonical rows: `99/99 OK`.
- `consolidated.csv` also reports `99/99 OK`.
- Peak values quoted in `docs/latency_analysis.md`, `README.md`, and `CANONICAL_INDEX.md` match TSV maxima after rounding:
  - etcd original `7686.60` -> `7,687`
  - MongoDB fastpath-100 `3199.60` -> `3,200`
  - ZooKeeper original `5647.60` -> `5,648`
  - Other quoted peaks match similarly.

Mode naming consistency check:

- Semantics are consistent, but string forms vary:
  - `fastpath100` (filename/dataset id)
  - `fastpath-100` (README/CANONICAL/ledger tables)
  - `FP 100%` / `Fast path 100%` (`docs/latency_analysis.md`)
- This is readable but not strictly normalized.

Cross-check vs `result.md` throughput prose/tables:

- `result.md` throughput tables are not consistent with the canonical 9-case sweep artifacts.
- Examples:
  - `result.md` max table reports MongoDB OFF max `2304` and ON max `1966`, while canonical sweep shows MongoDB original `3799` and adaptive `3858` (fastpath-100 `3200`).
  - `result.md` high-concurrency c=200 reports MongoDB OFF `2135` and ON `2160`; canonical c=200 rows are substantially higher (`3642` original, `3200` fastpath-100, `3542` adaptive).
- Conclusion: throughput claims in `docs/latency_analysis.md` align with canonical sweep artifacts; throughput tables in `result.md` appear stale or from a different run/config that is not linked to canonical sweep files.

Rerun/archive contradiction check:

- `FAILURE_LEDGER.md` states 12 prior zero-throughput points and successful reruns; this is consistent with `rerun_results.tsv` entries.
- `rerun_results.tsv` values for those 12 points differ from final canonical TSV rows at the same dataset/concurrency by roughly `-10.6%` to `+12.4%` in some cases.
- This is not a direct contradiction (ledger is explicitly historical/superseded), but it indicates non-trivial run-to-run variance for several points.

### C. Failure-Recovery Consistency Verdict

Artifact-backed WAN 3x3 check (from committed logs `docs/logs/*_recovery_gap_fix_wan_r*.txt`):

| Backend | Rep1 internal (ms) | Rep2 internal (ms) | Rep3 internal (ms) | Expected (~81ms) | Status |
|---|---:|---:|---:|---:|---|
| etcd | 82 | 81 | 81 | ~81 | Match |
| MongoDB | 83 | 81 | 81 | ~81 | Match |
| ZooKeeper | 83 | 82 | 81 | ~81 | Match |

Backend re-election from the same logs:

| Backend | Rep1 (ms) | Rep2 (ms) | Rep3 (ms) | Qualitative claim check |
|---|---:|---:|---:|---|
| etcd | 1106 | 6973 | 1556 | Variable, includes multi-second cases -> consistent |
| MongoDB | 10496 | 12710 | 11091 | Around 10-13s -> consistent |
| ZooKeeper | 862 | 789 | 776 | Sub-second to about 1s -> consistent |

Key interpretation:

- The 3x3 WAN internal durations (`81-83ms`) support the RTT-based recovery model.
- However, logs also include script-measured `Jetpack downtime` lines that differ substantially (for example MongoDB rep2 shows `323ms`) while the internal recovery line is `81ms`.
- Therefore the docs are only consistent if "sanity-check metric" is interpreted as internal recovery duration (`duration=`), not script detection time.

Internal-document consistency review:

- `docs/failure_recovery_evaluation.md` and `result.md` include both pre-fix gap narratives and post-fix 81-83ms PASS narratives.
- In `docs/failure_recovery_evaluation.md`, some status rows are marked `RESOLVED` while later sections still mark related items `OPEN`, which is internally inconsistent.
- The pre-fix RTT=40ms internal-duration numbers (`~124-128ms`, `~162-184ms`) are described, but I did not find matching committed `docs/logs/*.txt` artifacts containing those exact internal-duration lines; available committed logs clearly support the post-fix 81-83ms runs plus older 0ms/single-process runs.

## 6. Benchmark Rerun Attempts

Phase 2 prerequisite/build checks executed. Fresh-image rebuild remains blocked by the build issues above, but reruns were still possible using pre-existing local images:

- Prerequisite checks:
  - Docker: PASS
  - Docker Compose: PASS
  - Submodule availability: PASS
  - File descriptor limit (`ulimit -n`): PASS
- Build checks:
  - etcd image: BLOCKED (context-transfer timeout; command did not reach build completion)
  - MongoDB image: BLOCKED (context-transfer timeout; command did not reach build completion)
  - ZooKeeper image: FAILED (upstream tarball URL returned 404 during `ADD`)

Low-concurrency rerun attempts executed using pre-existing local backend images (`jetpack-etcd`, `jetpack-mongodb`, `jetpack-zookeeper`):

Command used:

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_etcd.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-etcd benchmark
```

| Attempt UTC | Status | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Assessment vs docs |
|---|---|---|---:|---:|---:|---:|---|
| 2026-03-07T20:29:26Z | Completed | `/tmp/codex_phase2_etcd_off_20260307T202926Z.log` | 22.99 | 62.76 | 39.77 | 39.80 | Contradicts absolute latency level (too low), but matches +40ms delta model |
| 2026-03-07T20:32:00Z | Completed | `/tmp/codex_phase2_etcd_off_20260307T203200Z.log` | 43.91 | 83.35 | 39.44 | 40.10 | Roughly matches published etcd OFF (`43.6/83.7`) and +40ms delta |
| 2026-03-07T20:34:50Z | Completed | `/tmp/codex_phase2_etcd_off_20260307T203450Z.log` | 43.09 | 83.30 | 40.21 | 40.30 | Roughly matches published etcd OFF (`43.6/83.7`) and +40ms delta |

Interpretation (`etcd OFF`):

- 2/3 reruns support the published etcd OFF latency range.
- 1/3 rerun is an outlier with ~20ms lower absolute latencies while preserving the expected +40ms h1->h2-h5 gap.
- This increases confidence in the latency-delta model but indicates run-to-run instability in absolute backend write latency.

Second low-concurrency rerun set (`etcd ON`, rule mode):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_etcd.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-etcd benchmark
```

| Attempt UTC | Status | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Fast-path success rate | Assessment vs docs |
|---|---|---|---:|---:|---:|---:|---:|---|
| 2026-03-07T20:38:15Z | Completed | `/tmp/codex_phase2_etcd_on_20260307T203815Z.log` | 40.29 | 40.44 | 0.15 | 39.50 | 100.00% | Roughly matches published etcd ON (`40.4/40.7`); consistent one-RTT behavior |
| 2026-03-07T20:39:44Z | Completed | `/tmp/codex_phase2_etcd_on_20260307T203944Z.log` | 40.29 | 40.47 | 0.18 | 40.10 | 100.00% | Roughly matches published etcd ON (`40.4/40.7`); consistent one-RTT behavior |
| 2026-03-07T20:41:11Z | Completed | `/tmp/codex_phase2_etcd_on_20260307T204111Z.log` | 40.31 | 40.45 | 0.14 | 39.90 | 100.00% | Roughly matches published etcd ON (`40.4/40.7`); consistent one-RTT behavior |

Interpretation (`etcd ON`):

- 3/3 reruns closely match the documented ON-mode latency range for etcd.
- `h1` and `h2-h5` stay within ~0.2ms, consistent with the fast-path one-RTT model.
- Fast-path success was `100%` in all three runs at concurrency 1.

Third low-concurrency rerun set (`mongodb OFF`, none mode):

Default runbook-shape command:

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

Retry command with script-supported replica-set endpoint override:

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e MONGODB_ENDPOINTS='mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=jetpack-rs' \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

| Attempt UTC | Status | Primary elected | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Assessment vs docs |
|---|---|---|---|---:|---:|---:|---:|---|
| 2026-03-07T20:45:47Z | Failed (verification write) | 127.0.0.2 | `/tmp/codex_phase2_mongodb_off_20260307T204547Z.log` | N/A | N/A | N/A | N/A | Non-supporting: default command failed pre-benchmark |
| 2026-03-07T20:46:26Z | Failed (verification write) | 127.0.0.2 | `/tmp/codex_phase2_mongodb_off_20260307T204626Z.log` | N/A | N/A | N/A | N/A | Non-supporting: default command failed pre-benchmark |
| 2026-03-07T20:47:16Z | Completed (override) | 127.0.0.1 | `/tmp/codex_phase2_mongodb_off_20260307T204716Z.log` | 8.76 | 47.86 | 39.10 | 40.50 | Contradicts published MongoDB OFF absolute levels (`47.7/88.0`) |
| 2026-03-07T20:51:04Z | Interrupted by operator before summary (override) | 127.0.0.3 | `/tmp/codex_phase2_mongodb_off_20260307T205104Z.log` | N/A | N/A | N/A | N/A | Non-supporting: incomplete attempt |
| 2026-03-07T20:55:56Z | Interrupted by operator before summary (override) | 127.0.0.1 | `/tmp/codex_phase2_mongodb_off_20260307T205556Z.log` | N/A | N/A | N/A | N/A | Non-supporting: incomplete attempt |

Interpretation (`mongodb OFF`):

- With default runbook command, rerun did not complete due pre-benchmark MongoDB write verification failures when primary was not `127.0.0.1`.
- Replica-set endpoint override enabled verification and yielded one complete run, but that run materially contradicts published MongoDB OFF absolute latencies (`8.76/47.86` observed vs `47.7/88.0` documented) while preserving an internal ~40ms host delta.
- Additional override retries in this iteration were manually interrupted before summaries while I was still characterizing runtime behavior; they do not provide supporting evidence either way.

Fourth low-concurrency rerun set (`mongodb ON`, rule mode):

Default runbook-shape command:

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

Retry command with script-supported replica-set endpoint override:

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_mongodb.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e MONGODB_ENDPOINTS='mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=jetpack-rs' \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-mongodb benchmark
```

| Attempt UTC | Status | Endpoint mode | Primary elected | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Fast-path success rate | Assessment vs docs |
|---|---|---|---|---|---:|---:|---:|---:|---:|---|
| 2026-03-07T21:00:57Z | Interrupted by operator before summary | default | 127.0.0.1 | `/tmp/codex_phase2_mongodb_on_20260307T210057Z.log` | N/A | N/A | N/A | N/A | N/A | Non-supporting: incomplete attempt |
| 2026-03-07T21:03:25Z | Interrupted by operator before summary | default | 127.0.0.1 | `/tmp/codex_phase2_mongodb_on_20260307T210325Z.log` | N/A | N/A | N/A | N/A | N/A | Non-supporting: incomplete attempt |
| 2026-03-07T21:05:00Z | Completed | default | 127.0.0.1 | `/tmp/codex_phase2_mongodb_on_20260307T210500Z.log` | 8.91 | 42.20 | 33.29 | 40.50 | 100.00% | Contradicts published MongoDB ON absolute and cross-host values (`45.2/45.9`) |
| 2026-03-07T21:08:26Z | Failed (verification write) | default | 127.0.0.2 | `/tmp/codex_phase2_mongodb_on_20260307T210826Z.log` | N/A | N/A | N/A | N/A | N/A | Non-supporting: pre-benchmark verification failed |
| 2026-03-07T21:08:53Z | Timed out (no summary) | override | 127.0.0.3 | `/tmp/codex_phase2_mongodb_on_20260307T210853Z.log` | N/A | N/A | N/A | N/A | N/A | Non-supporting: no benchmark summary emitted before timeout |
| 2026-03-07T21:13:04Z | Completed | default | 127.0.0.1 | `/tmp/codex_phase2_mongodb_on_20260307T211304Z.log` | 8.87 | 42.14 | 33.27 | 40.30 | 100.00% | Contradicts published MongoDB ON absolute and cross-host values (`45.2/45.9`) |

Interpretation (`mongodb ON`):

- Completed runs (2/6 attempts) are internally consistent with each other (`h1 ~8.9ms`, `h2-h5 ~42.2ms`, fast-path `100%`), but they do not match published MongoDB ON low-concurrency expectations (`45.2/45.9`, near-uniform across hosts).
- One default attempt failed pre-benchmark when elected primary was `127.0.0.2`.
- One override attempt timed out without summaries, and two early attempts were manually interrupted before summary output while runtime characteristics were still being characterized.
- Overall, MongoDB ON low-concurrency rerun is non-supporting in the current environment.

Fifth low-concurrency rerun set (`zookeeper OFF`, none mode):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=none_zookeeper.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-zookeeper benchmark
```

| Attempt UTC | Status | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Assessment vs docs |
|---|---|---|---:|---:|---:|---:|---|
| 2026-03-07T21:20:36Z | Completed | `/tmp/codex_phase2_zookeeper_off_20260307T212036Z.log` | 43.15 | 83.29 | 40.14 | 39.50 | Roughly matches model and published ZK OFF trend; absolute values slightly lower than `45.5/86.0` |
| 2026-03-07T21:21:59Z | Completed | `/tmp/codex_phase2_zookeeper_off_20260307T212159Z.log` | 42.80 | 82.87 | 40.07 | 40.20 | Roughly matches model and published ZK OFF trend; absolute values slightly lower than `45.5/86.0` |
| 2026-03-07T21:23:21Z | Completed | `/tmp/codex_phase2_zookeeper_off_20260307T212321Z.log` | 43.43 | 83.14 | 39.71 | 40.70 | Roughly matches model and published ZK OFF trend; absolute values slightly lower than `45.5/86.0` |

Interpretation (`zookeeper OFF`):

- 3/3 reruns completed and were internally consistent.
- All runs preserve the expected OFF-mode host delta of about +40ms (`h2-h5 ~= h1 + 40ms`).
- Absolute levels are consistently ~2-3ms lower than the published `45.5/86.0`, but still in the same rough range and fully consistent with the stated latency model.

Sixth low-concurrency rerun set (`zookeeper ON`, rule mode):

```bash
docker run --rm --privileged \
  -e SITE_CONFIG=60c1s5r5p.yml \
  -e MODE_CONFIG=rule_zookeeper.yml \
  -e CLIENT_CONFIG=client_open.yml \
  -e CONCURRENT_CONFIG=concurrent_1.yml \
  -e LATENCY_MS=20 \
  -e LATENCY_JITTER=0 \
  -e TEST_DURATION=30 \
  jetpack-zookeeper benchmark
```

| Attempt UTC | Status | Stdout/stderr capture | h1 avg (ms) | h2-h5 avg (ms) | h2-h5 - h1 (ms) | Total throughput | Fast-path success rate | Assessment vs docs |
|---|---|---|---:|---:|---:|---:|---:|---|
| 2026-03-07T21:27:27Z | Completed | `/tmp/codex_phase2_zookeeper_on_20260307T212727Z.log` | 40.28 | 40.37 | 0.09 | 41.00 | 100.00% | Roughly matches published ZK ON (`40.3/40.5`); consistent one-RTT behavior |
| 2026-03-07T21:28:52Z | Completed | `/tmp/codex_phase2_zookeeper_on_20260307T212852Z.log` | 40.33 | 40.44 | 0.11 | 40.70 | 100.00% | Roughly matches published ZK ON (`40.3/40.5`); consistent one-RTT behavior |
| 2026-03-07T21:30:23Z | Completed | `/tmp/codex_phase2_zookeeper_on_20260307T213023Z.log` | 40.28 | 40.37 | 0.09 | 40.00 | 100.00% | Roughly matches published ZK ON (`40.3/40.5`); consistent one-RTT behavior |

Interpretation (`zookeeper ON`):

- 3/3 reruns completed and were tightly clustered.
- `h1` and `h2-h5` remain within ~0.1ms, consistent with ON-mode one-RTT behavior.
- Fast-path success was `100%` in all three runs at concurrency 1.

First throughput-sweep rerun set (`etcd original`, `none_etcd.yml`):

To avoid writing large generated logs into tracked docs paths during this iteration, I executed a temporary copy of `scripts/sweep_benchmark.sh` with `LOG_DIR` redirected to `/tmp`:

```bash
sed 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark.sh
chmod +x /tmp/codex_sweep_benchmark.sh
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd none_etcd.yml > /tmp/codex_phase2_sweep_etcd_original_20260307T213527Z.tsv 2> /tmp/codex_phase2_sweep_etcd_original_20260307T213527Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.10 | 39.90 | -2.01% | OK |
| 5 | 274.40 | 272.40 | +0.73% | OK |
| 10 | 569.90 | 568.00 | +0.33% | OK |
| 25 | 1469.50 | 1471.70 | -0.15% | OK |
| 50 | 2966.80 | 2974.70 | -0.27% | OK |
| 75 | 4458.70 | 4458.40 | +0.01% | OK |
| 100 | 5945.40 | 5949.40 | -0.07% | OK |
| 150 | 6322.90 | 7616.40 | -16.98% | OK |
| 200 | 6146.90 | 7686.60 | -20.03% | OK |
| 300 | 5612.50 | 6977.20 | -19.56% | OK |
| 400 | 5285.30 | 6915.20 | -23.57% | OK |

Interpretation (`etcd original` throughput sweep rerun):

- Sweep completed `11/11` points with `status=OK` and `retry_count=0` for all points.
- Throughput closely matches canonical at `c <= 100` (within roughly `-2.0%` to `+0.7%`).
- High-concurrency points (`c >= 150`) are materially lower than canonical (`~17%` to `~24%` deficit).
- Rerun peak is `6322.90 @ c=150`, below canonical peak `7686.60 @ c=200` (about `-17.7%`).
- This case is partially supporting: shape and low/mid-concurrency levels reproduce well, but published high-concurrency capacity was not reproduced in this environment.

Second throughput-sweep rerun set (`etcd fastpath100`, `rule_etcd.yml`, `-m 100`):

```bash
sed 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark.sh
chmod +x /tmp/codex_sweep_benchmark.sh
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd rule_etcd.yml "-m 100" > /tmp/codex_phase2_sweep_etcd_fastpath100_20260307T215653Z.tsv 2> /tmp/codex_phase2_sweep_etcd_fastpath100_20260307T215653Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.70 | 39.90 | -0.50% | OK |
| 5 | 270.60 | 274.70 | -1.49% | OK |
| 10 | 564.60 | 566.70 | -0.37% | OK |
| 25 | 1470.70 | 1465.60 | +0.35% | OK |
| 50 | 2969.70 | 2968.70 | +0.03% | OK |
| 75 | 4472.00 | 4464.60 | +0.17% | OK |
| 100 | 5939.40 | 5938.30 | +0.02% | OK |
| 150 | 5926.10 | 4817.60 | +23.01% | OK |
| 200 | 5756.30 | 6064.80 | -5.09% | OK |
| 300 | 5342.90 | 6448.80 | -17.15% | OK |
| 400 | 4931.40 | 6749.30 | -26.93% | OK |

Interpretation (`etcd fastpath100` throughput sweep rerun):

- Sweep completed `11/11` points with `status=OK` and `retry_count=0` for all points.
- Throughput closely matches canonical at `c <= 100` (within roughly `-1.5%` to `+0.4%`).
- High-concurrency behavior diverges materially: `+23.0%` at `c=150`, then deficits at `c=200/300/400` (`-5.1%`, `-17.2%`, `-26.9%`).
- Rerun peak is `5939.40 @ c=100`, while canonical peak is `6749.30 @ c=400` (about `-12.0%` lower and at a different concurrency).
- This case is also partially supporting: low/mid-concurrency reproduction is strong, but high-concurrency shape and peak location do not reproduce.

Third throughput-sweep rerun set (`etcd adaptive`, `rule_etcd.yml`):

```bash
sed 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark.sh
chmod +x /tmp/codex_sweep_benchmark.sh
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd rule_etcd.yml > /tmp/codex_phase2_sweep_etcd_adaptive_20260307T221731Z.tsv 2> /tmp/codex_phase2_sweep_etcd_adaptive_20260307T221731Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.20 | 39.70 | -1.26% | OK |
| 5 | 274.10 | 271.60 | +0.92% | OK |
| 10 | 568.30 | 574.40 | -1.06% | OK |
| 25 | 1470.80 | 1465.50 | +0.36% | OK |
| 50 | 2966.40 | 2964.20 | +0.07% | OK |
| 75 | 4466.60 | 4462.90 | +0.08% | OK |
| 100 | 5964.00 | 5925.00 | +0.66% | OK |
| 150 | 6013.20 | 6955.60 | -13.55% | OK |
| 200 | 5997.90 | 7323.30 | -18.10% | OK |
| 300 | 5583.00 | 6789.50 | -17.77% | OK |
| 400 | 5158.70 | 6051.40 | -14.75% | OK |

Interpretation (`etcd adaptive` throughput sweep rerun):

- Sweep completed `11/11` points with `status=OK` and `retry_count=0` for all points.
- Throughput closely matches canonical at `c <= 100` (within roughly `-1.3%` to `+0.9%`).
- High-concurrency points are lower than canonical (`c=150..400` about `-13.6%` to `-18.1%`).
- Rerun peak is `6013.20 @ c=150`, below canonical peak `7323.30 @ c=200` (about `-17.9%`).
- This case is partially supporting: low/mid-concurrency behavior reproduces well, but published high-concurrency capacity was not reproduced.

Fourth throughput-sweep rerun set (`mongodb original`, `none_mongodb.yml`):

```bash
sed 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark.sh
chmod +x /tmp/codex_sweep_benchmark.sh
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-mongodb none_mongodb.yml > /tmp/codex_phase2_sweep_mongodb_original_final_20260307T224600Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_original_final_20260307T224600Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 40.00 | 40.90 | -2.20% | OK |
| 5 | 273.60 | 275.40 | -0.65% | OK |
| 10 | 571.70 | 569.10 | +0.46% | OK |
| 25 | 1466.00 | 1457.40 | +0.59% | OK |
| 50 | 2960.80 | 2969.90 | -0.31% | OK |
| 75 | 3162.60 | 3728.40 | -15.18% | OK |
| 100 | 2896.00 | 3799.30 | -23.78% | OK |
| 150 | 2647.40 | 3766.80 | -29.72% | OK |
| 200 | 2939.90 | 3641.80 | -19.27% | OK |
| 300 | 2539.70 | 3460.00 | -26.60% | OK |
| 400 | 2080.00 | 3148.70 | -33.94% | OK |

Interpretation (`mongodb original` throughput sweep rerun):

- Final sweep completed `11/11` points with `status=OK` on all points.
- Throughput is close to canonical up to `c=50` (within about `-2.2%` to `+0.6%`), then drops well below canonical from `c=75` onward (`-15.2%` to `-33.9%`).
- Rerun peak is `3162.60 @ c=75`, below canonical peak `3799.30 @ c=100` (about `-16.8%`), and capacity falls further at higher concurrency.
- Several points required retries (`c=50`, `c=100`, `c=200`, `c=400` with retry counts `1/1/1/2`), indicating stability pressure at moderate/high load.
- Two exploratory attempts in this iteration were terminated before any data row was emitted while characterizing unusually long point runtime; the completed run above is the authoritative evidence.

Fifth throughput-sweep rerun set (`mongodb fastpath100`, `rule_mongodb.yml`, `-m 100`):

Exploratory default sweep attempt (terminated during `c=10` stall):

```bash
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-mongodb rule_mongodb.yml "-m 100" > /tmp/codex_phase2_sweep_mongodb_fastpath100_20260307T233231Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_fastpath100_20260307T233231Z.stderr.log
```

Authoritative timeout-guarded sweep used for final evidence:

```bash
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh jetpack-mongodb rule_mongodb.yml "-m 100" > /tmp/codex_phase2_sweep_mongodb_fastpath100_final_20260307T234259Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_fastpath100_final_20260307T234259Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.60 | 40.10 | -1.25% | OK |
| 5 | 271.20 | 274.00 | -1.02% | OK |
| 10 | 568.70 | 572.70 | -0.70% | OK |
| 25 | 1467.00 | 1473.80 | -0.46% | OK |
| 50 | 2058.50 | 2104.20 | -2.17% | OK |
| 75 | 2276.30 | 2715.30 | -16.17% | OK |
| 100 | 2398.70 | 2947.60 | -18.62% | OK |
| 150 | 2426.60 | 2506.70 | -3.20% | OK |
| 200 | 2473.40 | 3199.60 | -22.70% | OK |
| 300 | 2200.00 | 2880.00 | -23.61% | OK |
| 400 | 1227.10 | 2920.00 | -57.98% | FAILED |

Interpretation (`mongodb fastpath100` throughput sweep rerun):

- Final sweep emitted all `11/11` rows, with `10/11` rows `OK` and one terminal failure (`c=400`, `FAILED`, `retry_count=2`, `docker_exit_1;timeout`).
- Throughput tracks canonical closely for `c <= 50` (about `-0.5%` to `-2.2%`), then diverges materially at higher concurrency.
- At `c=75..300`, rerun throughput is generally below canonical by about `16%` to `24%`; `c=400` degrades much further and fails (`-58%` vs canonical throughput value).
- Rerun peak is `2473.40 @ c=200`, below canonical peak `3199.60 @ c=200` (about `-22.7%`).
- Fast-path success collapses as concurrency rises (`100%` at `c<=10`, `98.14%` at `c=25`, `2.40%` at `c=50`, `0.45%` at `c=75`, and `0` from `c>=100`).
- Overall this case is non-supporting for high-concurrency fastpath100 claims in the current environment: low-concurrency behavior is reproducible, but high-concurrency capacity and stability are not.

Sixth throughput-sweep rerun set (`mongodb adaptive`, `rule_mongodb.yml`):

```bash
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh jetpack-mongodb rule_mongodb.yml > /tmp/codex_phase2_sweep_mongodb_adaptive_final_20260308T002834Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_adaptive_final_20260308T002834Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.70 | 40.00 | -0.75% | OK |
| 5 | 272.70 | 274.10 | -0.51% | OK |
| 10 | 575.30 | 563.30 | +2.13% | OK |
| 25 | 1466.40 | 1465.50 | +0.06% | OK |
| 50 | 2925.80 | 2964.80 | -1.32% | OK |
| 75 | 3242.90 | 3849.90 | -15.77% | OK |
| 100 | 3019.10 | 3858.30 | -21.75% | OK |
| 150 | 2861.90 | 3670.30 | -22.03% | OK |
| 200 | 2639.00 | 3542.10 | -25.50% | OK |
| 300 | 2500.00 | 3200.00 | -21.88% | OK |
| 400 | 2160.00 | 1659.80 | +30.14% | OK |

Interpretation (`mongodb adaptive` throughput sweep rerun):

- Final sweep completed `11/11` points with `status=OK` on all points and `retry_count=0` for all points.
- Throughput matches canonical closely at low/mid concurrency through `c=50` (about `-1.3%` to `+2.1%`).
- At `c=75..300`, rerun throughput underperforms canonical by about `15.8%` to `25.5%`, with peak shifting lower.
- Rerun peak is `3242.90 @ c=75`, below canonical peak `3858.30 @ c=100` (about `-15.9%` and at lower concurrency).
- At `c=400`, rerun throughput is above canonical (`+30.1%`), producing a non-monotonic tail relative to canonical shape.
- Fast-path success starts near `100%` at low concurrency, then varies in the mid-high range (`~66.5%` to `85.9%`), indicating substantial adaptive mode-path mix changes under load.
- Overall this case is partially supporting: low/mid-concurrency values reproduce well, but high-concurrency capacity/shape diverges materially from canonical.

Seventh throughput-sweep rerun set (`zookeeper original`, `none_zookeeper.yml`):

```bash
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_original_timeout.sh jetpack-zookeeper none_zookeeper.yml > /tmp/codex_phase2_sweep_zookeeper_original_final_20260308T010749Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_original_final_20260308T010749Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 40.40 | 39.60 | +2.02% | OK |
| 5 | 271.70 | 270.10 | +0.59% | OK |
| 10 | 576.80 | 570.00 | +1.19% | OK |
| 25 | 1464.40 | 1475.50 | -0.75% | OK |
| 50 | 2959.70 | 2959.20 | +0.02% | OK |
| 75 | 4446.10 | 4460.10 | -0.31% | OK |
| 100 | 4665.00 | 5360.40 | -12.97% | OK |
| 150 | 4876.70 | 5647.60 | -13.65% | OK |
| 200 | 5626.50 | 5589.90 | +0.65% | OK |
| 300 | 5637.60 | 5488.60 | +2.71% | OK |
| 400 | 5879.50 | 5223.20 | +12.57% | OK |

Interpretation (`zookeeper original` throughput sweep rerun):

- Final sweep completed `11/11` points with `status=OK` on all points and `retry_count=0` for all points.
- Throughput closely matches canonical through low/mid concurrency (`c<=75`, within about `-0.8%` to `+2.0%`).
- At `c=100` and `c=150`, rerun underperforms canonical by about `13%` to `14%`.
- At higher concurrency (`c>=200`), rerun throughput recovers and exceeds canonical at `c=300` and `c=400`.
- Rerun peak is `5879.50 @ c=400`, above canonical peak `5647.60 @ c=150` (about `+4.1%`, and at a different concurrency).
- Overall this case is partially supporting: all points reproduce operationally, but mid/high-concurrency curve shape differs from canonical.

Eighth throughput-sweep rerun set (`zookeeper fastpath100`, `rule_zookeeper.yml`, `-m 100`):

```bash
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_fastpath100_timeout.sh jetpack-zookeeper rule_zookeeper.yml "-m 100" > /tmp/codex_phase2_sweep_zookeeper_fastpath100_final_20260308T012804Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_fastpath100_final_20260308T012804Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 39.60 | 41.30 | -4.12% | OK |
| 5 | 270.60 | 271.30 | -0.26% | OK |
| 10 | 574.70 | 573.70 | +0.17% | OK |
| 25 | 1465.20 | 1467.70 | -0.17% | OK |
| 50 | 2973.00 | 2959.20 | +0.47% | OK |
| 75 | 4458.30 | 4458.60 | -0.01% | OK |
| 100 | 4737.00 | 4743.00 | -0.13% | OK |
| 150 | 5653.20 | 4729.90 | +19.52% | OK |
| 200 | 5486.80 | 5436.40 | +0.93% | OK |
| 300 | 5805.70 | 5456.40 | +6.40% | OK |
| 400 | 5853.40 | 4930.80 | +18.71% | OK |

Interpretation (`zookeeper fastpath100` throughput sweep rerun):

- Final sweep completed `11/11` points with `status=OK` on all points and `retry_count=0` for all points.
- Throughput closely matches canonical through `c=5..100` (within about `-0.3%` to `+0.5%`), with a larger low-concurrency deviation at `c=1` (`-4.1%`).
- At higher concurrency (`c>=150`), rerun throughput is above canonical by about `+0.9%` to `+19.5%`.
- Rerun peak is `5853.40 @ c=400`, above canonical peak `5456.40 @ c=300` (about `+7.3%`, and at a different concurrency).
- Fast-path success is near 100% through `c<=75`, then drops to `0` from `c>=100`, indicating substantial mode-path behavior shift under load.
- Overall this case is partially supporting: operational completion and low/mid-concurrency levels reproduce well, but high-concurrency curve shape and mode-path mix differ from canonical.

Ninth throughput-sweep rerun set (`zookeeper adaptive`, `rule_zookeeper.yml`):

```bash
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_adaptive_timeout.sh jetpack-zookeeper rule_zookeeper.yml > /tmp/codex_phase2_sweep_zookeeper_adaptive_final_20260308T014626Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_adaptive_final_20260308T014626Z.stderr.log
```

| Concurrency | Rerun throughput | Canonical throughput | Delta vs canonical | Rerun status |
|---:|---:|---:|---:|---|
| 1 | 40.00 | 39.30 | +1.78% | OK |
| 5 | 271.90 | 272.70 | -0.29% | OK |
| 10 | 572.70 | 567.20 | +0.97% | OK |
| 25 | 1465.80 | 1462.80 | +0.21% | OK |
| 50 | 2963.70 | 2958.30 | +0.18% | OK |
| 75 | 4455.70 | 4459.10 | -0.08% | OK |
| 100 | 5278.00 | 5054.20 | +4.43% | OK |
| 150 | 5661.50 | 5486.00 | +3.20% | OK |
| 200 | 4729.50 | 4620.80 | +2.35% | OK |
| 300 | 5907.40 | 5380.30 | +9.80% | OK |
| 400 | 5932.80 | 5422.80 | +9.40% | OK |

Interpretation (`zookeeper adaptive` throughput sweep rerun):

- Final sweep completed `11/11` points with `status=OK` on all points and `retry_count=0` for all points.
- Throughput closely matches canonical through low/mid concurrency (`c<=75`, within about `-0.3%` to `+1.8%`).
- At `c=100..200`, rerun throughput is modestly above canonical (about `+2.4%` to `+4.4%`).
- At high concurrency (`c=300..400`), rerun throughput is materially above canonical (about `+9.4%` to `+9.8%`).
- Rerun peak is `5932.80 @ c=400`, above canonical peak `5486.00 @ c=150` (about `+8.2%`, and at a different concurrency).
- Fast-path success is `100%` through `c<=50`, then drops to `0` from `c>=75`, indicating a substantial adaptive path-mix shift under load.
- Overall this case is partially supporting: all points reproduce operationally and low/mid-concurrency values align, but high-concurrency curve shape and peak location differ from canonical.

## 7. Failure Recovery Rerun Attempts

First failure-recovery rerun set (`etcd`, WAN latency mode):

Runbook command attempt (failed under current Docker Compose v5 CLI):

```bash
timeout 1800s docker compose -f docker/etcd/docker-compose.yml run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery > /tmp/codex_phase3_etcd_recovery_wan20_20260308T020457Z.log 2>&1
```

Compose-v5-compatible recovery rerun (service already `privileged: true` in compose file):

```bash
timeout 1800s docker compose -f docker/etcd/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery > /tmp/codex_phase3_etcd_recovery_wan20_composev5_20260308T020524Z.log 2>&1
```

| Attempt UTC | Status | Stdout/stderr capture | etcd leader re-election (ms) | Jetpack detection after signal (ms) | Jetpack internal duration (ms) | Assessment vs docs |
|---|---|---|---:|---:|---:|---|
| 2026-03-08T02:04:57Z | Failed pre-run | `/tmp/codex_phase3_etcd_recovery_wan20_20260308T020457Z.log` | N/A | N/A | N/A | Non-supporting runbook invocation in this environment (`unknown flag: --privileged`) |
| 2026-03-08T02:05:24Z | Completed | `/tmp/codex_phase3_etcd_recovery_wan20_composev5_20260308T020524Z.log` | 6496 | 108 | 123 | Partially supporting: signal chain and etcd election range reproduce, but Jetpack internal duration is above strict 81-83ms claim |

Interpretation (`etcd` failure-recovery rerun):

- Recovery test completed successfully after adapting command syntax to Compose v5 (`run --rm` without CLI `--privileged`).
- Required evidence points were observed in logs: leader kill, new leader election, Jetpack recovery start, and Jetpack recovery completion.
- Signal files were all reported as written and detected (`JM_Jetpack_failure_triggered`, `JM_Jetpack_0.0.0.0`, `JM_Jetpack_recovery_finish_after_failure`).
- etcd re-election timing (`6496ms`) is within the broad expected range documented for etcd failover.
- Jetpack recovery timing in this run is mixed against docs expectations:
  - Script-level detection after signal: `108ms`.
  - Internal Jetpack recovery duration line: `123ms`.
  - Both are above the strict RTT=40ms claim (`~81-83ms`) used in current docs.
- This case is therefore partially supporting overall: recovery mechanism and event ordering reproduce, but the strict Jetpack duration claim was not reproduced in this first rerun.

Second failure-recovery rerun set (`mongodb`, WAN latency mode):

Runbook command attempt (failed under current Docker Compose v5 CLI):

```bash
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_20260308T021804Z.log 2>&1
```

Compose-v5-compatible recovery reruns (service already `privileged: true` in compose file):

```bash
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_composev5_20260308T021815Z.log 2>&1
docker compose -f docker/mongodb/docker-compose.yml down -v
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_composev5_retry1_20260308T021903Z.log 2>&1
```

| Attempt UTC | Status | Stdout/stderr capture | MongoDB primary re-election (ms) | Jetpack detection after signal (ms) | Jetpack internal duration (ms) | Assessment vs docs |
|---|---|---|---:|---:|---:|---|
| 2026-03-08T02:18:04Z | Failed pre-run | `/tmp/codex_phase3_mongodb_recovery_wan20_20260308T021804Z.log` | N/A | N/A | N/A | Non-supporting runbook invocation in this environment (`unknown flag: --privileged`) |
| 2026-03-08T02:18:15Z | Failed before recovery | `/tmp/codex_phase3_mongodb_recovery_wan20_composev5_20260308T021815Z.log` | N/A | N/A | N/A | Non-supporting: dependency `mongodb` container exits (100) before recovery phases |
| 2026-03-08T02:19:03Z | Failed before recovery (after cleanup) | `/tmp/codex_phase3_mongodb_recovery_wan20_composev5_retry1_20260308T021903Z.log` | N/A | N/A | N/A | Non-supporting: same dependency startup failure persists after `down -v` |

Interpretation (`mongodb` failure-recovery rerun):

- The documented runbook form with CLI `--privileged` does not run under this Compose v5 CLI (`unknown flag: --privileged`).
- The Compose-v5-compatible rerun command starts dependency orchestration but fails before any recovery timeline events; `mongodb` exits with code `100` and compose aborts with `dependency failed to start`.
- Retrying after full stack/volume cleanup (`down -v`) reproduces the same pre-recovery dependency failure.
- Container logs for `mongodb-mongodb-1` show an immediate mongod startup termination:
  - `std::exception in initAndListen, terminating`
  - `error":"open: Permission denied"`
- Because no recovery phases (`leader kill`, `new primary`, Jetpack recovery start/finish, signal-file chain) become observable, this backend rerun is non-supporting in the current environment.

## 8. Discrepancies and Risks

- `result.md` throughput tables conflict with canonical sweep artifacts in `docs/sweep_2026-02-28/`.
  - Risk: readers may treat those stale numbers as current validated results.
- Mode labels are semantically consistent but textually inconsistent (`fastpath100` vs `fastpath-100` vs `FP 100%`).
  - Risk: traceability friction when matching files/scripts/tables.
- Historical rerun vs canonical differences reach about +/-10% to +/-12% on some points.
  - Risk: single-point comparisons may overstate precision without variance bounds.
- Recovery metric naming is ambiguous in docs/logs (`Jetpack downtime` vs internal `duration=`), and these can differ substantially.
  - Risk: readers may compare the wrong metric against the 81ms formula.
- `docs/failure_recovery_evaluation.md` contains internally conflicting status statements (`RESOLVED` tables vs later `OPEN` subsections for related issues).
  - Risk: confidence level is overstated unless each claim is tied to a specific evidence set/date.
- Some pre-fix RTT=40ms internal-duration claims are not directly backed by committed log files in `docs/logs/`.
  - Risk: those pre-fix values remain plausible narrative context rather than directly artifact-backed in this repository snapshot.
- Fresh-image reproducibility remains blocked by backend image build issues in current environment/workspace state.
  - Risk: current rerun evidence depends on pre-existing local images, so full clean-room reproducibility is not yet demonstrated.
- The etcd OFF rerun shows one significant absolute-latency outlier (22.99/62.76ms) among otherwise matching runs (~43/83ms).
  - Risk: absolute latency conclusions may be sensitive to uncontrolled runtime conditions even when topology/mode settings are fixed.
- MongoDB OFF low-concurrency rerun is unstable: default command fails pre-benchmark under some primary-election outcomes; the only completed run contradicts published absolute latency levels.
  - Risk: published MongoDB OFF low-concurrency numbers are currently not reproducible with high confidence in this environment.
- MongoDB ON low-concurrency rerun is also unstable/non-supporting: completed runs contradict published ON low-concurrency values, and several attempts failed/timed out before summaries.
  - Risk: current docs likely overstate MongoDB ON reproducibility at the documented latency levels.
- The `etcd original` throughput sweep rerun reproduces low/mid-concurrency points but misses canonical high-concurrency throughput by about `17%` to `24%`.
  - Risk: peak-capacity claims are sensitive to runtime/environment conditions and should be presented with variance context.
- The `etcd fastpath100` throughput sweep rerun matches canonical at `c <= 100` but diverges at high concurrency and shifts peak from `c=400` (canonical) to `c=100` (rerun).
  - Risk: fast-path capacity curves appear environment-sensitive, so single-run peak comparisons can be misleading without variance bounds.
- The `etcd adaptive` throughput sweep rerun also matches canonical at `c <= 100` but underperforms canonical at `c >= 150` by about `14%` to `18%`.
  - Risk: adaptive high-concurrency capacity appears sensitive to runtime conditions, reducing confidence in single-run peak claims.
- The `mongodb original` throughput sweep rerun matches canonical through `c <= 50` but underperforms canonical at `c >= 75` by about `15%` to `34%`, with retries needed on several points.
  - Risk: MongoDB moderate/high-concurrency capacity appears environment-sensitive, so single-run peak and tail-throughput claims should be treated as provisional without variance bounds.
- The `mongodb fastpath100` throughput sweep rerun matches canonical only at low concurrency, then underperforms substantially at moderate/high concurrency, including a terminal `FAILED` point at `c=400` after retries.
  - Risk: MongoDB fast-path capacity/stability claims at higher concurrency are currently not reproducible in this environment and may be significantly overstated without variance/failure-rate context.
- The `mongodb adaptive` throughput sweep rerun matches canonical at `c <= 50` but diverges materially for `c=75..300` and shows an inverted tail relative to canonical at `c=400`.
  - Risk: MongoDB adaptive high-concurrency shape appears unstable/environment-sensitive, so single-run curve/peak claims are not yet robust without repeated runs and variance bounds.
- The `zookeeper original` throughput sweep rerun matches canonical at low/mid concurrency but diverges around `c=100..150` and shifts peak throughput to `c=400`.
  - Risk: ZooKeeper high-concurrency curve shape appears environment-sensitive, so single-run peak-location claims should be treated as provisional without variance bounds.
- The `zookeeper fastpath100` throughput sweep rerun is close to canonical through `c<=100` but exceeds canonical throughput at `c>=150`, with peak shifting to `c=400` and fast-path success collapsing to `0` from `c>=100`.
  - Risk: ZooKeeper fastpath100 high-concurrency behavior appears environment-sensitive and mode-path mixing may differ materially between runs, reducing confidence in single-run capacity/fast-path claims.
- The `zookeeper adaptive` throughput sweep rerun is close to canonical through `c<=75` but increasingly exceeds canonical at higher concurrency and shifts peak from `c=150` to `c=400`.
  - Risk: ZooKeeper adaptive high-concurrency capacity/shape appears environment-sensitive, so single-run peak and tail-shape claims should be treated as provisional without variance bounds.
- The runbook recovery command form (`docker compose run --privileged ...`) is not directly compatible with the current Docker Compose v5 CLI in this environment (`unknown flag: --privileged`).
  - Risk: reproduction may fail at command invocation level unless operators adapt command syntax to the local Compose implementation.
- The first etcd WAN recovery rerun reproduced failover ordering but yielded Jetpack recovery timings (`108ms` detect, `123ms` internal) above the strict RTT=40ms claim (`~81-83ms`).
  - Risk: single-run Jetpack recovery-duration claims may be optimistic without variance bounds and updated toolchain/runtime notes.
- The mongodb WAN recovery rerun is currently blocked before recovery begins because the dependency container exits at startup (`std::exception ... open: Permission denied`, exit `100`) even after `docker compose down -v`.
  - Risk: MongoDB recovery reproducibility cannot currently be evaluated in this environment, and recovery claims for this backend remain unverified here.
- Runtime regression testing still blocked in this environment by build prerequisites/toolchain compatibility.
  - Risk: this report can currently confirm artifact consistency, not runtime reproducibility.

## 9. Conclusion

- `Phase 1A`: Documented low-concurrency latency claims are internally consistent and follow the expected RTT-delta model, with a small MongoDB ON overhead above the simple 40ms ideal.
- `Phase 1B`: Canonical sweep claims in `docs/latency_analysis.md` and `docs/sweep_2026-02-28/` are internally consistent and artifact-backed (`99/99 OK`, peak values match TSVs after rounding).
- `Phase 1C`: The WAN 3x3 recovery logs support the 81-83ms internal recovery claim and the qualitative backend election ranking/ranges (etcd variable, MongoDB ~10-13s, ZooKeeper ~0.8s).
- `Phase 2` prerequisite check: core prerequisites pass, but backend image builds are currently blocked (etcd/mongodb context-transfer timeouts; zookeeper source URL 404), so reruns currently depend on pre-existing local images rather than fresh rebuilds.
- `Phase 2` low-concurrency rerun progress:
  - `etcd OFF` was rerun 3 times using existing local image; 2 runs roughly match published 43.6/83.7ms, 1 run is a low-latency outlier while still matching the +40ms delta rule.
  - `etcd ON` (rule mode) was rerun 3 times; all 3 runs roughly match published 40.4/40.7ms and show 100% fast-path success at concurrency 1.
  - `mongodb OFF` rerun is currently non-supporting overall: default command failed pre-benchmark in repeated attempts, and the only completed override run contradicted published absolute latency levels.
  - `mongodb ON` rerun is currently non-supporting overall: completed runs (`h1 ~8.9`, `h2-h5 ~42.2`) contradict published `45.2/45.9`, and additional attempts failed or timed out before summaries.
  - `zookeeper OFF` rerun is supporting overall: 3/3 completed runs preserved the +40ms OFF-mode delta and stayed in the same rough absolute range (slightly lower than published values).
  - `zookeeper ON` rerun is supporting overall: 3/3 completed runs roughly match published `40.3/40.5` and show 100% fast-path success at concurrency 1.
  - Throughput sweep progress:
    - `etcd original` completed with `11/11 OK`; low/mid-concurrency matches canonical closely, but high-concurrency throughput is lower and peak is `6322.9` vs canonical `7686.6` (about `-17.7%`).
    - `etcd fastpath100` completed with `11/11 OK`; low/mid-concurrency closely matches canonical, but high-concurrency points diverge and peak shifts to `5939.4@c=100` vs canonical `6749.3@c=400`.
    - `etcd adaptive` completed with `11/11 OK`; low/mid-concurrency closely matches canonical, while high-concurrency points are lower and peak is `6013.2@c=150` vs canonical `7323.3@c=200`.
    - `mongodb original` completed with `11/11 OK`; throughput matches canonical through `c <= 50`, then drops at higher concurrency (`-15%` to `-34%`), with peak `3162.6@c=75` vs canonical `3799.3@c=100` and retries at `c=50/100/200/400`.
    - `mongodb fastpath100` emitted `11/11` rows but only `10/11 OK`; low-concurrency points are close to canonical, while moderate/high-concurrency points underperform (roughly `-16%` to `-24%`) and `c=400` fails after retries (`FAILED`, `docker_exit_1;timeout`).
    - `mongodb adaptive` completed with `11/11 OK`; low/mid-concurrency points (`c<=50`) closely match canonical, but `c=75..300` underperform by about `16%` to `26%`, with peak `3242.9@c=75` vs canonical `3858.3@c=100` and an inverted tail at `c=400` (+30% vs canonical).
    - `zookeeper original` completed with `11/11 OK`; low/mid-concurrency points (`c<=75`) closely match canonical, but `c=100..150` underperform by about `13%` to `14%`, and peak shifts to `5879.5@c=400` vs canonical `5647.6@c=150`.
    - `zookeeper fastpath100` completed with `11/11 OK`; low/mid-concurrency points are close to canonical through `c<=100`, but `c>=150` exceeds canonical by about `+0.9%` to `+19.5%`, with peak `5853.4@c=400` vs canonical `5456.4@c=300` and fast-path success dropping to `0` from `c>=100`.
    - `zookeeper adaptive` completed with `11/11 OK`; low/mid-concurrency points (`c<=75`) closely match canonical, while `c>=100` is above canonical by about `+2.4%` to `+9.8%`, with peak `5932.8@c=400` vs canonical `5486.0@c=150` and fast-path success dropping to `0` from `c>=75`.
- `Phase 2` throughput sweep matrix status: 9 of 9 cases rerun; no cases are pending.
- `Phase 3` recovery rerun progress:
  - `etcd` WAN-style recovery rerun completed after Compose-v5 command adaptation; leader failover ordering and signal chain reproduced, with etcd re-election `6496ms`.
  - Jetpack recovery timing in this run (`108ms` detect, `123ms` internal) is above the strict RTT=40ms `~81-83ms` claim, so this backend is currently only partially supporting.
  - `mongodb` WAN-style recovery rerun is currently non-supporting: command-level adaptation is possible, but dependency startup fails before recovery phases (`mongodb` exits `100`, `open: Permission denied`) even after cleanup/retry.
- `Phase 3` recovery matrix status: 2 of 3 backends rerun; remaining 1 backend (`zookeeper`) is pending.
- Open discrepancies:
  - Throughput numbers in `result.md` are not consistent with canonical sweep artifacts.
  - Recovery sections mix metrics and contain internal status conflicts; pre-fix RTT=40ms gap claims are not fully traceable to committed logs.

## 10. Appendix: Commands and Evidence

Key commands used in this and previous iteration:

```bash
git pull
rg -n "h1|h2-h5|40ms|Jetpack OFF|Jetpack ON|etcd|MongoDB|ZooKeeper|low-concurrency|sanity" docs/latency_analysis.md result.md docs/benchmark_runbook.md
rg -n "Peak Throughput|Maximum Throughput|99/99|OK|adaptive|original|fastpath100|FP 100%|none_" docs/latency_analysis.md result.md docs/sweep_2026-02-28/README.md docs/sweep_2026-02-28/CANONICAL_INDEX.md docs/sweep_2026-02-28/FAILURE_LEDGER.md
rg -n "81ms|2\\*RTT|RTT=40|WAN|recovery|downtime|leader election|new leader|Run A|Run B|Run C|expected" docs/failure_recovery_evaluation.md result.md docs/benchmark_runbook.md
docker --version
docker compose version
git submodule status --recursive
ulimit -n
timeout 90s docker compose -f docker/etcd/docker-compose.yml build
timeout 90s docker compose -f docker/mongodb/docker-compose.yml build
timeout 90s docker compose -f docker/zookeeper/docker-compose.yml build
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=none_etcd.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-etcd benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_etcd.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-etcd benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=none_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=none_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e MONGODB_ENDPOINTS='mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=jetpack-rs' -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 240s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 240s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e MONGODB_ENDPOINTS='mongodb://127.0.0.1:27017,127.0.0.2:27017,127.0.0.3:27017/?replicaSet=jetpack-rs' -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 360s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_mongodb.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-mongodb benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=none_zookeeper.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-zookeeper benchmark
timeout 900s docker run --rm --privileged -e SITE_CONFIG=60c1s5r5p.yml -e MODE_CONFIG=rule_zookeeper.yml -e CLIENT_CONFIG=client_open.yml -e CONCURRENT_CONFIG=concurrent_1.yml -e LATENCY_MS=20 -e LATENCY_JITTER=0 -e TEST_DURATION=30 jetpack-zookeeper benchmark
sed 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark.sh
chmod +x /tmp/codex_sweep_benchmark.sh
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd none_etcd.yml > /tmp/codex_phase2_sweep_etcd_original_20260307T213527Z.tsv 2> /tmp/codex_phase2_sweep_etcd_original_20260307T213527Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' /tmp/codex_phase2_sweep_etcd_original_20260307T213527Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/etcd_original.tsv | sort -n)
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd rule_etcd.yml "-m 100" > /tmp/codex_phase2_sweep_etcd_fastpath100_20260307T215653Z.tsv 2> /tmp/codex_phase2_sweep_etcd_fastpath100_20260307T215653Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' /tmp/codex_phase2_sweep_etcd_fastpath100_20260307T215653Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/etcd_fastpath100.tsv | sort -n)
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-etcd rule_etcd.yml > /tmp/codex_phase2_sweep_etcd_adaptive_20260307T221731Z.tsv 2> /tmp/codex_phase2_sweep_etcd_adaptive_20260307T221731Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' /tmp/codex_phase2_sweep_etcd_adaptive_20260307T221731Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/etcd_adaptive.tsv | sort -n)
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-mongodb none_mongodb.yml > /tmp/codex_phase2_sweep_mongodb_original_final_20260307T224600Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_original_final_20260307T224600Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' /tmp/codex_phase2_sweep_mongodb_original_final_20260307T224600Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/mongodb_original.tsv | sort -n)
timeout 7200s /tmp/codex_sweep_benchmark.sh jetpack-mongodb rule_mongodb.yml "-m 100" > /tmp/codex_phase2_sweep_mongodb_fastpath100_20260307T233231Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_fastpath100_20260307T233231Z.stderr.log
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_mongodb_fastpath100_timeout.sh jetpack-mongodb rule_mongodb.yml "-m 100" > /tmp/codex_phase2_sweep_mongodb_fastpath100_final_20260307T234259Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_fastpath100_final_20260307T234259Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13"\t"$16}' /tmp/codex_phase2_sweep_mongodb_fastpath100_final_20260307T234259Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/mongodb_fastpath100.tsv | sort -n)
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_mongodb_adaptive_timeout.sh jetpack-mongodb rule_mongodb.yml > /tmp/codex_phase2_sweep_mongodb_adaptive_final_20260308T002834Z.tsv 2> /tmp/codex_phase2_sweep_mongodb_adaptive_final_20260308T002834Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13"\t"$16"\t"$10}' /tmp/codex_phase2_sweep_mongodb_adaptive_final_20260308T002834Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{print $1"\t"$2"\t"$13}' docs/sweep_2026-02-28/mongodb_adaptive.tsv | sort -n)
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_original_timeout.sh jetpack-zookeeper none_zookeeper.yml > /tmp/codex_phase2_sweep_zookeeper_original_final_20260308T010749Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_original_final_20260308T010749Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\t%s\n",$1,$2,$13}' /tmp/codex_phase2_sweep_zookeeper_original_final_20260308T010749Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\n",$1,$2}' docs/sweep_2026-02-28/zookeeper_original.tsv | sort -n)
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_zookeeper_fastpath100_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_zookeeper_fastpath100_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_fastpath100_timeout.sh jetpack-zookeeper rule_zookeeper.yml "-m 100" > /tmp/codex_phase2_sweep_zookeeper_fastpath100_final_20260308T012804Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_fastpath100_final_20260308T012804Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\t%s\n",$1,$2,$13}' /tmp/codex_phase2_sweep_zookeeper_fastpath100_final_20260308T012804Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\n",$1,$2}' docs/sweep_2026-02-28/zookeeper_fastpath100.tsv | sort -n)
sed -e 's|LOG_DIR="docs/sweep_2026-02-28/logs/${IMAGE_SHORT}_${MODE_SHORT}"|LOG_DIR="/tmp/codex_sweep_logs/${IMAGE_SHORT}_${MODE_SHORT}"|' -e 's|output=$(docker run --rm --privileged \\|output=$(timeout 360s docker run --rm --privileged \\|' scripts/sweep_benchmark.sh > /tmp/codex_sweep_benchmark_zookeeper_adaptive_timeout.sh
chmod +x /tmp/codex_sweep_benchmark_zookeeper_adaptive_timeout.sh
timeout 7200s /tmp/codex_sweep_benchmark_zookeeper_adaptive_timeout.sh jetpack-zookeeper rule_zookeeper.yml > /tmp/codex_phase2_sweep_zookeeper_adaptive_final_20260308T014626Z.tsv 2> /tmp/codex_phase2_sweep_zookeeper_adaptive_final_20260308T014626Z.stderr.log
join -t $'\t' -1 1 -2 1 <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\t%s\n",$1,$2,$13}' /tmp/codex_phase2_sweep_zookeeper_adaptive_final_20260308T014626Z.tsv | sort -n) <(awk -F'\t' '!/^#/&&$1!="concurrency"{printf "%s\t%s\n",$1,$2}' docs/sweep_2026-02-28/zookeeper_adaptive.tsv | sort -n)
timeout 1800s docker compose -f docker/etcd/docker-compose.yml run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery > /tmp/codex_phase3_etcd_recovery_wan20_20260308T020457Z.log 2>&1
timeout 1800s docker compose -f docker/etcd/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-etcd recovery > /tmp/codex_phase3_etcd_recovery_wan20_composev5_20260308T020524Z.log 2>&1
rg -n "New etcd leader elected|etcd downtime|Jetpack recovery detected|Jetpack recovery completed|JM_Jetpack_|Failure Recovery Test PASSED|unknown flag" /tmp/codex_phase3_etcd_recovery_wan20_20260308T020457Z.log /tmp/codex_phase3_etcd_recovery_wan20_composev5_20260308T020524Z.log
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm --privileged -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_20260308T021804Z.log 2>&1
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_composev5_20260308T021815Z.log 2>&1
docker compose -f docker/mongodb/docker-compose.yml down -v
timeout 1800s docker compose -f docker/mongodb/docker-compose.yml run --rm -e RECOVERY_LATENCY_MS=20 jetpack-mongodb recovery > /tmp/codex_phase3_mongodb_recovery_wan20_composev5_retry1_20260308T021903Z.log 2>&1
rg -n "unknown flag|dependency failed to start|exited \\(100\\)|Failure Recovery Test PASSED|JM_Jetpack_" /tmp/codex_phase3_mongodb_recovery_wan20_20260308T021804Z.log /tmp/codex_phase3_mongodb_recovery_wan20_composev5_20260308T021815Z.log /tmp/codex_phase3_mongodb_recovery_wan20_composev5_retry1_20260308T021903Z.log
docker logs mongodb-mongodb-1 | rg -n "std::exception in initAndListen|Permission denied|exitCode"
docker kill <jetpack-mongodb-container-id>
```

Recovery-log extraction checks:

```bash
ls -la docs/logs
git ls-files docs/logs
rg -n "downtime|Jetpack recovery completed|duration=|new leader|new primary|signal|RTT|recovery" docs/logs/*_recovery_gap_fix_wan_r*.txt

printf 'file\tbackend_downtime_ms\tjetpack_downtime_ms\tinternal_duration_ms\n'
for f in docs/logs/*_recovery_gap_fix_wan_r*.txt; do
  bd=$(sed -nE 's/.*(etcd|MongoDB|ZooKeeper) downtime: ([0-9]+)ms.*/\2/p' "$f" | head -n1)
  jd=$(sed -nE 's/.*Jetpack downtime: ([0-9]+)ms.*/\1/p' "$f" | head -n1)
  id=$(sed -nE 's/.*Jetpack recovery completed \(duration=([0-9]+)ms\).*/\1/p' "$f" | head -n1)
  printf '%s\t%s\t%s\t%s\n' "$(basename "$f")" "$bd" "$jd" "$id"
done | sort
```

Canonical sweep status/peak checks:

```bash
for f in docs/sweep_2026-02-28/{etcd,mongodb,zookeeper}_{original,fastpath100,adaptive}.tsv; do
  awk -F'\t' -v f="$f" 'BEGIN{ok=0;total=0;max=-1;maxc=""}
    !/^#/ {if($1=="concurrency") next; total++; if($13=="OK") ok++; if(($2+0)>max){max=$2+0;maxc=$1}}
    END{printf "%s rows=%d ok=%d bad=%d peak=%.2f@c=%s\n",f,total,ok,total-ok,max,maxc}' "$f"
done
```

Consolidated status check:

```bash
awk -F',' 'NR==1{for(i=1;i<=NF;i++)h[$i]=i;next}
  {total++; if($(h["status"])=="OK") ok++; else bad++}
  END{printf "consolidated.csv status OK=%d/%d bad=%d\n",ok,total,bad}' docs/sweep_2026-02-28/consolidated.csv
```

Historical rerun-vs-canonical delta check (failed-point reruns):

```bash
awk -F'\t' '
!/^#/ && $1!="dataset" {
  ds=$1; c=$2; rr=$3+0;
  if (ds=="etcd_fastpath100") file="docs/sweep_2026-02-28/etcd_fastpath100.tsv";
  else if (ds=="etcd_adaptive") file="docs/sweep_2026-02-28/etcd_adaptive.tsv";
  else if (ds=="mongodb_original") file="docs/sweep_2026-02-28/mongodb_original.tsv";
  else if (ds=="mongodb_fastpath100") file="docs/sweep_2026-02-28/mongodb_fastpath100.tsv";
  else if (ds=="mongodb_adaptive") file="docs/sweep_2026-02-28/mongodb_adaptive.tsv";
  else if (ds=="zookeeper_fastpath100") file="docs/sweep_2026-02-28/zookeeper_fastpath100.tsv";
  cmd="awk -F\"\\t\" -v c=\"" c "\" '\''!/^#/ && $1==c {print $2}'\'' " file;
  cmd | getline canon; close(cmd);
  d=rr-canon; pct=(canon==0)?0:(d/canon*100);
  printf "%s c=%s rerun=%.2f canonical=%.2f delta=%.2f (%.1f%%)\n", ds,c,rr,canon+0,d,pct;
}' docs/sweep_2026-02-28/rerun_results.tsv
```

Build/test attempts:

```bash
./test_run.py
python3 waf configure build -d
python2 waf configure build -d -D
```
