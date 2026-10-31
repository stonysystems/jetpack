# Fidelity: docs/pseudocode.md lines to the model

Every line of the pseudocode §0, §1 (N1-N25), §2 (T1-T2, L1-L54), and where it lives in `model/`.
"DR-n" refers to `DECISIONS.md`. Files: `model/replica.rs` (R), `model/client.rs` (K),
`model/system.rs` (S), `model/types.rs` (T).

## §0 notation and state

| the pseudocode | Model |
|---|---|
| view record, id, replicas, proposers | T `View`, `view(cfg, id)`, `proposers(cfg, v) = {proposer(v)}`; ids in states and messages (DR-1); `Config::replicas` constant |
| ⊥ | T `bot() = -1` |
| maj, t, sq | T `maj`, `t`, `sq` (`n = cfg.replicas.len()`); R `c_maj`, `c_t`; K `c_sq` |
| k (ballot), compare views first then ballots | T `Bal { v, k }`, `bal_lt` lexicographic |
| R.last_normal_view, R.new_view, R.mode | R `ReplicaState.lnv`, `.nv`, `.mode` |
| R.pool[w] | R `.pool` (the pool of `lnv`; `pool_of(s, w)`, DR-2) |
| R.max_seen_ballot[w] | R `.msb` (`msb_of`, absent = ⊥) |
| R.accepted[w] | R `.accepted` (T `Acc`, absent = ⊥) |
| R.olog | R `.olog`, `.committed` (DR-5) |
| join(v) | R `join` |
| learn(u), "runs BEFORE the handler" | R `learn`; applied in `RecvPrepare`, `RecvAccept` (v_n), `CoordNack` (lnv'), `RecvFinishRecovery` (v), `CoordBeginOK` (the largest lnv, DR-11); clients: `ClientRecvFastNack` |
| Pending(R.olog) | R `pending_cmds` (DR-16) |
| SpecExec_R(c) | not modeled (DR-3) |
| C.view, C.v_n, C.k, C.rset | R `Coord` (+ `phase`) |
| K.view | K `ClientState.view` |
| Initially | S `Init`, R `replica_init`, K `client_init` |
| a replica added later | not modeled (constant membership, DR-1) |
| Persistence | implicit: no crash step loses state |
| Invariants on R | `top.rs` theorems 1a, 1b |
| A1-A3 | S oracle: `log`, `committed`, `Replicate`, `AdvanceCommit`, `ReplicaCommit` (DR-5) |
| A4, A5, A7 | not modeled (not needed by the theorems) |
| A6 | not modeled (DR-1) |

## §1 normal path

| Line | Model |
|---|---|
| N1 | K `ClientSendFastCmd`: `to_replicas(.., FastCmd { view: K.view, cmd })` |
| N2 | K `ClientFastCommit`: a FastAck(K.view, c) from every r of q, addressed to K |
| N3 | K `ClientFastCommit`: `q.len() >= c_sq`, `q.contains(proposer(K.view))` |
| N4 | not modeled (DR-3) |
| N5 | K `ClientFastCommit`: `fast.insert(FastCommit { view, cmd })` |
| N6-N7 | not modeled (DR-3) |
| N8-N9 | K `ClientRecvFastNack` |
| N10 | K `ClientSendFastCmd` (the same packets) |
| N11 | S `AppendCmd` (DR-4) |
| N12-N13 | R `RecvFastCmd`, first guard: `v == lnv && mode is Normal && no_conflict(cmd, pool ∪ pending_cmds)` |
| N14 | R `RecvFastCmd`: `pool: s.pool.insert(cmd)` |
| N15 | not modeled (DR-3) |
| N16 | R `RecvFastCmd`: `send_to(src, FastAck { view, cmd })` |
| N17 | R `RecvFastCmd`, second guard: `v != lnv || mode is Recovery` |
| N18 | R `RecvFastCmd`: `FastNack { lnv, mode }` (a conflict alone: no reply) |
| N19-N20 | S `AppendCmd` (DR-4) |
| N21 | R `ObserveCommitted`: guard `exists j < committed: entry_cmds(olog[j]).contains(cmd)`; `pool.remove(cmd)` if Normal |
| N22 | not modeled (DR-3) |
| N23 | R `ObserveCommitted`: `broadcast(Evict { cmd })` |
| N24 | R `RecvEvict` |
| N25 | not modeled beyond `entry_cmds` (commands are ids; execution = committed prefix, DR-5) |

## §2 trigger

| Line | Model |
|---|---|
| T1 | S `NewView`: the proposer's replica gets `Coord { phase: P1, view: v, vn: ⊥, k: 0, rset: ∅ }` and sends BeginRecovery(v); `can_propose` false until T2 (DR-6) |
| T2 | S `can_propose`: a Recovered of the base view is committed (or the view is v_0); L47 and L53 append while paused |

## §2 phase 1

| Line | Model |
|---|---|
| L1-L2 | S `NewView` (`Coord { .. view: v, k: 0 }`) |
| L3 | S `NewView`: `broadcast(BeginRecovery { view: v })`; retry: DR-12 |
| L4 | R `RecvBeginRecovery`: `v >= nv && v > lnv` |
| L5 | R `RecvBeginRecovery`: `if v > nv { join(s, v) }` |
| L6 | R `RecvBeginRecovery`: `BeginRecoveryOK { view: v, lnv }` |
| L7-L8 | R `RecvBeginRecovery`, else: `Nack { new_view: nv, lnv, k: None }` |

## §2 phase 2

| Line | Model |
|---|---|
| L9 | R `CoordBeginOK`: `m` a majority with BeginRecoveryOK(C.view, lnvs[r]) each; `vn` the largest; `learn(s, vn)` (DR-11) |
| L10 | R `CoordBeginOK`: `broadcast(Prepare { view, vn, k })`, phase P2a |
| L11 | R `RecvPrepare`: `stale(s1, v, vn)` with `s1 = learn(s, vn)` |
| L12 | R `RecvPrepare`: `Nack { s1.nv, s1.lnv, None }` |
| L13-L14 | R `RecvPrepare`: `s2 = join_if_newer(s1, v)` |
| L15 | R `RecvPrepare`: `k > msb_of(s2, vn)` |
| L16 | R `RecvPrepare`: `msb: s2.msb.insert(vn, k)` |
| L17-L18 | R `RecvPrepare`: body `Accepted { acc: s2.accepted[vn] }` if `accepted.contains_key(vn)` |
| L19-L20 | R `RecvPrepare`: body `Pool { pool: pool_of(s2, vn) }` |
| L21-L22 | R `RecvPrepare`, else: `Nack { s2.nv, s2.lnv, Some(msb_of(s2, vn)) }` (DR-15) |
| L23-L24 | R `rset_rule_ok`, `RsetRule::Adopt { r }`: r's triple is the largest (view, ballot); `rset = acc.val` |
| L25-L29 | R `rset_rule_ok`, `RsetRule::Count`: every body a pool; `is_recover_set` (count >= t, DR-13) |
| L30 | R `CoordPrepareOK`: `broadcast(Accept { view, vn, k, rset })`, phase P2b |
| L31-L32 | R `RecvAccept`: `stale(s1, v, vn)`, `Nack { .., None }` |
| L33-L34 | R `RecvAccept`: `join_if_newer(s1, v)` |
| L35 | R `RecvAccept`: `k >= msb_of(s2, vn)` |
| L36 | R `RecvAccept`: `msb.insert(vn, k)` |
| L37 | R `RecvAccept`: `accepted.insert(vn, Acc { view: v, k, val: S })`; ghost `votes_cast` (S) |
| L38 | R `RecvAccept`: `AcceptOK { view, vn, k }` |
| L39-L40 | R `RecvAccept`, else: `Nack { .., Some(msb_of(s2, vn)) }` |
| L41-L42 | R `CoordNack`, first branch: phase Stopped (phases P1, P2a, P2b only: DR-10) |
| L43-L44 | R `CoordNack`, second branch: `vn: lnv'`, `broadcast(Prepare { view, lnv', k })` |
| L45-L46 | R `CoordNack`, third branch: `k: k' + 1`, `broadcast(Prepare { view, vn, k' + 1 })`; backoff not modeled |

## §2 phase 3

| Line | Model |
|---|---|
| L47 | R `CoordAcceptOK` (phase P3) + S `accept_ok_appends`: `Recovered { view: C.view, vn: C.v_n, cmds: C.rset }` joins the log; `step_base_guard` (DR-7) |
| L48 | R `CoordFinish`: guard `exists j < committed: olog[j] == recovered_entry(coord)`; `broadcast(FinishRecovery { view, vn, rset })` (DR-8), phase Done |
| L49 | not modeled (DR-12) |
| L50 | not modeled beyond `entry_cmds(Recovered) = S` (DR-5) |
| L51 | R `RecvFinishRecovery`: `learn(s, v)` |
| L52-L53 | S `finish_appends` (DR-9) |
| L54 | R `RecvFinishRecovery`: `FinishRecoveryOK { view }` |

## §3 (M1-M6)

Not modeled: the merged 2-RPC variant is an engineering form of §2 (the pseudocode §3).
