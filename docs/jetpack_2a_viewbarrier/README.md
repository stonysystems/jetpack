# Jetpack and etcd: the "Route 2a" view barrier (landed)

Design + implementation for making Jetpack failure-recovery trigger from etcd's
**real** leadership, on the exact new-leader boundary, without dropping commands.

**Status: landed and verified end-to-end.** The etcd patch builds against
v3.5.13 (Go 1.21.8) and the deptran side lives in `jm_file_signal.h`,
`src/deptran/etcd/server.h` and `src/deptran/scheduler.{h,cc}`. The `.draft.*`
files in this directory are kept only as a record of the original proposal;
they differ from what shipped; see "Deviations from the draft".

Build the patched etcd with `scripts/build_etcd_patched.sh --leader viewbarrier`
(the default for `aws_setup_script.sh` and `docker/etcd/Dockerfile`), and
exercise the handshake with `scripts/run_local_etcd_recovery_test.sh`.

Measured on a single host, 3 etcd + 3 deptran, killing the etcd leader:

```
22:35:27.605983  etcd     view barrier armed (raft loop blocked, term 3)
22:35:27.606295  jetpack  RECOVERY entered
22:35:27.606     jetpack  leader_paused term=3 nonce=... written
22:35:27.607389  etcd     view barrier RELEASED   <- 1.4ms, not the 200ms fail-open
22:35:27.612543  jetpack  recovery COMPLETED (6ms)
```

etcd resumed ~5ms *before* recovery finished, so the recovery's own resubmits
replay through a live etcd; the no-deadlock property holds in practice.
Exactly one replica coordinated (the one co-located with the new leader);
the other two ran nothing. A control run with no failure induced produced
zero recoveries on all three.

## The problem this solves

For the etcd backend, Jetpack recovery was triggered by a file signal that only
carried "leadership changed" — never the real etcd term — so the recovery `View`
always had `view_id_ == 0`, and the trigger was decoupled from etcd's own
leader-election boundary. Route 2a hooks the *instant etcd becomes raft leader,
before it serves its first command*, hands off to the co-located Jetpack replica,
and only resumes once Jetpack has paused. New-view commands are briefly delayed
(~ms), never dropped; no per-command marker or client-side leader watcher needed.

## The handshake (deadlock-free)

```
etcd (new leader)                         deptran (co-located replica, separate process)
-----------------                         ----------------------------------------------
becomes raft leader
  updateLeadership(newLeader) [raft loop]
  jetpackViewBarrier():
    write "etcd:viewchange term=T nonce=N"
    ── blocks the raft loop, polling ──►   poller reads viewchange (1ms loop)
    (no AppendEntries / no-op sent yet)      first view = baseline: ack directly
                                             real failover:
                                               set jetpack_status_ = RECOVERY   (scheduler.cc:1103)
                                               write "jetpack:leader_paused term=T nonce=N" (:1123)
    ◄── reads term+nonce-matched ack ──      then run recovery rounds + resubmit (:1129)
    barrier releases (~2-3ms)
  sends first AppendEntries (raft.go:237)
                                             resubmits replay through etcd (now resumed) → no deadlock
```

Key property: the ack is emitted at recovery **start** (after RECOVERY is set,
before the ~80ms recovery), so etcd unblocks in ~ms and the recovery's own
resubmits (which replay through etcd) are never blocked → **no deadlock**.
Because the `updateLeadership` hook runs before `r.transport.Send` and before
`storage.Save`, not even the term's no-op entry is sent/persisted until the ack.

## Files

| File | Applies to | What |
|---|---|---|
| `../../patches/etcd-jetpack-2a-viewbarrier-v3.5.13.patch` | etcd **v3.5.13** `server/etcdserver/server.go` | `jetpackViewBarrier()` + per-boot `jetpackBootNonce` + call in `updateLeadership`. `git apply`-clean against pristine v3.5.13. |
| `deptran-jm_file_signal.draft.h` | `jm_file_signal.h` | `read_latest_value` (value-prefix filtered) + `parse_uint_field`. |
| `deptran-etcd-server-h.draft.cpp` | `src/deptran/etcd/server.h` (replaces the `if (loc_id_!=0){...poller...}` block, lines ~55-82) | poller on **every** replica (machine-local signal ⇒ single recovery coordinator = the replica co-located with the new etcd leader); baseline-skips the startup election; nonce echo. |
| `deptran-scheduler-ack.draft.cpp` | `src/deptran/scheduler.{h,cc}` | `JetpackRecoveryEntry(epoch_t etcd_view=0, uint64_t etcd_nonce=0)`; emits the term+nonce ack right after `fastpath_stopped`. |

