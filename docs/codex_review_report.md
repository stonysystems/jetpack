# Codex Independent Evaluation Review Report

## 1. Scope

This report currently covers the first fourteen high-priority leaf tasks from `TODO_codex.md`:

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

Included in this pass:

- Internal consistency checks across `docs/latency_analysis.md`, `result.md`, and sweep artifacts.
- Numerical checks of latency deltas and sweep peak/status claims.
- Cross-check of canonical sweep files vs rerun/archive history for contradictions.
- Recovery-model checks against `docs/failure_recovery_evaluation.md`, `result.md`, and committed recovery logs.
- Phase-2 prerequisite verification (Docker, compose, submodules, ulimit, backend image build attempts).
- Low-concurrency rerun execution (`etcd OFF`, `etcd ON`, `mongodb OFF`, `mongodb ON`, `zookeeper OFF`, `zookeeper ON`) with captured command transcripts and per-run metrics.
- Throughput-sweep rerun execution (`etcd original`, `etcd fastpath100`, `etcd adaptive`, `mongodb original`) with per-concurrency comparison to canonical sweep artifacts.

Not yet executed in this report:

- Remaining `Phase 2` throughput sweep reruns (5 of 9 matrix cases still pending).
- `Phase 3` recovery reruns.

## 2. Environment

- UTC timestamp (this iteration): 2026-03-07T23:27:40Z
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

## 7. Failure Recovery Rerun Attempts

No failure-recovery rerun executed yet. Pending `Phase 3`.

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
- `Phase 2` throughput sweep matrix status: 4 of 9 cases rerun; remaining 5 cases are still pending.
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
