# jetpack

A Verus model and inductive safety proof of the Jetpack consensus shim as written in
`docs/pseudocode.md` (three-phase recovery, §0-§2), in the hand-written
`spec fn` style of tla-rs (no `state_machine!`), laid out as the other crates of this
repository (`model/` trusted definitions, `proof/` untrusted lemmas, `top.rs` theorems).

Verify (0 errors expected; `results/checks/2026-10-31-verify.txt` has the log):

    PATH="$HOME/.cargo/bin:$PATH" ~/verus/verus --crate-type=lib verus/jetpack/lib.rs

Documents: `PROGRESS.md` (status, what is proved, next steps), `DECISIONS.md` (DR-1 to DR-18,
every reading of the pseudocode the model fixes), `FIDELITY.md` (every pseudocode line to the spec fn or branch).

## Files

| File | Lines | Content |
|---|---|---|
| `lib.rs` | 24 | crate root; pulls in `../common/mod.rs` |
| `top.rs` | 154 | theorems 1-7 (trusted statements) |
| `model/mod.rs` | 10 | module list (trusted) |
| `model/types.rs` | 191 | config, views, quorum sizes, ballots, entries, messages, packets, votes |
| `model/replica.rs` | 544 | replica + co-located coordinator: `join`, `learn`, N12-N24, L4-L48 handlers, `ReplicaNext` |
| `model/client.rs` | 93 | client: N1/N10, N2-N5, N8-N9 |
| `model/system.rs` | 246 | system state, the original-protocol oracle (T1-T2, N11/N19-N20, A1-A3), `Init`, `Next`, behaviors |
| `model/properties.rs` | 151 | `WellFormed`, the properties of theorems 1-5 |
| `proof/mod.rs` | 17 | module list |
| `proof/defs.rs` | 385 | the inductive invariant (`inv`), `mono`, Paxos vocabulary (`promise`, `safe_at`, `chosen`, `value_ok`) |
| `proof/bal.rs` | 59 | lexicographic ballot order |
| `proof/quorum.rs` | 66 | majorities intersect; superquorum meets majority in >= t |
| `proof/replica_lemmas.rs` | 186 | `learn`, `join`, L16/L36-L37 updates; `replica_mono` preorder |
| `proof/mono.rs` | 416 | stability under `mono`; log lemmas; the assembly lemma |
| `proof/keep.rs` | 236 | per-replica predicates kept under weak hypotheses |
| `proof/frame.rs` | 146 | node-step frames, packet-set membership |
| `proof/init.rs` | 35 | `Init` establishes `inv` |
| `proof/step_fast.rs` | 222 | N12-N18, N21-N23, N24 preserve `inv` |
| `proof/step_rec.rs` | 490 | L4-L8, L11-L22, L31-L40, L51-L54 preserve `inv` |
| `proof/step_coord.rs` | 558 | L9-L10, L23-L30 (the Paxos argument), L47, L48, L41-L46 preserve `inv` |
| `proof/step_client.rs` | 112 | client steps preserve `inv` |
| `proof/step_base.rs` | 223 | oracle steps preserve `inv` |
| `proof/inductive.rs` | 200 | dispatch over `Next`, behavior induction, step invariants |
| `proof/props.rs` | 340 | theorems 1-4 from `inv` (Paxos agreement, durability, Principle 2) |
| `proof/exclusions.rs` | 230 | theorem 5: the two audit schedules are unreachable |
| `witness/mod.rs` | 8 | module list (not trusted) |
| `witness/steps.rs` | 297 | `cfg3()`, `init_state`, the state after each kind of step and its `Next` lemma, `lemma_behavior_push` |
| `witness/w_fast.rs` | 280 | W1: 7 fast-committed in v_0 (6 states) |
| `witness/w_recovery.rs` | 927 | W2: W1 continued by NewView(1) and a full recovery committing Recovered(v_0, {7}) (26 states) |
| `results/checks/2026-10-31-verify.txt` | | verification log |

## Theorems (top.rs)

1. `theorem_replica_invariants`, `theorem_replica_step_invariants`: the pseudocode §0's replica invariants.
2. `theorem_recovered_agreement`: one recovery set per fast-path view.
3. `theorem_fast_commit_durability`: a fast-committed command is recovered or committed.
4. `theorem_principle2`: the first entry of a view is its Recovered entry.
5. `theorem_audit_schedules_excluded`: JETPACK-001 and JETPACK-002 cannot happen.
6. `theorem_witness_fast_commit` (W1): a valid behavior in which 7 is fast-committed in v_0.
7. `theorem_witness_recovery` (W2): W1 continued by a full recovery; at the end a Recovered
   entry holding 7 is committed and replica 0 is Normal in view 1.

Current result: `verification results:: 147 verified, 0 errors` (also with `--no-cheating`).
