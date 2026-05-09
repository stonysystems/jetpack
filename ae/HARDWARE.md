# Hardware specification

## Local — single host (default path)

| Component | Minimum | Recommended | Notes |
|---|---|---|---|
| OS | Linux kernel ≥ 5.4 | Ubuntu 22.04 LTS | tc/netem and cgroups v2 are used by the privileged tests |
| CPU | 8 physical cores | 16 physical cores | 5 server processes pinned to disjoint cores + 5 clients; SMT does not count |
| RAM | 16 GB | 32 GB | TLA large configs are the dominant consumer; bench matrix is well below 16 GB |
| Disk free | 80 GB | 150 GB | Sources + Docker images + per-run outputs |
| Network | localhost-only | localhost-only | The local mode does not use the network outside of Docker bridge interfaces |
| Docker Engine | 17.05+ | 24.0+ | Required for all local phases except TLA |
| Docker Compose | V2 (`docker compose ...`) | latest | Legacy `docker-compose` (V1) is **not** supported |
| Privileged Docker | required | required | Needed for tc/netem (WAN simulation) and cgroup access (TLC memory caps) |
| Java | 8+ (for local TLA mode) | 11 | Optional — the runner falls back to a Docker-based TLA invocation if no Java |

Disk usage on a full-matrix run is dominated by the Docker image
cache (single-digit GB) plus per-run `.res` files. The artifact
tree itself is 142 MB.

## Local — multi-host LAN cluster (opt-in via `--mode cluster`)

| Component | Minimum |
|---|---|
| Hosts | 5 SSH-accessible Linux hosts |
| Per-host CPU | 8 physical cores |
| Per-host RAM | 8 GB |
| Per-host disk free | 30 GB |
| Inter-host network | 1 Gbps LAN |
| SSH trust | Passwordless between every pair, plus from the driver host to all 5 |
| Shared FS | Strongly recommended — NFS mount on a single shared path; otherwise the harness rsyncs the binary to each host before each run |
| Privileged | not required (no tc/netem in cluster mode — software WAN delay via `WAN_DELAY_MS` env var) |

## AWS — gold-standard reproduction

Per [`ae/aws/camera-ready/settings.md`](aws/camera-ready/settings.md) §1:

| Component | Spec |
|---|---|
| Instance type | `c5.2xlarge` (8 vCPU, 1 socket, 4 physical cores × SMT2) |
| Count | 10 |
| Topology | 5 server-side (CA / OR / Mumbai / Frankfurt / Stockholm) + 5 client-heavy (London / Hong Kong / Singapore / Ireland / Paris) |
| Per-instance disk | 100 GB gp3 |
| Pre-installed | Ubuntu 22.04, Docker (for build only on server0), patched mongod / etcd / zkServer binaries |
| AWS regions | `us-west-1, us-west-2, ap-south-1, eu-central-1, eu-north-1, eu-west-2, ap-east-1, ap-southeast-1, eu-west-1, eu-west-3` |
| Estimated cost | ~$50 for the full ~28 h run |

## What does not need to be reproduced on local hardware

Absolute throughput, CPU utilization, tail-latency p99.9, and
per-region claims are AWS-only — single-host Docker can't capture
cross-region jitter or per-core CPU isolation.
