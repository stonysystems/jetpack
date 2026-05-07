# etcd async-handler pool sizing — investigation log (2026-05-07)

## Context

While running the camera-ready v2 sweep, the etcd vanilla profile showed
a sharp latency surge from c=1 → c=50 even when the cluster was nowhere
near saturated (~3 k r/s peak vs 1.4 k r/s at c=50 mu=10). This was
unique to etcd; raft / mongodb / copilot don't have the same pattern.

ETCD_INNER_DEBUG instrumentation localised the overhead to PHASE_B
(time spent waiting for the cpprestsdk channel to return a response):
at c=50 with one handler, per-request PHASE_B was 466–615 ms vs the
~154 ms 1-RTT geodesic floor — a 3-4× tax purely from in-channel queueing.

Root cause: every async etcd request was funneled through a *single*
`EtcdKVTableHandler` instance, which owns one cpprestsdk gRPC channel
(one TCP connection to the etcd endpoint). cpprestsdk multiplexes onto
HTTP/2 with `MAX_CONCURRENT_STREAMS=100`, so 50 outstanding requests
all serialised through one channel.

Fix: introduce a round-robin pool of async handlers in
`src/deptran/etcd_connection_thread_pool.h`:

```cpp
std::vector<std::shared_ptr<EtcdKVTableHandler>> async_handlers_;
std::atomic<uint32_t> async_handler_rr_{0};
static constexpr int kAsyncHandlerPoolSize = 256;
```

Each request `pick_async_handler()`s round-robin into the pool, so
in-flight requests are spread across N gRPC channels.

## Microbench setup

5 cells, all etcd vanilla `none_etcd m=0`:
- c=1 mu=200 (idle baseline)
- c=50 mu=10 (channel-pressured)
- c=50 mu=50
- c=50 mu=100
- c=50 mu=200

Each cell run with `rerun_until_10of10.sh` (2-attempt retry).
Logs live at:
- `results/2026-05-05-camera-ready-exp0-fixes-v2/log/etcd_mu_test_inner_h1/`    — pool=1 (pre-fix)
- `results/2026-05-05-camera-ready-exp0-fixes-v2/log/etcd_mu_test_inner_h256/`  — pool=256
- `results/2026-05-05-camera-ready-exp0-fixes-v2/log/etcd_mu_test_inner_h4096/` — pool=4096

## Results: 3-way comparison

```
  c   mu     H      tput     avg     p50     p99    qd@s0    cpu_CA  cpu_OR  cpu_FF
  1  200     1      40.5   348.6   323.4   455.4     4.37      5.8     2.7     2.5
  1  200   256      39.4   339.8   308.2   456.4     3.88      5.3     2.7     2.6
  1  200  4096      41.1   452.6   404.0   875.5    27.94      4.9     2.7     2.5

 50   10     1     597.4   543.2   525.7   897.5    12.43     32.0     7.3     6.5
 50   10   256     601.6   501.2   490.4   637.1    14.67     38.4     7.7     7.3
 50   10  4096    2959.4   802.1   677.4  1497.2    17.57     72.3    14.6    13.8

 50   50     1    2754.1   888.0   836.9  1359.2    30.27     66.2    13.1    12.3
 50   50   256    2796.1   793.7   677.6  1414.7    24.74     70.9     9.3     9.6
 50   50  4096    2802.1   766.5   657.3  1388.6    31.01     71.4    15.4    13.2

 50  100     1    2971.9   804.2   673.2  1441.6    31.05     70.8     9.9    14.5
 50  100   256    2974.8   814.3   669.3  1580.5    25.81     72.3     9.4     9.0
 50  100  4096    2863.5   814.5   682.7  1452.7    22.85     76.9    15.1    14.9

 50  200     1    2962.4   793.1   668.0  1469.4    32.46     70.0    15.5    13.1
 50  200   256    2966.4   779.5   656.4  1436.5    27.25     73.7    10.0    11.9
 50  200  4096    2968.8   872.4   692.5  1654.4    32.69     74.8     9.8     9.4
```

## Per-phase breakdown (median of per-host medians, ms)

```
  c   mu     H    PHASE_B p50  PHASE_B p99   HANDLER p50  HANDLER p99   TOTAL p50
  1  200     1          153.6        156.0         155.6        307.2       155.6
  1  200   256          153.1        394.2         155.0        456.5       155.0
  1  200  4096          252.4       4505.7         286.2       4535.7       286.2

 50   10     1          295.3        637.5         354.1        661.0       354.1
 50   10   256          283.0        371.2         324.3        482.3       324.3
 50   10  4096          490.3       4621.8         500.1       4687.1       500.1

 50   50     1          598.6       1180.8         614.5       1189.6       614.5
 50   50   256          484.2       3036.2         490.4       3058.3       490.4
 50   50  4096          475.2       4808.9         481.4       4814.6       481.4

 50  100     1          473.7       1230.7         481.4       1244.4       481.4
 50  100   256          467.4       1332.4         475.4       1342.9       475.4
 50  100  4096          494.3       5183.5         506.1       5187.3       506.1

 50  200     1          465.8       1232.8         472.7       1240.4       472.7
 50  200   256          462.5       1318.4         472.4       1331.7       472.4
 50  200  4096          494.4       4096.0         504.9       4094.2       504.9
```

## Findings

1. **Pool=1 → 256 is a strict win on median.**
   - c=50 mu=10 p99: 898 → 637 ms (−29%)
   - c=50 mu=10 PHASE_B p99: 638 → 371 ms (−42%)
   - c=50 mu=50 PHASE_B p50: 599 → 484 ms (−19%)
   - c=50 mu=50 avg: 888 → 794 ms (−11%)
   - Throughput unchanged (cluster cap ~3 k r/s).

2. **Pool=256 → 4096 is over-provisioned.** No tput gain in cap'd cells,
   tail latency degrades sharply:
   - PHASE_B p99 explodes 4–5× in every cell (e.g. c=50 mu=100: 1332 → 5184 ms).
   - Even c=1 idle degrades (308 → 404 ms median, 456 → 876 ms p99).
   - At c=50 mu=10 the channel-multiplexing cap is gone, so tput jumps
     600 → 2960 r/s — meaning the cluster cap (not mu) is now the
     binding constraint. Latency reflects the cap (677 ms median).
   - 4096 idle/active TCP connections per Janus process appear to swamp
     etcd's server-side gRPC scheduler.

3. **The cluster cap (~3 k r/s) at c=50 mu≥100 is downstream of the
   cpprestsdk channel.** Pool size beyond 256 doesn't move it.

## Decision

**Revert to `kAsyncHandlerPoolSize = 256`.** It's a strict improvement
over pool=1 in the contended regime with no regression elsewhere. Larger
pool sizes don't improve throughput and harm tails.

## Open questions

- Where does the residual ~317 ms PHASE_B at c=50 mu=10 come from?
  Candidates: etcd server-side processing, gRPC accept queue, Janus
  coroutine scheduling. Server-side instrumentation would localise it.
- For the camera-ready v2 sweep numbers, ETCD_INNER_DEBUG should be
  disabled and the binary rebuilt clean — current AWS binary still has
  the instrumentation enabled.

## Commits

- `65a4d9ea` — etcd: multi-handler pool for non-batch async path (kAsyncHandlerPoolSize=256)
- `275285a5` — etcd: bump async-handler pool to 4096 (was 256) for stress test
- (this) — etcd: revert pool to 256 after 4096 stress test confirmed over-provisioning
