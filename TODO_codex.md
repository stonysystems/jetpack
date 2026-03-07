# TODO for Codex: Independent Evaluation Review and Rerun

This file is for a **Codex agent**, not Claude. The goal is to independently review the
existing Jetpack evaluation claims for MongoDB, ZooKeeper, and etcd, try to reproduce the
benchmark and failure-recovery results, and write a review report in
`docs/codex_review_report.md`.

## Hard Scope Limits

- Your **only allowed file edit** is `docs/codex_review_report.md`.
- Do **not** edit:
  - `TODO.md`
  - `result.md`
  - `docs/failure_recovery_evaluation.md`
  - `docs/latency_analysis.md`
  - `docs/benchmark_runbook.md`
  - any config, source, script, Docker, or benchmark artifact file
- Do **not** silently “fix” code, configs, or docs to make the rerun pass.
- Do **not** rewrite prior claims in place. If you find a mismatch, record it in
  `docs/codex_review_report.md`.
- You may make commits if useful, but any commit you create must contain changes only to
  `docs/codex_review_report.md`.

## Primary Goal

Produce an independent review that answers:

1. Do the currently documented evaluation results appear internally consistent?
2. Do the claimed benchmark results pass the stated sanity checks?
3. Can the results be reproduced by following `docs/benchmark_runbook.md`?
4. If not fully reproducible, what failed, what evidence was collected, and what is the most
   likely cause?

The final output of your work is a factual report in `docs/codex_review_report.md`, not code
changes elsewhere.

## Documents and Artifacts to Review First

Read these before running anything:

- `docs/benchmark_runbook.md`
- `docs/latency_analysis.md`
- `docs/failure_recovery_evaluation.md`
- `result.md`
- `docs/sweep_2026-02-28/README.md`
- `docs/sweep_2026-02-28/CANONICAL_INDEX.md`
- `docs/sweep_2026-02-28/FAILURE_LEDGER.md`
- Raw TSV files in `docs/sweep_2026-02-28/`
- Representative per-run logs under `docs/sweep_2026-02-28/logs/`

Also inspect `TODO.md`, but only as background on claimed completion status. Do **not** edit it.

## Read the Code First

Before trusting the docs or rerunning benchmarks, read the relevant Jetpack code paths and build
at least a basic understanding of how the benchmark and recovery measurements are supposed to
work.

Minimum code-reading targets:

- Jetpack request / fast-path / coordinator flow in `src/deptran/`
- Jetpack recovery entry / recovery timing / signal handling code
- backend integration points for etcd, MongoDB, and ZooKeeper
- scripts or Docker entrypoints that actually launch benchmark and recovery runs

You do **not** need a full architecture writeup, but your review report should show that you
understand the implementation well enough to judge whether the published measurements are
plausible.

## Review Standards

- Be skeptical of summaries. Prefer raw TSV/log evidence over prose claims.
- Distinguish clearly between:
  - documented claim,
  - artifact-backed claim,
  - rerun-confirmed claim,
  - and unresolved claim.
- If you cannot reproduce a result because of environment limitations, missing prerequisites,
  excessive runtime, or failures, say that plainly and record the exact blocker.
- Do **not** overstate reproduction. “I reran one benchmark successfully” is not the same as
  “the full evaluation is reproduced”.

## Deliverable Format for `docs/codex_review_report.md`

The report should contain these sections:

1. `Scope`
2. `Environment`
3. `Docs Reviewed`
4. `Existing Claims Checked`
5. `Sanity Check Review`
6. `Benchmark Rerun Attempts`
7. `Failure Recovery Rerun Attempts`
8. `Discrepancies and Risks`
9. `Conclusion`
10. `Appendix: Commands and Evidence`

For every rerun attempt, record:

- exact command
- date/time in UTC
- whether it completed, failed, or was interrupted
- where stdout/stderr was captured
- key metrics observed
- whether the result matches, roughly matches, or contradicts the existing docs

## Phase 1: Audit the Existing Docs Against Their Own Evidence

Before rerunning anything, check whether the written conclusions are supported by the checked-in
artifacts.

### A. Low-Concurrency Latency Sanity Check

Claims appear in:

- `docs/latency_analysis.md`
- `result.md`

The current documented expectations are roughly:

- Jetpack OFF, h1:
  - should be near backend write latency
- Jetpack OFF, h2-h5:
  - should be near h1 latency + one client-to-leader RTT
  - with 20ms one-way tc/netem, RTT is about 40ms
- Jetpack ON fast path:
  - should be about one RTT, around 40ms, for all clients

Check whether the reported values are numerically consistent with those rules:

- etcd OFF: h1 around 43.6ms, h2-h5 around 83.7ms
- MongoDB OFF: h1 around 47.7ms, h2-h5 around 88.0ms
- ZooKeeper OFF: h1 around 45.5ms, h2-h5 around 86.0ms
- etcd ON: around 40.4-40.7ms
- MongoDB ON: around 45.2-45.9ms
- ZooKeeper ON: around 40.3-40.5ms

Do not just repeat the table. State whether the deltas are consistent with the stated model.

### B. Throughput Sweep Consistency Check

Claims appear in:

