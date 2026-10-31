# jetpack: progress

Source of truth: `docs/pseudocode.md` (§0, §1 N1-N25, §2 T1-T2, L1-L54; the
three-phase version). §3 (merged 2-RPC variant M1-M6) is not modeled. Line map: `FIDELITY.md`;
every judgement call: `DECISIONS.md` (DR-1 to DR-17); files: `README.md`.

Verify: `PATH="$HOME/.cargo/bin:$PATH" ~/verus/verus --crate-type=lib verus/jetpack/lib.rs`
(Verus 0.2026.08.02.b677dd5; this vstd has finite `Set` only, `Set::new` returns `Option`,
`Map::new` takes a `Set` domain). Logs: `results/checks/2026-10-31-verify.txt`.

## Status (2026-10-31)

`verification results:: 147 verified, 0 errors` (also with `--no-cheating`). No `assume`,
`admit`, `external_body`, no `exec` code. `tools/check_english.py verus/jetpack`: ok.

### Proved (top.rs)

1. `theorem_replica_invariants`: the pseudocode §0 "R.last_normal_view <= R.new_view" and "R.mode =
   Recovery <==> R.new_view > R.last_normal_view", every state.
   `theorem_replica_step_invariants`: neither view decreases; the pool changes only while
   Normal or when last_normal_view advances (so once new_view > last_normal_view = w, pool[w]
   is frozen), every step.
2. `theorem_recovered_agreement`: two Recovered entries, in any replicas' logs, with the same
   v_n carry the same set. Proof: Paxos per v_n with ballots (view, k) lexicographic, Prepare
   strict >, Accept >=, promise = (R.new_view, R.max_seen_ballot[v_n]); `safe_at` /
   `none_other_choosable_at` / `cannot_vote_at` over the ghost vote history, one Accept per
   (view, v_n, k) from the coordinator's (v_n, k) monotonicity, `chosen` from L47's AcceptOK
   quorum; every Recovered entry's set is `chosen` (L47 directly, L53 through FinishRecovery).
3. `theorem_fast_commit_durability` (paper C1 Case 3 + GC rule): if a superquorum of replicas
   containing the proposer of w each sent FastAck(w, c), then every Recovered entry for v_n = w
   contains c or c is in the committed prefix of some replica's log; also for the fast commits
   the clients decided (`ClientFastCommitDurability`). Proof: every FastAck(w, c) from R is
   backed by R's pool while R.last_normal_view = w, or c is committed (N21/N24 remove only
   committed commands); every PrepareOK pool is a snapshot that keeps every ack'd uncommitted
   command and R never acks in w afterwards (new_view >= v > w); every Accept's set is
   `value_ok`: contains every command in >= t snapshots of some majority (L26-L29 directly,
   L24 by induction through the adopted vote); a superquorum and a majority meet in >= t
   replicas (`lemma_sq_maj_meet`).
4. `theorem_principle2`: in every replica's log the first entry of every view other than v_0 is
   a Recovered entry (T2 as `can_propose`).
5. `theorem_audit_schedules_excluded`: `PrepareOkFreezes` (a replica that answered Prepare for
   w has new_view > w and is not Normal in w), `AcksOnlyWhenNormal` (a FastAck is sent only
   while Normal in its view), `StaleFinishRecoveryKeepsRecovery` (a stale FinishRecovery does
   not unfreeze a replica that joined a newer view): the two schedules of the tla-rs recovery
   audit (JETPACK-001, JETPACK-002) are unreachable.

6. Reachability witnesses (`witness/`, not trusted; the theorems are not vacuous), over the same
   model and `IsValidBehavior`, configuration `cfg3()`: replicas {0, 1, 2}, client 0, replica 0
   the proposer of every view, no conflicts (n = 3, maj = 2, t = 2, sq = 3).
   `theorem_witness_fast_commit` (W1, 6 states): client 0 sends FastCmd(0, 7), replicas 0, 1,
   2 ack, client 0 decides: `fast_committed(cfg, b.last(), v_0, 7)` and the client's `fast`
   holds it. `theorem_witness_recovery` (W2, 26 states, continuing W1: `b[5]` is W1's last
   state): NewView(1), BeginRecovery/OK by 0, 1, 2, Prepare/OK (pools {7}), Accept/OK, L47
   appends Recovered(view 1, v_n 0, {7}), replica 0 replicates, the entry commits, L48
   FinishRecovery, replicas 0, 1, 2 return to Normal in view 1; at the end replica 0 is Normal
   with new_view = last_normal_view = 1, its committed prefix holds the Recovered entry with 7,
   and `committed_cmd(cfg, b.last(), 7)`: the FastCommitDurability conclusion holds by both
   disjuncts. Every step is proved to be a `Next` step with the model's own definitions
   (`witness/steps.rs` gives the state after each kind of step).

### Not proved / not stated

- C1 for cascading failures as a separate statement (the v_n chain): not stated. Theorems 2
  and 3 already hold for every Recovered entry whatever view produced it, and several views
  recovering the same v_n share one Paxos instance, so no separate chain argument was needed.
- Liveness, results (N4, N15), A4/A5/A7-dependent properties: out of scope (DR-3).
- No `// TODO (unproven)` statements remain in the crate.

## Proof-side readings (no model change)

- `coord_ok` allows C.v_n = ⊥ in phases P2a and Stopped: in P1 a stale Nack can take L45-L46
  and send Prepare(v, ⊥, k'+1) (DR-10); such a Prepare is always Nacked by L11 (every
  last_normal_view is >= v_0 > ⊥), so no PrepareOK with v_n = ⊥ exists and P2b always has a
  real v_n. `msg_ok` allows `vn >= ⊥` in Prepare.
- `one_decree` (one set per (view, v_n, k)) comes from the coordinator record: every Accept of
  C.view is at (v_n, k) componentwise at most C's, and strictly below while C is in P2a; L44
  raises v_n, L46 raises k, so a (v_n, k) is never revisited.

## Save points (results/checks/2026-10-31-verify.txt)

- model only: 5 verified; invariant + stability: 61; all step lemmas: 84; theorems 1-4: 109;
  with the audit exclusions: 115; with the witnesses W1, W2: 147 verified, 0 errors.

## Next steps (if continued)

- Generalize to several proposers per view (the pseudocode §0 l.75-77): `proposers(cfg, v)` a set, one
  coordinator per proposer, `one_decree` then needs PrepareOK uniqueness per replica and
  (view, k) instead of the single coordinator record; L52-L53 becomes live.
- State C1 for cascading failures explicitly as a corollary of theorems 2-3.
- Reconfiguration (A6): views with changing membership; quorum intersection across views.
