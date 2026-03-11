# Phase 1F Claim Reconciliation Matrix (2026-03-11)

Scope: first-pass reconciliation map for the open item
`Make the published docs/results match what Codex can actually rerun`.

## Claim Status Legend

- `artifact-backed`: directly backed by committed canonical artifacts/logs.
- `rerun-confirmed`: validated by rerun evidence, but interpreted/derived from artifacts.
- `historical context`: legacy/pre-fix results kept for explanation only; not current accepted evidence.
- `still open`: currently inconsistent/ambiguous and requires follow-up edits.

## Canonical Artifact Set

- Throughput sweep (accepted): `docs/sweep_2026-02-28/*.tsv`
- Low-concurrency reruns: `docs/phase1d_low_concurrency_runs.md`
- WAN recovery accepted pass: `docs/phase1f_wan_recovery_20260311/*_wan_r*.txt`
- WAN recovery consolidated table: `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md`

## Reconciliation Matrix

| ID | Claim / Number Family | Primary doc locations | Canonical source | Status | Follow-up |
|---|---|---|---|---|---|
| B1 | Throughput peaks by backend/mode (9-case sweep) | `docs/latency_analysis.md`, `result.md` | `docs/sweep_2026-02-28/*.tsv` | artifact-backed | keep as accepted baseline |
| B2 | c=200 cross-backend throughput comparison | `result.md` | `docs/sweep_2026-02-28/*.tsv` | artifact-backed | keep |
| B3 | Tail variability (`c=300/400`) is environment-sensitive | `docs/latency_analysis.md`, `result.md` | current vs prior sweep comparison in `docs/latency_analysis.md` | rerun-confirmed | keep as caveat |
| B4 | MongoDB low-concurrency absolute mismatch vs old published baseline | `result.md`, `docs/phase1d_low_concurrency_runs.md` | `docs/phase1d_low_concurrency_runs.md` table | rerun-confirmed | keep clearly labeled as mismatch/open-to-update |
| R1 | Jetpack internal WAN recovery duration is 81-83ms (RTT=40ms) | `docs/failure_recovery_evaluation.md`, `result.md` | `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md` | artifact-backed | use only this metric for RTT model |
| R2 | Script-detected Jetpack downtime differs from internal duration | `docs/failure_recovery_evaluation.md`, `result.md` | `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md` | artifact-backed | keep explicit metric split |
| R3 | Backend re-election ranges for accepted WAN pass | `docs/failure_recovery_evaluation.md`, `result.md` | `docs/phase1f_wan_recovery_20260311/wan_matrix_summary.md` | artifact-backed | update all summary ranges to accepted pass |
| R4 | Pre-fix gap analysis (e.g., MongoDB SDAM overhead in single-process runs) | `docs/failure_recovery_evaluation.md`, `result.md` | historical logs under `docs/logs/*_recovery_gap_fix*` | historical context | retain with explicit historical framing |
| R5 | RTT formula comparison target (`1ms + 2*RTT`) | `docs/failure_recovery_evaluation.md`, `result.md`, `docs/benchmark_runbook.md` | formula + accepted WAN internal durations | rerun-confirmed | ensure runbook wording uses RTT=40ms for RECOVERY_LATENCY_MS=20 |
| R6 | Recovery metric naming consistency (“Jetpack downtime” overloaded) | `docs/failure_recovery_evaluation.md`, `result.md`, `docs/benchmark_runbook.md` | accepted WAN logs + formulas | still open | finish runbook+cross-doc label alignment |
| D1 | Claim-status categories visible to readers | `result.md`, `docs/failure_recovery_evaluation.md`, `docs/latency_analysis.md` | this matrix + accepted artifacts | still open | add concise status labels in remaining docs (next leaves) |

## Immediate Findings from Leaf 1

- `result.md` and `docs/failure_recovery_evaluation.md` now largely align with the accepted WAN matrix and metric split.
- `docs/benchmark_runbook.md` still has RTT wording that implies `RTT=20ms` for `RECOVERY_LATENCY_MS=20`; this should be corrected to `RTT=40ms` (20ms one-way).
- Remaining reconciliation work should focus on runbook wording and explicit claim-status labeling consistency across docs.
