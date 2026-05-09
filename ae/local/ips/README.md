# Cluster IP configuration (optional)

`ae/reproduce_local.sh` defaults to **single-host Docker mode** —
the simplest user experience. This `ips/` directory is only
needed if you want to run the alternative **multi-host cluster
mode** instead.

## When to use cluster mode

Cluster mode is opt-in via:

```bash
./ae/reproduce_local.sh --mode cluster
```

Use it if:
- You have 5 SSH-accessible hosts on a LAN.
- You want CPU-utilization figures to be meaningful (single-host
  Docker contaminates per-core readings).
- You want shorter wall-clock than single-host Docker on the same
  matrix.

If you don't have 5 hosts handy, ignore this directory entirely —
single-host Docker reproduces all four claim sets directionally.

## Setup

1. Copy the template:

    ```bash
    cp ae/local/ips/cluster_ips.json.template ae/local/ips/cluster_ips.json
    ```

2. Edit `cluster_ips.json` — replace each `REPLACE_ME` with the IP
   (or hostname) of one of your 5 hosts. Set `n_server` to 5.

3. Make sure passwordless SSH works between every pair of hosts
   (`ssh user@hostN echo ok`).

4. Decide on a working directory shared across hosts. NFS works
   best; otherwise the harness will rsync the binary to each host.

5. Edit `setup.json.template` if you need different
   `server_username` or `cluster directory` defaults, then save as
   `setup.json`. Or let the runner derive it from `cluster_ips.json`.

## Sanity check

```bash
( cd ae/local/ips && ../scripts/00-ips.sh )
cat ae/local/ips/setup.json | jq .
```

`n_server` should be `"5"`. If `setup.json` is present and valid,
the cluster path will pre-flight successfully:

```bash
./ae/reproduce_local.sh --mode cluster --dry-run
```

## Field reference (`setup.json.template`)

| Field | Meaning |
|---|---|
| `environment` | Internal cluster-engine key — leave as `"zoo"`. |
| `server_username` | SSH username on every cluster host. |
| `n_server` | Number of hosts (must be 5 for the AE matrix). |
| `zoo_directory` | Shared working dir on every host (NFS path is ideal). The field name is a frozen-script detail; "shared cluster directory" is the meaning. |
| `servers[]` | Array of `{ "server_<i>_ip": "..." }` entries, one per host. |

## Notes

- The runner copies your `cluster_ips.json` to a script-internal
  filename before invoking `00-ips.sh`. That's why the template has
  the friendly name even though the underlying script reads from a
  different filename — that's a frozen-script implementation detail
  we don't expose.
- The cluster engine is the same one used by the AWS path
  (`10-run_all.sh`); on a 5-host LAN it injects software WAN delay
  via `WAN_DELAY_MS=20`. CPU pinning works the same as on AWS:
  server thread on core 1, clients spread across the remaining cores.
- This path is **not required** for any AE badge. Both Functional
  and Reproduced are satisfied by the default Docker mode.
