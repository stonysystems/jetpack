# ZooKeeper Latency Analysis

## Summary

ZooKeeper Setting A (Jetpack OFF, low concurrency) showed ~167ms write latency — 4x higher
than etcd (~43ms) and MongoDB (~48ms). Investigation revealed three root causes, all related
to how tc/netem latency simulation interacts with ZooKeeper's architecture on Linux loopback.
After fixing all three, ZK latency dropped to ~45ms (h1) and ~86ms (h2-h5), comparable to
etcd and MongoDB.

## Bug Report

### Failing benchmark (before fix)

- **Setting**: ZK A (5 clients, concurrency=1, Jetpack OFF, 20ms one-way tc/netem)
- **Expected**: h1 ~43ms (0 RTT + ~43ms ZAB repl), h2-h5 ~83ms (40ms RTT + ~43ms)
- **Actual**: h1 ~167.5ms, h2-h5 ~167.5ms (uniform across all hosts)
- **Reference**: etcd A h1=43.6ms, h2-h5=83.7ms

### Root Causes

Three independent issues combined to inflate ZK latency by ~4x:

#### 1. ZAB leader not at 127.0.0.1

ZooKeeper's Fast Leader Election (FLE) picks the server with the highest `zxid`, breaking
ties by highest `myid`. At fresh start (all zxid=0), the node with the highest myid wins.

The original `start_zookeeper_ensemble()` assigned myid sequentially:
- 127.0.0.1 → myid=1
- 127.0.0.2 → myid=2
- 127.0.0.3 → myid=3 (highest → becomes ZAB leader)

Since the ZAB leader was at 127.0.0.3 (a tc/netem-delayed IP), all writes from the Jetpack
leader at 127.0.0.1 were forwarded to 127.0.0.3, adding ~40ms RTT.

**Fix**: Reversed myid assignment: 127.0.0.1→myid=3, 127.0.0.2→myid=2, 127.0.0.3→myid=1.
Now 127.0.0.1 wins the election, eliminating write forwarding.

#### 2. tc/netem delay applied to 127.0.0.1 self-traffic

The ZK `setup_latency()` function applied tc/netem delay to ALL five loopback IPs:
```bash
local ips=("127.0.0.1" "127.0.0.2" "127.0.0.3" "127.0.0.4" "127.0.0.5")
for ip in "${ips[@]}"; do
    tc filter add dev lo parent 1:0 protocol ip u32 match ip dst "$ip" flowid 1:4
done
```

The etcd script, by contrast, **skips 127.0.0.1**:
```bash
for ip in "${MULTI_LOOPBACK_IPS[@]:1}"; do  # Starts from index 1
```

With 127.0.0.1 in the filter, local self-traffic (Jetpack h1 → ZK leader at 127.0.0.1)
got an artificial 20ms delay, and ZK follower → leader responses were also delayed.

**Fix**: Changed ZK `setup_latency()` to skip 127.0.0.1, matching the etcd pattern.
Also added `match ip src` filters (both src and dst) to delay traffic in both directions.

#### 3. ZK ZAB peer traffic invisible to IP-based tc filters

This was the most subtle issue. On Linux loopback, **all TCP connections use 127.0.0.1 as
source IP**, regardless of which loopback alias the server binds to. This is a kernel
routing behavior: for loopback traffic, the source IP is always the lowest loopback address.

**ZK architecture**: In ZAB, followers connect TO the leader. The leader at 127.0.0.1:2888
accepts inbound connections from followers. Even though followers are configured at
127.0.0.2 and 127.0.0.3, their TCP connections show:
```
127.0.0.1:ephemeral → 127.0.0.1:2888  (both endpoints are 127.0.0.1!)
```

Since neither `src 127.0.0.2` nor `dst 127.0.0.2` matches, tc/netem never delays ZK peer
traffic. ZAB replication happens at local loopback speed (~0ms), not the intended ~40ms RTT.

**etcd architecture** (for comparison): etcd uses a different connection pattern. The leader
connects TO followers at their listen addresses:
```
127.0.0.1:ephemeral → 127.0.0.2:2380  (dst=127.0.0.2, matches tc filter!)
```

