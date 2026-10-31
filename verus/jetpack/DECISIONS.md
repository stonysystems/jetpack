# Decision record: jetpack

Every reading of docs/pseudocode.md that the model fixes, with the pseudocode line it comes from.
`PROGRESS.md` has the status; `FIDELITY.md` the line map.

- **DR-1 Views are ids with a constant proposer function.** the pseudocode §0 l.12-14: "the id determines
  the record uniquely". Membership is constant (A6 and reconfiguration, the pseudocode §0 l.117-121, are
  not modeled), so the record of id v is `View { id: v, proposers: {proposer(v)} }`
  (`model/types.rs::view`); states and messages carry ids. Single-proposer case: one
  coordinator per view (the pseudocode §0 l.75-77 allows several).
- **DR-2 One pool set per replica.** the pseudocode §0 l.47 keeps `pool[w]` per view; L20 (after learn(v_n),
  l.59-68) reads only `pool[last_normal_view]`, and L11 Nacks when last_normal_view > v_n. So
  the pool of the current last normal view suffices; when last_normal_view advances the pool
  is empty (R never ack'd in the new view, l.68). `pool_of(s, w)` is R.pool if w is R's last
  normal view, else empty.
- **DR-3 Results dropped.** N15's r, N4, N6-N7, N22 are not modeled: FastAck carries (view, cmd),
  the client's fast commit is N2-N3 + N5. They do not affect which commands are recovered.
- **DR-4 N11 and N19-N20 are the oracle's `AppendCmd`.** The proposer of the current view
  appends any command once T2 lets it (`can_propose`). The trigger (a FastCmd at a Normal
  proposer, N19) is not tracked: liveness only.
- **DR-5 The original protocol is one master log with prefix copies.** A1-A3 (the pseudocode §0
  l.108-112): `log` is the one original log, every `olog` a prefix of it, every replica's
  `committed` at most the global one. Uncommitted tails never diverge in this oracle, which is
  stronger than A1-A2; the proofs use only that committed prefixes agree and never shrink.
- **DR-6 T1/T2 as `can_propose`.** T1-T2 (l.207-213): a Cmd of view v is appended only when a
  Recovered of view v is committed, or v = v_0 (which needs no recovery, l.87-88). Recovered
  entries may be appended while paused (L47, L53). `NewView(v)` needs v > every view so far
  (l.13 "monotonic identifier").
- **DR-7 L47 appends atomically and only in C.view.** On maj AcceptOKs C moves to P3 and
  `Recovered { view: C.view, vn: C.v_n, cmds: C.rset }` joins the log if C.view is the current
  base view and C is its proposer (`step_base_guard`); otherwise the step is disabled (a
  deposed proposer's append never commits).
- **DR-8 FinishRecovery carries vn.** the pseudocode L48 sends FinishRecovery(C.view, C.rset); the model
  adds C.v_n so that the L53 entry records the view it recovers. No guard reads it.
- **DR-9 L52-L53.** After learn(v) (L51), if R.new_view = v, R = proposer(v), no Recovered of
  view v is in the log (L52 "has not yet submitted a Recovered(·) in v"), and v is the current
  base view, the entry is appended (`finish_appends`). With one proposer per view the branch
  never fires (C appended at L47 before L48); it is modeled.
- **DR-10 Nack handling (L41-L46) in P1, P2a, P2b only.** Nacks answer BeginRecovery (L8),
  Prepare (L12, L22) and Accept (L32, L40), outstanding only in those phases; the pseudocode's handler
  has no phase guard. In P1 a stale Nack can take L43-L46 (a Prepare without L9): harmless
  for safety.
- **DR-11 learn on each BeginRecoveryOK = learn(max).** L9's note: learn ran on each reply;
  learn (l.59-66) is monotone, so `CoordBeginOK` applies learn(vn) with vn the largest.
- **DR-12 L3 retry and L49 retransmission** resend packets already in the network set: no step.
- **DR-13 L26-L29 as a relation.** The step parameter `rset` must be exactly the commands in
  at least t replies (`is_recover_set`); vstd sets are finite and such a set exists (a subset
  of the union of the finitely many pools).
- **DR-14 Entries record views.** Cmd records the view it was appended in, Recovered records
  (view, vn), so Principle 2 and RecoveredAgreement can be stated on logs.
- **DR-15 Nack's k'.** L22/L40 send `Some(max_seen_ballot[v_n])`; L8/L12/L32 send `None` (⊥).
- **DR-16 Pending(R.olog) = entries from R's committed length on** (the pseudocode §0 l.70, A3): the
  executed prefix is the committed prefix.
- **DR-17 Steps that receive several packets** (L9, L23, L47, N2) take the packet set and the
  replica set as parameters; the system checks each packet is in the network and addressed to
  the receiver.
- **DR-18 Audit-schedule properties added to `model/properties.rs`** (after the model verified):
  `PrepareOkFreezes`, `AcksOnlyWhenNormal`, `StaleFinishRecoveryKeepsRecovery` state that the
  two schedules of the tla-rs recovery audit (JETPACK-001: a replica that never froze answers
  Prepare then acks; JETPACK-002: a stale FinishRecovery unfreezes a replica that joined a
  newer view) are unreachable, from the pseudocode L14 (join before L16-L20) and learn's second branch
  (§0 l.66). Definitions only; no handler changed.
