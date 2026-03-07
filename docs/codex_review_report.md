# Codex Independent Evaluation Review Report

## 1. Scope

This report currently covers the first three high-priority leaf tasks from `TODO_codex.md`:

- `Phase 1A`: Low-concurrency latency sanity check.
- `Phase 1B`: Throughput sweep consistency check.
- `Phase 1C`: Failure-recovery sanity check.

Included in this pass:

- Internal consistency checks across `docs/latency_analysis.md`, `result.md`, and sweep artifacts.
- Numerical checks of latency deltas and sweep peak/status claims.
- Cross-check of canonical sweep files vs rerun/archive history for contradictions.
- Recovery-model checks against `docs/failure_recovery_evaluation.md`, `result.md`, and committed recovery logs.

Not yet executed in this report:

- `Phase 2` benchmark reruns.
- `Phase 3` recovery reruns.

## 2. Environment

- UTC timestamp (this iteration): 2026-03-07T20:09:07Z
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

No benchmark rerun executed yet. Pending `Phase 2`.

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
- Runtime regression testing still blocked in this environment by build prerequisites/toolchain compatibility.
  - Risk: this report can currently confirm artifact consistency, not runtime reproducibility.

## 9. Conclusion

- `Phase 1A`: Documented low-concurrency latency claims are internally consistent and follow the expected RTT-delta model, with a small MongoDB ON overhead above the simple 40ms ideal.
- `Phase 1B`: Canonical sweep claims in `docs/latency_analysis.md` and `docs/sweep_2026-02-28/` are internally consistent and artifact-backed (`99/99 OK`, peak values match TSVs after rounding).
- `Phase 1C`: The WAN 3x3 recovery logs support the 81-83ms internal recovery claim and the qualitative backend election ranking/ranges (etcd variable, MongoDB ~10-13s, ZooKeeper ~0.8s).
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
