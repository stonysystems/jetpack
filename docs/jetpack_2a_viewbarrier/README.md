# Jetpack ⇄ etcd "Route 2a" view-barrier (DRAFT — not landed)

Design + draft implementation for making Jetpack failure-recovery trigger from
etcd's **real** leadership, on the exact new-leader boundary, without dropping
commands. **Status: draft only.** Nothing here is applied to the deptran source
tree, compiled, or benchmarked. See "Open issues" before relying on any of it.

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
- Fixes already folded in: newline-anchored ack (no `term=6` vs `term=60`),
  election-timeout-derived deadline (cap 200ms), per-boot nonce, startup baseline,
  poller on all replicas.

## Open issues (must resolve before this is real)

1. **Never compiled.** No Go toolchain was available; the patch was only
   `git apply`-checked + statically reviewed. deptran C++ likewise not compiled.
2. **Recovery-protocol correctness is untouched.** Route 2a fixes the *trigger*
   (view_id, barrier, single coordinator) but rides on pre-existing recovery bugs
   the first audit found (`jepoch_/oepoch_` uninitialized; `OnJetpackPrepare/Accept`
   accept an equal ballot via `>=`; `RecordCmd` quorum vacuous). Verify the
   recovery Paxos — especially with the coordinator running on the hardcoded
   deptran leader (loc0) — before trusting recovery.
3. **`leaders_` left empty.** etcd's `lead` is an etcd member id, not a deptran
   loc_id. The co-located replica knows its own `loc_id_` (= the new leader's
   deptran locale), so an alternative is `View(n, loc_id_, term)` +
   `UpdatePartitionView` (mirroring Raft's `setIsLeader`). Undecided.
4. **etcd-only.** MongoDB/ZooKeeper still use the old `primary_elected` mechanism;
   their upstream server source is not vendored in this repo.
5. **No landing pipeline.** The repo installs *vanilla* etcd binaries
   (`aws_setup_script.sh`: etcd v3.5.13 release; docker: v3.5.17). Using this
   patch requires a build-from-source-and-apply pipeline that does not exist yet.
   (Also note: the patch targets v3.5.13 = the AWS version; docker uses v3.5.17.)
6. **No end-to-end test.** The handshake, the ~2-3ms timing, and fail-open
   behavior have never been run.
