# AWS IP configuration

`ae/reproduce_aws.sh` reads the cluster topology from
`ae/aws/ips/setup.json`. You can either:

1. Provide raw IPs in `aws_ips.json` and let `00-ips.sh` derive
   `setup.json`, or
2. Provide `setup.json` directly.

## Path A — fill in `aws_ips.json` (recommended)

1. Copy the template:

    ```bash
    cp ae/aws/ips/aws_ips.json.template ae/aws/ips/aws_ips.json
    ```

2. Edit `ae/aws/ips/aws_ips.json`. Replace each `"REPLACE_ME"` with
   the public IP of the corresponding EC2 instance. Replace
   `"REPLACE_ME_KEY"` with the path to your SSH private key.

3. Topology required by the camera-ready paper:

    | Index | Region | Role |
    |---:|---|---|
    | 0 | us-west-1 (California) | NFS host, server + client |
    | 1 | us-west-2 (Oregon)     | server + client |
    | 2 | ap-south-1 (Mumbai)    | server + client |
    | 3 | eu-central-1 (Frankfurt) | server + client |
    | 4 | eu-north-1 (Stockholm) | server + client |
    | 5 | eu-west-2 (London)     | client-heavy |
    | 6 | ap-east-1 (Hong Kong)  | client-heavy |
    | 7 | ap-southeast-1 (Singapore) | client-heavy |
    | 8 | eu-west-1 (Ireland)    | client-heavy |
    | 9 | eu-west-3 (Paris)      | client-heavy |

    `ae/aws/scripts/aws_create_instances.sh` will provision exactly
    this topology if you have AWS credentials configured.

4. `reproduce_aws.sh` calls `00-ips.sh` for you on first run; the
   resulting `setup.json` is cached in this directory.

## Path B — provide `setup.json` directly

Skip `aws_ips.json` and fill in `setup.json` yourself:

```bash
cp ae/aws/ips/setup.json.template ae/aws/ips/setup.json
$EDITOR ae/aws/ips/setup.json
```

Required fields: `environment` (`"aws"`), `server_username`,
`n_server` (`"10"`), `servers[]`. See the template for the exact
shape.

## Sanity check

After filling in either file:

```bash
( cd ae/aws/ips && ../scripts/00-ips.sh )    # generates / refreshes setup.json
cat ae/aws/ips/setup.json | jq .             # should print valid JSON
```

If `setup.json` is present and valid, `ae/reproduce_aws.sh` will
proceed; otherwise it errors out in pre-flight.