## Signal contract (byte-for-byte)

```
etcd writes:    etcd:viewchange term=<T> nonce=<N> lead=<S> member=<S>\n
deptran reads:  read_latest_value("etcd", host, "viewchange")  →  parse term/nonce/lead
deptran acks:   jetpack:leader_paused term=<T> nonce=<N>\n      (baseline directly / failover inside JetpackRecoveryEntry)
etcd polls for: jetpack:leader_paused term=<T> nonce=<N>\n
```
`host` = `JM_SIGNAL_HOST` env or `0.0.0.0`; deptran uses `0.0.0.0` under `#ifdef AWS`
(the two sides only provably agree under AWS). `N` is a per-etcd-boot nonce so a
stale ack from a prior run (terms reset to small values) can never release a
fresh barrier.

## Adversarial review verdict (static; no compiler was run)

Reviewed across 5 lenses — **fundamentally sound, deadlock-free, no compile
blockers found statically**:
- No self-deadlock: `raftStatus()` from the raft loop is serviced by the separate
  `node.run` goroutine (idle after handing off the Ready).
- Barrier placement correct: runs before `storage.Save` and `r.transport.Send`.
- Ack ordering correct: emitted at recovery-start ⇒ ~ms barrier, resubmits unblocked.
- Already included: newline-anchored ack (no `term=6` vs `term=60`),
  election-timeout-derived deadline (cap 200ms), per-boot nonce, startup baseline,
  poller on all replicas.

## Deviations from the draft

The shipped version differs from the `.draft.*` files in two places.

1. **Baseline detection.** The draft suppressed "the first viewchange I ever
   see" via a `baseline_set` flag flipped on first observation. That does not suit
   a replica whose etcd was *not* the startup leader: such a replica sees no
   viewchange at all until a failover promotes it, so its first-ever viewchange
   *is* the failover, and would be taken as the baseline. Observed directly: the
   replica co-located with the new leader logged `baseline view term=3 (startup)`
   and ran no recovery. The shipped version establishes the baseline **once at
   startup from what is already on disk**; an empty file means "my etcd is not
   the startup leader, so anything from here is a real failover."

2. **`leaders_` is populated.** The draft left it empty (its open issue #3).
   It holds **site ids** (`OnJetpackBeginRecovery` compares `GetLeader()`
   against `site_id_`), so the shipped code uses `View(n, site_id_, term)`.
   With it empty the recovery view logged `WARNING: New view has no leaders` and
   could not step down a stale leader. Also uses `GetPartitionSize()` rather than
   the draft's `GetReplicaHosts().size()`, to match the quorum arithmetic in
   `Communicator::JetpackBroadcastPullRecovery`.

## Still open

1. **Recovery rounds.** Route 2a provides the trigger (view id, barrier, single
   coordinator). `jepoch_`/`oepoch_` start at 0, and the `QuorumEvent` epoch
   accumulators start at 0. A recovery round sends Prepare at the proposer's
   current `max_seen_ballot_` (`scheduler.cc:1164`), so successive rounds share
   a ballot; giving each round a unique, increasing ballot is the next step.
2. **etcd-only.** MongoDB/ZooKeeper still use the old `primary_elected`
   mechanism; their upstream server source is not vendored here.
3. **Dead fallback code.** `src/deptran/etcd_leader_watcher.h` watches a
   `JetPack/leader` key nothing writes outside the docker harness, and
   `s_main.cc` hands it a signal host derived from `hosts[1]` while every poller
   reads `0.0.0.0`. It never fired; now it is also redundant. Should be removed.
4. **All replicas share one etcd endpoint.** `EtcdServer::Setup()` builds
   `etcd_uri_` from `hosts[0]` for *every* replica, so they all talk to replica
   0's etcd rather than their co-located one. Orthogonal to the trigger, but it
   means killing etcd0 disconnects everyone.
5. **Startup ordering is assumed.** The baseline logic requires deptran to start
   after the etcd cluster is healthy (which every launch path does). A deptran
   that starts first would see an empty file and treat the startup election as a
   failover.