- `docs/latency_analysis.md`
- `result.md`
- `docs/sweep_2026-02-28/*.tsv`

Check:

- whether the peak values quoted in the prose match the TSV files
- whether the claimed “99/99 OK” style statements match the actual status columns
- whether any rerun TSV / archive TSV / failure ledger entries contradict the polished summary
- whether adaptive/original/fastpath100 mode naming is used consistently

### C. Failure-Recovery Sanity Check

Claims appear in:

- `docs/failure_recovery_evaluation.md`
- `result.md`

Check whether the reported Jetpack recovery duration matches the documented formula:

- expected Jetpack downtime at RTT=40ms:
  - about `1ms poll + 2 * RTT = 81ms`

Check whether the published 3x3 backend repetitions are consistent with that expectation.
Also check whether the backend re-election times match the qualitative claims:

- etcd: variable and sometimes multi-second
- MongoDB: about 10-13 seconds
- ZooKeeper: around sub-second to about 1 second

### D. Report Phase 1 Outcome

In `docs/codex_review_report.md`, separate:

- claims that are consistent with raw artifacts
- claims that are plausible but not fully evidenced
- claims that appear inconsistent or over-claimed

## Phase 2: Rerun the Benchmark Results

Use `docs/benchmark_runbook.md` as the primary operational guide.

### Prerequisites to Confirm

Before launching reruns, confirm and record:

- Docker is available
- `docker compose` is available
- submodules are initialized if required
- you can build the 3 backend images
- `ulimit -n 65536` if needed

If any prerequisite is missing, record it and stop only if blocked.

### Build Step

Try to build:

- etcd image
- MongoDB image
- ZooKeeper image

Record success/failure and any build errors in the report.

### Benchmark Rerun Matrix

Try to rerun at least the documented low-concurrency sanity-check cases first:

- etcd OFF
- etcd ON / rule mode
- MongoDB OFF
- MongoDB ON / rule mode
- ZooKeeper OFF
- ZooKeeper ON / rule mode

Use the runbook defaults unless the docs clearly require a specific override. Record exactly
which command you used.

Minimum goal for each low-concurrency rerun:

- obtain observable throughput/latency output
- compare the measured h1 / h2-h5 behavior against the documented sanity model

If those pass, then try to rerun the broader throughput evaluation.

### Throughput Sweep Rerun Goal

Try to rerun the 9-case sweep matrix described across the docs:

- 3 backends:
  - etcd
  - MongoDB
  - ZooKeeper
- 3 modes:
  - original / none
  - fast path 100%
  - adaptive

If a full sweep is too expensive for one session, do not fake completion. Instead:

- run as much of the matrix as feasible
- state exactly which cases were rerun
- state which cases were not rerun
- state whether the partial rerun increases or decreases confidence in the published tables

### Benchmark Acceptance Rules

Treat a rerun as supporting the docs only if:

- the command actually completed
- output contained the expected benchmark summary lines
- the observed latencies/throughputs are in the same rough range as the published values
- there is no obvious contradiction with the stated latency model

Treat a rerun as non-supporting if:

- the command fails
- output is missing the expected metrics
- throughput is zero or clearly broken
- latency is wildly inconsistent with the documented network model

## Phase 3: Rerun Failure-Recovery Results

Try to reproduce the recovery experiments for:

- etcd
- MongoDB
- ZooKeeper

Use the recovery instructions in `docs/benchmark_runbook.md`.

### Recovery Checks

For each backend, check whether you can observe evidence for:

- leader kill
- new leader election
- Jetpack recovery start
- Jetpack recovery completion

If the WAN-style recovery path is practical, also try the latency-configured recovery case and
compare Jetpack recovery duration against the 81ms expectation at RTT=40ms.

### Recovery Acceptance Rules

Treat a recovery rerun as supporting the docs only if:

- you can identify the relevant recovery phases from logs/output
- the backend re-election time is in the expected broad range
- Jetpack recovery duration is near the documented bound for the chosen RTT

If the script runs but timing extraction is ambiguous, record it as ambiguous, not as a pass.

## Required Evidence Handling

- Save command transcripts or redirect output somewhere readable during your session.
- In the report, quote only short snippets when necessary.
- Prefer tables for:
  - commands attempted
  - benchmark cases rerun
  - recovery cases rerun
  - pass/fail/blocked status

You may create temporary local files for your own command output during the session if needed,
but do **not** treat them as deliverables and do **not** commit them.

## Important Non-Goals

- Do **not** modify code to make the evaluation pass.
- Do **not** regenerate or overwrite the official docs.
- Do **not** “clean up” old benchmark artifacts.
- Do **not** update `TODO.md` or mark any project task complete.
- Do **not** try to solve unrelated TLA+ issues.

## Minimum Useful Outcome

Even if full reruns are too heavy, the task is still useful if you produce a careful report that:

- validates or questions the existing sanity-check math,
- spot-checks the raw sweep artifacts against the published prose,
- reruns at least some benchmark and/or recovery cases,
- and clearly states what remains unverified.

## Final Instruction

When you finish, the only modified tracked file should be:

- `docs/codex_review_report.md`

If any other tracked file changed during your work, revert your own accidental changes before
stopping, unless the user explicitly asked for them.
