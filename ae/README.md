# Jetpack AE — User Guide

`ae/` is a self-contained, frozen artifact archive. Every script,
config, and Docker asset a user needs is duplicated under this
directory; nothing in `ae/` reaches out to the rest of the
repository at run time. This is by design — at submission time the
rest of the repo can drift without affecting reproduction.

Jetpack is a plugin consensus protocol that sits on top of a base
protocol (Raft / CoPilot / Mencius / MongoDB / etcd / ZooKeeper) and
provides failure recovery via a 3-phase Paxos protocol independent
of the base layer. The paper's four headline claim sets are:

1. **Exp 0** — throughput-vs-concurrency for 9 protocols on AWS WAN.
2. **Exp 1** — Zipf-skew sensitivity at fixed concurrency.
3. **Exp 2** — key-range (contention) sensitivity at fixed concurrency.
4. **Recovery + TLA+** — recovery time = `1ms + 2·RTT` (empirical) and
   safety / agreement properties machine-checked by TLC.

This artifact reproduces all four. The **default path is
single-machine Docker** — works on any commodity Linux host with
Docker installed. Two opt-in alternatives are also provided:

- ★ **Local Docker** *(default, recommended)* — single host with
  tc/netem WAN simulation. Runs in 30 min with `--quick` for the
  Functional badge, ~15–22 h for the full overnight matrix on a
  16-core / 32 GB host. Reproduces *direction* of the paper's
  results.
- **Local cluster** *(opt-in)* — 5 SSH-accessible hosts on a LAN.
  Use only if you have such a cluster handy. Faster wall-clock and
  meaningful CPU-utilization figures. See
  [`ae/local/ips/README.md`](local/ips/README.md).
- **AWS** *(opt-in, gold standard)* — 10 × c5.2xlarge in 5 AWS
  regions. Exact paper figures including absolute throughput and
  CPU numbers. ~28 h, ~$50. See
  [`ae/aws/ips/README.md`](aws/ips/README.md).

## 0. Prerequisites

| | local | AWS |
|---|---|---|
| Hosts | 1 Linux host | 10 × c5.2xlarge in AWS |
| OS | Linux ≥ 5.4 (Ubuntu 22.04 ideal) | Ubuntu 22.04 |
| CPU | 16 cores | 8 vCPU per host |
| RAM | 32 GB | 16 GB per host |
| Disk | 150 GB free | 100 GB per host |
| Docker Engine | ≥ 17.05 | not required (build done in Docker on one host, deployed via NFS) |
| Docker Compose | V2 (`docker compose`) | n/a |
| Privileged Docker | required (tc/netem + cgroups for TLC) | n/a |

The artifact ships with the **full source tree** at
[`ae/local/`](local/) (~157 MB including `src/`, `third_party/`,
build files). On first run the Docker build takes ~30–45 min while
it compiles mongo-c, mongo-cxx, etcd-cpp-apiv3, and the Jetpack
binary itself. Re-runs are fast thanks to Docker layer caching.

No pre-built binary is shipped — users build their own via
`./ae/reproduce_local.sh --phase build`.

Verify (local):

```bash
docker --version
docker compose version
```

See [`ae/HARDWARE.md`](HARDWARE.md) for full hardware notes,
disk-usage breakdown, and the AWS topology.

## 1. Functional badge — kick the tires (~30 min)

```bash
./ae/reproduce_local.sh --quick
```

What it does:
- Builds the Docker image.
- Runs a raft mini-sweep (3 conc points × 4 variants).
- Runs one failure-recovery test (etcd, 1 rep, 20 ms RTT).
- Model-checks `jetpack_raft_composition.tla` on its small config.

After the run, summarize the output with:

```bash
./ae/check_results.sh ae/output/reproduce_<timestamp>
```

Things to look at by hand: every TLC log should end with
`Model checking completed. No error has been found.`; recovery
should report a Jetpack internal duration close to `1ms + 2·RTT`
(i.e. ~81 ms at 20 ms one-way); throughput should be non-zero on
every produced `.res`.

## 2. Reproduced badge — local reproduction (~15–22 h)

The default and recommended path:

```bash
./ae/reproduce_local.sh
```

This is single-machine Docker — no cluster, no IP config, no SSH
trust. The full AWS-density matrix runs as multiple processes on
one host with software WAN delay (`tc/netem`):

