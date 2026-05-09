# AWS EC2 Setup

Settings used when launching EC2 instances for this project.

## Regions

| Index | Region        | AWS code        |
| ----- | ------------- | --------------- |
| 00    | California    | us-west-1       |
| 01    | Oregon        | us-west-2       |
| 02    | Mumbai        | ap-south-1      |
| 03    | Frankfurt     | eu-central-1    |
| 04    | Stockholm     | eu-north-1      |
| 05    | London        | eu-west-2       |
| 06    | Hong Kong     | ap-east-1       |
| 07    | Singapore     | ap-southeast-1  |
| 08    | Ireland       | eu-west-1       |
| 09    | Paris         | eu-west-3       |

## Instance

- AMI: Ubuntu 22.04 (x86_64)
- Instance type: c5.2xlarge

## Inbound security group rules

Source: `0.0.0.0/0` (and `::/0` for IPv6) for all rules.

| Protocol | Port range  |
| -------- | ----------- |
| TCP      | 100 – 50000 |
| UDP      | 100 – 50000 |
| ICMP     | All         |
| TCP      | 22          |

## Root EBS volume (gp2)

| Index | Region     | Size   |
| ----- | ---------- | ------ |
| 00    | California | 128 GB |
| 01–09 | Others     | 16 GB  |

## SSH key pair

- Name in AWS: `zoo-key`
- Source: import the existing `config/ssh/id_rsa.pub` into each region via `aws ec2 import-key-pair`. AWS does not generate a new keypair — the same private key (`config/ssh/id_rsa`) is used to SSH every instance.

## Network

- VPC / subnet: default VPC, default subnet (first AZ).
- Each instance gets a public IP at launch and is then associated with a newly allocated **Elastic IP** for a stable address.

## Tagging

- Instance `Name` tag: `jp-<index>-<city>` (e.g. `jp-00-california`, `jp-06-hongkong`).
- Elastic IP `Name` tag: same as the instance it's associated with.
- Security group name: `jp-cluster` (one per region, identical rules).

## Scripts

- [aws_create_instances.sh](aws_create_instances.sh) — launches one instance per region per the table above. Idempotent for key import + SG creation; calling `run-instances` again creates a *new* instance. Env vars: `SKIP_INDICES="00 01"` to skip regions, `STOP_AFTER_LAUNCH=1` to stop each instance immediately after launch + EIP association.
- [aws_instances.tsv](aws_instances.tsv) — current inventory: `index<TAB>city<TAB>region<TAB>instance_id<TAB>eip`.
- [aws_start_instances.sh](aws_start_instances.sh) / [aws_stop_instances.sh](aws_stop_instances.sh) — start/stop every instance in the inventory. Env var: `ONLY_INDICES="00 03"` to act on a subset.
