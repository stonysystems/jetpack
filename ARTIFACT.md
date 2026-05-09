# Jetpack — Artifact

Top-level entry point for users running the artifact-evaluation
pipeline. For day-to-day development docs, see [`README.md`](README.md).

## What this artifact provides

- [x] **Available** — repository tag archived on Zenodo (DOI: TBD).
- [x] **Functional** — Docker-based smoke test reproduces build,
      a single-protocol mini-sweep, one recovery test, and one
      TLA spec in under 30 minutes on a commodity Linux host.
      See [`ae/README.md`](ae/README.md) §1.
- [x] **Reproduced** — Docker-only reproduction of all four
      headline claim sets (Exp 0, Exp 1, Exp 2, failure recovery
      + TLA proofs) overnight. Reproduces the *direction* of the
      paper's results; absolute throughput numbers require AWS
      WAN and are reproducible via the optional path in
      [`ae/README.md`](ae/README.md) §3.

## Where to start

Open [`ae/README.md`](ae/README.md). It has three tiers
(Functional → Reproduced-Docker → optional Reproduced-AWS) and a
claim-to-script map in [`ae/claims.md`](ae/claims.md).

## Repository overview

- [`src/`](src/) — single-binary deptran_server (all 9 protocols).
- [`tla/`](tla/) — TLA+ specifications (Raft / CoPilot / Mencius
  standalone + Jetpack compositions); both small (budget) and
  large (paper-claim) TLC configs are provided.
- [`docker/`](docker/) — reproducible build + protocol-specific test
  images; Compose V2 setups for etcd / mongodb / zookeeper.
- [`scripts/`](scripts/) — experiment drivers. The Docker reproducer
  is [`scripts/reproduce_evaluation.sh`](scripts/reproduce_evaluation.sh)
  plus extensions referenced from `ae/`.
- [`scripts/camera-ready/`](scripts/camera-ready/) — full AWS
  reproduction (28 h, 860 runs); used to produce the paper's figures.
  Not required to satisfy the badges above; documented under §3 of
  `ae/README.md` for users who want gold-standard numbers.
- [`results/`](results/) — historical experiment outputs; kept for
  provenance, not consumed by `ae/` scripts.
- [`ae/`](ae/) — the user-facing artifact archive (this submission).