| Phase | Coverage | Wall-clock |
|---|---|---|
| Build | Single binary + per-backend test images | ~15 min |
| Exp 0 | 9 protocols × full AWS conc array (11–24 points each) × 1–4 variants = ~509 runs | ~6–9 h |
| Exp 1 | 9 protocols × 6 zipf values × 1–4 variants = ~162 runs | ~3 h |
| Exp 2 | 9 protocols × 7 key-range values × 1–4 variants = ~189 runs | ~3 h |
| Recovery | etcd / mongodb / zookeeper, 3 reps each, 20 ms latency | ~15 min |
| TLA — small | All 6 specs on `*_small.cfg` (AE budget) | ~30 min |

Total: ~860 runs, **plan for an overnight run**. Selective phase
re-runs are supported — see §4.

The exact concurrency / zipf / key-range arrays the matrix
iterates are inline at the top of `ae/local/run.sh`
(`CONCS_FULL`, `ZIPF_FULL`, `KEYRANGE_FULL`).

### 2.1 Optional — multi-host LAN cluster (~10–15 h, opt-in)

If you happen to have 5 SSH-accessible hosts on a LAN (e.g. an
academic compute pod), you can run the same matrix across the
cluster instead. Faster wall-clock and CPU-utilization figures
become meaningful.

Setup:

1. Edit `ae/local/ips/cluster_ips.json` with your 5 host IPs (template
   provided; see [`ae/local/ips/README.md`](local/ips/README.md)).
2. Verify SSH trust + a shared writable directory.
3. Run:

    ```bash
    ./ae/reproduce_local.sh --mode cluster
    ```

The cluster engine is `10-run_all.sh` (the same script used by
the AWS path), driven against your 5-host topology with software
WAN delay (`WAN_DELAY_MS=20` injected by the binary). Wall-clock
~10–15 h for the full matrix, depending on host CPU.

This path is **not required** for any AE badge.

Output layout:

```
ae/output/reproduce_<timestamp>/
├── SUMMARY.md                  # per-phase file counts + pointer to check_results.sh
├── build/                      # build logs
├── exp0/                       # .res files (one per run)
├── exp1/                       # zipf sweep
├── exp2/                       # key-range sweep
├── recovery/                   # signal-file timestamps + recovery durations
└── tla/                        # TLC logs (small configs)
```

To summarize the output:

```bash
./ae/check_results.sh ae/output/reproduce_<timestamp>
```

This prints per-phase file counts, surfaces any `.res` missing
the expected markers, prints recovery duration min/max, and
reports whether each TLC log ended with "Model checking completed.
No error has been found." It is intentionally non-judgmental —
you interpret the numbers yourself.

### TLA — large configs (paper claim, opt-in)

`reproduce_local.sh` runs TLA only at small-config size to fit the
AE budget. To reproduce the *paper's* state counts (21 M+ for Raft,
11 M+ for CoPilot, etc.), run:

```bash
./ae/tla/one_click_large.sh
# or:
./ae/reproduce_local.sh --phase tla_large
```

Wall-clock: ≥ 12 h on 16 cores; peak RAM ~50 GB. State counts
end up in `ae/tla/log/<timestamp>_<spec>*.log` — TLC's final
progress line is `N states generated, M distinct states found`.

## 3. Reproduced — AWS gold-standard reproduction (~28 h, ~$50)

Users wanting exact paper numbers (absolute throughput, p99
latency, CPU-utilization figures) can run the camera-ready matrix
on AWS:

```bash
# 1. Edit ae/aws/ips/aws_ips.json with your 10 EC2 public IPs
#    (template provided; see ae/aws/ips/README.md)
$EDITOR ae/aws/ips/aws_ips.json

# 2. Run the one-click driver
./ae/reproduce_aws.sh
```

Prerequisites (full detail in
[`ae/aws/camera-ready/settings.md`](aws/camera-ready/settings.md)
and [`ae/aws/ips/README.md`](aws/ips/README.md)):

1. 10 × c5.2xlarge instances in California / Oregon / Mumbai /
   Frankfurt / Stockholm + 5 client-heavy spares.
2. IPs filled in at `ae/aws/ips/aws_ips.json`.
3. SSH trust + NFS + repo bootstrap done — run the numbered scripts
   in `ae/aws/scripts/` (`00-ips.sh` through `07-link_mongocxx.sh`)
   on a first-time setup. The one-click only generates `setup.json`
   from `aws_ips.json` (via `00-ips.sh`); the remaining bootstrap
   steps are manual on first deployment.