So etcd's Raft replication traffic IS delayed by the `dst` filter, producing the correct
~20ms one-way delay.

**Fix**: Added port-based tc filters for ZK's leader peer port (2888). This matches traffic
regardless of IP addresses:
```bash
tc filter add ... u32 match ip dport 2888 0xffff flowid 1:$band  # follower→leader
tc filter add ... u32 match ip sport 2888 0xffff flowid 1:$band  # leader→follower
```

Both directions get 20ms delay, producing ~40ms RTT for ZAB replication — matching the
intended WAN simulation.

## Verification

### Before fix

| Setting | h1 (ms) | h2-h5 (ms) | Notes |
|---|---:|---:|---|
| ZK A (off) | 167.5 | 167.5 | All hosts uniform due to 3 compounding issues |
| ZK C (on) | 40.6 | 40.5 | Jetpack fast path unaffected |

### After fix

| Setting | h1 (ms) | h2-h5 (ms) | Notes |
|---|---:|---:|---|
| ZK A (off) | 45.5 | 86.0 | Matches expected: 0/40ms RTT + ~45ms ZAB repl |
| ZK B (off, 60c) | — | — | 5,743 txn/s (was 5,622) |
| ZK C (on) | 40.3 | 40.5 | Jetpack fast path, 1 RTT |
| ZK D (on, 60c) | — | — | 5,498 txn/s (was 5,805) |

### Comparison with etcd and MongoDB

| Backend | h1 Avg (ms) | h2-h5 Avg (ms) | Delta h1→h2-h5 |
|---|---:|---:|---:|
| etcd | 43.6 | 83.7 | 40.1 (1 RTT) |
| MongoDB | 47.7 | 88.0 | 40.3 (1 RTT) |
| ZooKeeper | 45.5 | 86.0 | 40.5 (1 RTT) |

All three backends now show the expected pattern: h1 latency ≈ backend replication time,
h2-h5 latency ≈ h1 + 40ms (one client→leader RTT). The 40ms delta confirms tc/netem is
working correctly for all backends.

## Technical Details

### ZK vs etcd connection architecture

The key architectural difference that caused the tc/netem discrepancy:

| Property | etcd (Raft) | ZooKeeper (ZAB) |
|---|---|---|
| Peer connection direction | Leader → followers | Followers → leader |
| Leader peer socket | Connects TO follower IPs | Listens for inbound |
| Traffic dst IP | 127.0.0.2/3 (delayed) | 127.0.0.1 (not delayed) |
| tc/netem match | `dst` filter matches | Neither filter matches |

### Linux loopback source IP behavior

On Linux, TCP connections between loopback aliases (127.0.0.x) always use 127.0.0.1 as
the source IP. This is because all loopback addresses share the `lo` interface, and the
kernel's routing table selects the primary address (127.0.0.1) as source:

```
$ ss -tn | grep 2888
ESTAB 127.0.0.1:36410 → 127.0.0.1:2888   # follower at 127.0.0.2, but src=127.0.0.1
ESTAB 127.0.0.1:36418 → 127.0.0.1:2888   # follower at 127.0.0.3, but src=127.0.0.1
```

etcd works around this implicitly because it connects TO followers (using dst=127.0.0.2),
not FROM followers. The `match ip dst 127.0.0.2` filter catches this traffic.

### Port-based filter rationale

The port filter delays traffic on ZK's peer port 2888 in both directions:
- `dport 2888`: follower → leader data (ACKs, connect)
- `sport 2888`: leader → follower data (proposals, commits)

This produces 20ms + 20ms = 40ms RTT per ZAB proposal/ack exchange, which is the same
effective RTT as etcd's IP-based filtering produces for Raft replication.

## Files Modified

- `docker/zookeeper/run-zookeeper-test.sh`:
  - `start_zookeeper_ensemble()`: reversed myid assignment, updated server.X lines
  - `setup_latency()`: excluded 127.0.0.1, added src+dst IP filters, added ZK peer port filter
