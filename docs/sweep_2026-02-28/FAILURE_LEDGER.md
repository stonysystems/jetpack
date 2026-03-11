# Failure and Retry Ledger

Canonical dataset scope: `docs/sweep_2026-02-28/{etcd,mongodb,zookeeper}_{original,fastpath100,adaptive}.tsv`
refreshed from accepted pass `results/reproduce_20260310_164201/sweep/`.

## Canonical Summary

- Total canonical rows: **99**
- Status totals: **99 OK / 0 PARTIAL / 0 FAILED**
- Retry sum: **1**

No canonical row is currently FAILED or PARTIAL. One row required a retry and
succeeded.

## Canonical Retry Events

| # | Backend | Mode | Concurrency | Final Status | Retry Count | Final Selected Log | Prior Failed Attempt Log | Notes |
|---|---------|------|-------------|--------------|-------------|--------------------|--------------------------|-------|
| 1 | MongoDB | adaptive | 1 | OK | 1 | [conc1_attempt1.log](logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc1_attempt1.log) | [conc1_attempt0.log](logs/jetpack-mongodb-phase1e-leaf3-adaptive_rule_mongodb/conc1_attempt0.log) | attempt0 ended with docker exit 137 (stuck run); retry attempt1 succeeded and is the canonical row |

## Historical Context

Earlier non-canonical rerun work (2026-03-02) is still preserved in:

- `docs/sweep_2026-02-28/rerun_results.tsv`
- `docs/sweep_2026-02-28/logs/*_rerun/`

Those artifacts are historical/debug context and are not the active canonical
9-case dataset.