4. Patched `mongod` / `etcd` / `zkServer` binaries on each host (built
   from `third_party/` per `ae/aws/scripts/aws_setup_script.sh`).

This path is **not required** for any AE badge — both Functional
and Reproduced are satisfied by §1 + §2. AWS reproduction is for
users who want figure-for-figure replication.

## 4. Selective phases

```bash
./ae/reproduce_local.sh --phase build
./ae/reproduce_local.sh --phase exp0
./ae/reproduce_local.sh --phase exp1
./ae/reproduce_local.sh --phase exp2
./ae/reproduce_local.sh --phase recovery
./ae/reproduce_local.sh --phase tla_small
./ae/reproduce_local.sh --phase tla_large

./ae/reproduce_aws.sh --exp 0
./ae/reproduce_aws.sh --exp 1,2
./ae/reproduce_aws.sh --build-only
```

## 5. TLA+ standalone

The TLA+ specs are also runnable independently of the experiment
matrix:

```bash
./ae/tla/one_click_small.sh   # all 6 specs, small configs (~30 min)
./ae/tla/one_click_large.sh   # all 6 specs, paper configs (12+ h)
```

Or run a single spec via the standard runner:

```bash
cd ae/tla
./run-tlc.sh raft.tla raft_small.cfg
./run-tlc.sh jetpack_raft_composition.tla jetpack_raft.cfg
```

## 6. Layout of `ae/`

```
ae/
├── README.md                    # this file (user entry point)
├── (matrix arrays are inline at the top of `ae/local/run.sh`)
├── HARDWARE.md                  # hardware spec + disk/RAM breakdown
├── reproduce_local.sh           # ★ one-click local
├── reproduce_aws.sh             # ★ one-click AWS
├── check_results.sh             # output sanity-summary tool
├── .gitignore                   # excludes runtime artefacts + filled IP files
├── local/                       # self-contained local reproduction
│   ├── run.sh                       # full local driver (--mode docker|cluster)
│   ├── ips/                         # ★ cluster IP slot (mode=cluster only)
│   │   ├── README.md
│   │   ├── cluster_ips.json.template  # fill in YOUR 5 host IPs
│   │   └── setup.json.template
│   ├── scripts/                     # frozen scripts (incl. 00-..10- + run_native_local.sh)
│   ├── config/                      # frozen YAML configs (~406)
│   ├── docker/                      # frozen Dockerfiles + compose (4 backends)
│   ├── src/, third_party/, bin/, dependencies/, extern_interface/
│   └── waf, wscript, Makefile, CMakeLists.txt, .dockerignore
├── aws/                         # self-contained AWS reproduction
│   ├── run.sh                       # full AWS driver
│   ├── ips/                         # ★ AWS IP slot
│   │   ├── README.md
│   │   ├── aws_ips.json.template    # fill in YOUR 10 EC2 IPs
│   │   └── setup.json.template
│   ├── camera-ready/                # run.sh wrapper + paper-figure generators
│   ├── scripts/                     # frozen 00-..10- + bootstrap (30 scripts)
│   └── config/                      # frozen YAML configs (~406)
├── tla/                         # frozen TLA snapshot
│   ├── one_click_small.sh           # ★ all 6 specs, small configs
│   ├── one_click_large.sh           # ★ all 6 specs, paper configs
│   ├── run-tlc.sh                   # TLC runner
│   ├── *.tla / *.cfg                # 14 specs + 14 configs (flat layout)
│   ├── tla2tools.jar                # TLC v1.7.1
│   └── Dockerfile                   # TLC Docker image
└── output/                      # run outputs land here (gitignored)
```

## 7. Reproducibility contract

1. Run only through `ae/reproduce_local.sh` or `ae/reproduce_aws.sh`.
   They are deterministic given Docker version + the frozen `ae/`
   contents.
2. Do not edit any file under `ae/` between phases (other than
   `ae/output/`). The wrappers stamp the commit SHA into output dirs;
   mid-run edits produce silently inconsistent data.
3. If a phase fails, re-run that phase only
   (`./ae/reproduce_local.sh --phase exp1`) — do not patch by hand.
4. Privileged Docker is required for the local path; tc/netem and
   cgroup access cannot be replaced with userspace shims.
5. Everything `ae/` needs is under `ae/`. If a user ever sees a
   path like `../config/` or `../scripts/` resolving outside `ae/`,
   that's a bug.
