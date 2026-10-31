# Jetpack pseudocode

This is the complete pseudocode of the Jetpack protocol and the reference for the TLA+
specifications in `tla/` and the Verus specification in `verus/`. The OSDI '26 paper is the
abbreviated version: for space, its text and its appendix figure leave out a number of
conditions and cases. §5 lists each place the paper abbreviates and what this document
supplies there. Where this document and the paper differ in detail, this document is the one
the models and the implementation follow.

- Code blocks are the protocol. §1 is the normal path, §2 the recovery (the three-phase
  version, which the TLA+ and Verus models check), §3 the merged two-RPC variant (an
  engineering optimization, the shape of the implementation; not modeled).
- Line tags: normal path N1–N25, trigger T1–T2, recovery L1–L54, merged variant M1–M6. The
  models cite these tags.
- Two principles carry over from the paper. **Principle 1** (one view): a command is
  fast-committed only by a superquorum of acks given in one fast-path view, including every
  proposer of that view. **Principle 2** (recovered set first): the proposers of a new view
  recover and commit the fast-committed commands of the last normal view before committing
  anything else in the new view.

## §0 Notation and state

```text
A view is a record provided by the original protocol:
  v.id              monotonic identifier; views are compared by id only (v < v' means v.id < v'.id);
                    the id determines the record uniquely
  v.replicas        replica set (membership)          replicas(v) = v.replicas, n(v) = |v.replicas|
  v.proposers       original-path proposers           proposers(v) = v.proposers
  ⊥                 the null view, smaller than every view
  messages carry whole view records
  per protocol:  Raft / MongoDB   id = (term, index of the latest config entry), lexicographic:
                                  a leader change or a membership change starts a new view
                 Copilot          id = (ballot of pilot 0, ballot of pilot 1), lexicographic:
                                  replacing either pilot starts a new view; the unchanged pilot
                                  learns it from the other pilot's election
                 Mencius          no election, every server is a proposer: one static view, never
                                  changes; if any server is down the fast path simply stops until it
                                  is back (sq(v) = n), the original path is unaffected

Quorum sizes, per view, for any n (for n = 2f+1 they are f+1, ⌈f/2⌉+1, f+⌈f/2⌉+1 as in the paper):
  maj(v) = ⌊n(v)/2⌋ + 1               majority
  t(v)   = ⌊maj(v)/2⌋ + 1             recovery threshold
  sq(v)  = n(v) − maj(v) + t(v)       superquorum; a fast commit also needs every proposer of v
  why:  every majority meets every superquorum in ≥ t(v) replicas (a fast-committed cmd is found);
        t(v) > maj(v)/2, so a cmd conflicting with it gets ≤ maj(v) − t(v) < t(v) votes
  e.g.  n = 4: 3, 2, 3    n = 5: 3, 2, 4    n = 6: 4, 3, 5

v                   a view; in recovery, the new view                          replica stores it as R.new_view
v_n                 last normal view = the fast-path view being recovered    replica stores it as R.last_normal_view
w                   (only in this section) a fast-path view used as an index
k                   a ballot: a counter within one view, raised by a coordinator on retry
                    a view may have several coordinators; compare views first, then ballots:
                    a message from an older view is rejected without comparing ballots

Jetpack replica R (both views are whole records):
  R.last_normal_view  // = v_n: current fast-path view; advances only when a view's Recovered(·) is committed
  R.new_view          // = v: latest view whose recovery R joined
  R.mode ∈ {Normal, Recovery}
  R.pool[w]         // command pool of fast-path view w: cmds R ack'd while R.last_normal_view = w
                    //   (the paper's "fast-path log" / log_v_n); pairwise non-conflicting, so a set
  R.max_seen_ballot[w]  // Paxos promise for recovering w: highest ballot promised or accepted, within R.new_view
  R.accepted[w]     // last Accept R took for recovering w: (accepted_view, accepted_ballot, accepted_value)
                    //   accepted_value is a recovery set (the paper's rset_v_n); ⊥ if none
  R.olog            // the original protocol's own log; Jetpack only reads it

join(v)             // R joins the recovery round of view v (v > R.new_view):
                    //   R.new_view ← v; R.mode ← Recovery;
                    //   R.max_seen_ballot[w] ← ⊥ for every w   (ballots of older views are void;
                    //   R.accepted[·] is kept)

learn(u)            // R learns that view u is (or was) normal somewhere. Runs BEFORE the handler of
                    // every message carrying a last normal view: BeginRecoveryOK's last_normal_view,
                    // Nack's last_normal_view', Prepare/Accept's v_n, FinishRecovery's v
                    // (clients do the same on FastNack, N8–N9):
                    //   if u > R.last_normal_view then
                    //       if u ≥ R.new_view then                  // same as receiving FinishRecovery(u)
                    //           R.last_normal_view ← u;  R.new_view ← u;  R.mode ← Normal
                    //       else R.last_normal_view ← u             // R is already in a newer recovery round
                    // safe: last_normal_view = u on any replica means u's Recovered(·) is committed,
                    // so every fast-path view < u is fully recovered; R never acked in u, so pool[u] = ∅ is right

Pending(R.olog)     // entries of R.olog that R has not executed yet (⊇ uncommitted)
SpecExec_R(c)       // c's return value computed on R's executed state, without applying c;
                    //   the executed state includes the dedup table (cmd id → first result) of N25,
                    //   so a resent c that R already executed gets its first result

Coordinator C (a Jetpack replica co-located with a proposer of the new view, T1; every proposer of
               the new view starts one, so a view may have several coordinators;
               C is also in replicas(·) and handles its own messages by the same replica rules):
  C.view            // the new view v
  C.v_n             // last normal view, learned from the replicas' last_normal_view (L9)
  C.k               // C's current ballot within C.view
  C.rset            // recovery set C proposes for C.v_n

Client K:
  K.view            // the fast-path view K believes is current; only moves forward (N8–N9)
  every command c carries a unique id; a resend reuses it

Initially, on every Jetpack replica R in replicas(v_0):
  R.last_normal_view = R.new_view = v_0 (the initial view), R.mode = Normal, all slots empty / ⊥
A replica added later by a reconfiguration starts with:
  R.last_normal_view = R.new_view = ⊥, R.mode = Normal, all slots empty / ⊥
  // it acks nothing (no FastCmd carries ⊥); it joins on BeginRecovery(v) and reports ⊥ (L6),
  // and enters Normal in v on FinishRecovery(v, ·)

Persistence: R's whole Jetpack state (last_normal_view, new_view, mode, pool, max_seen_ballot,
  accepted, the dedup table) is on stable storage whenever the original protocol's own state is.
  Every state change is written before the message that depends on it is sent: pool insert
  before FastAck (N16), promise before PrepareOK (L16), accept before AcceptOK (L37),
  join/learn before any reply. A restarted replica reloads this state and continues as a slow
  replica; there is no amnesia mode. (If the original protocol keeps its log in memory only,
  so does Jetpack: same guarantee as the original, a constant factor more writes, no added
  latency relative to a WAN round trip.)

Invariants on every Jetpack replica R:
  R.last_normal_view ≤ R.new_view, and neither ever decreases
  R.mode = Recovery  ⟺  R.new_view > R.last_normal_view
  once R.new_view > w, R.pool[w] never changes again   (no acks in Recovery, GC frozen)

Assumptions on the original protocol:
  A1  durability: a command committed on the original path is never lost across view changes
  A2  consistent ordering: a committed command's log position never changes
  A3  in-order execution: commands are executed and replied to in log order; position j is not
      executed until every position i < j is committed
  A4  linearizability: if A is committed on the original path before B is proposed, B executes after A
  A5  at any time, every command already committed on the original path is in the log of at
      least one proposer of the current view   (Raft/MongoDB: leader completeness; Mencius: every
      server is a proposer; Copilot: the proposing pilot's log)
  A6  each view change adds or removes at most one replica
      => majorities of the two views intersect, so every majority of replicas(v) intersects every
         superquorum of replicas(v_n). Views between v_n and v append no entries (T1), so
         replicas(v) differs from replicas(v_n) by at most one replica. A one-step replace is not
         safe for the original protocol itself; joint consensus is out of scope.
  A7  a proposer's own entries execute in the order it proposed them (Raft: trivially; Mencius:
      one owner's slots increase; Copilot: one pilot's log is executed in order)   — used by T2
```

**Names used by the paper, the TLA+ and the implementation**

| this document | paper | TLA+ (`tla/jetpack.tla`) | implementation (`src/deptran/jetpack_rules.h`) |
|---|---|---|---|
| `R.last_normal_view` | `R.view` in the appendix figure; v_n, "last normal view" in the text | `rstate[i].lnv` | `view.id` (installed view) |
| `R.new_view` | the v of `Prepare(v_n → v)` in the text; no variable | `rstate[i].nv` | `vid` (newest joined view) |
| `R.mode = Normal` | "normal mode" | `rstate[i].mode` | `READY` |
| `C.view` / `C.v_n` / `C.k` | `C.view`, `C.v_n` in the figure; no ballot | `cstate[i].view / vn / k` | `v` / `vn` / ballot counter |
| `K.view` | §3.3 "clients track the current view" | `client_view` | — |
| `R.pool[w]` | `R.log_v_n` in the figure; "fast-path log", "command pool" in the text | `rstate[i].pool` (the pool of lnv) | `acked` |
| `R.accepted[w]` | its `accepted_value` is the figure's `R.rset_v_n` | `rstate[i].acc` | `accepted[vn]` |
| `R.max_seen_ballot[w]` | — | `rstate[i].msb` | `promised` (one per replica, see §3) |
| `R.olog` | the original protocol's log | the base module's `log` | — |

The figure's `R.view` is `R.last_normal_view`, not `R.new_view`.

## §1 Normal path

```text
Client K, issuing fast-path command c:
N1   send FastCmd(K.view, c) to replicas(K.view)
N2   if K receives FastAck(K.view, c, ·) from a set Q ⊆ replicas(K.view)
N3         with |Q| ≥ sq(K.view) and proposers(K.view) ⊆ Q    // one fast-path view (Principle 1)
N4         and every proposer in Q returned the same result r
N5       c is fast-committed; return r to app
N6   else                                     // includes: the proposers' results differ
N7       wait for c to commit on the original path; return its result

Client K, on receiving FastNack(v', ·) for c:
N8   if v' > K.view then
N9       K.view ← v'          // ends this attempt: acks from the old view are never counted with new ones

Client K, on timeout while waiting in N7:
N10  resend FastCmd(K.view, c) with the same id (go to N1)    // safe: dedup by id (N25)

Client K, issuing original-path command c:
N11  submit c to the original protocol as usual (e.g. to the Raft leader)
     // a proposer paused by T1 queues c and proposes it after its Recovered(S) (T2);
     // K's timeout resend (same id) is also safe

Jetpack replica R, on receiving FastCmd(v, c):
N12  if v = R.last_normal_view and R.mode = Normal
N13        and c conflicts with no cmd in R.pool[v] ∪ Pending(R.olog) then
N14      R.pool[v].insert(c)
N15      r ← SpecExec_R(c) if R's original replica is a proposer, else ⊥
N16      send FastAck(v, c, r) to K               // the promise; N14 is on stable storage first
N17  else if v ≠ R.last_normal_view or R.mode = Recovery then
N18      send FastNack(R.last_normal_view, R.mode) to K   // a conflict alone gets no reply
N19  if R.mode = Normal and R's original replica is a proposer then   // regardless of conflicts or v
N20      Propose(c)          // the original protocol appends c to R.olog by its own mechanism

Jetpack replica R, on observing the original path's reply for c (committed and executed):
N21  if R.mode = Normal then remove c from R.pool[R.last_normal_view]   // GC frozen during recovery
N22  forward the result to the client
N23  notify the other Jetpack replicas to evict c from their pools

Jetpack replica R, on an evict notice for c:
N24  if R.mode = Normal then remove c from R.pool[R.last_normal_view]   // GC frozen during recovery

Original replica, executing its log:
N25  skip c if c was already executed       // duplicates in Copilot / Mencius, resends (N10), Recovered(S)
                                            // a skipped copy returns c's first result (dedup table)
```

Notes.

- Conflict: two commands on the same key conflict if either is a write. Two reads do not
  conflict and can both be fast-committed.
- `Pending(R.olog)` in N13 is "entries R has not executed yet", not "uncommitted". Example
  (Raft): W = put(x,1) is committed at index 10 but R1 has applied only up to 9 when
  c = get(x) arrives. With "uncommitted", R1 would ack c and return 0, yet c ends up after W
  and the original path executes it to 1. The paper's §5 says that all commands go into the
  pool; that is how a shim that cannot read the original log implements `Pending(R.olog)`,
  not a third structure.
- N15: only proposers compute a result; a non-proposer's ack carries ⊥. A write returns ok.
  N4 requires all proposers' results to agree; otherwise the fast path fails. Correctness
  rests on A5: a committed command is in some proposer's log, so it has either been executed
  there (the result includes it) or is pending there (that proposer does not ack).
- N21/N24 remove only from the current view's pool; an older view's pool is never read
  again. Freezing GC during recovery is not needed for safety (a GC'd command is committed,
  A1); it makes the pool a PrepareOK sends the snapshot taken when the replica joined.
- The dedup table of N25 is part of the executed state and `SpecExec_R` reads it: a read
  resent with the same id returns its first result, not the current value.

## §2 Recovery (three-phase version)

### Trigger

```text
Original replica P, a proposer of a new view v, on learning v (elected leader; learned the new
proposer set, e.g. Copilot's unchanged pilot; or appended the config entry that starts v),
before appending any other entry of v:
T1   pause proposing (queue incoming commands, N11); P's Jetpack replica becomes a coordinator
     C for v (go to L1)     // every proposer of v does this; several coordinators are safe
T2   resume proposing only after P's own Recovered(S) is committed, where S is v's recovery set:
     decided by P's own run (L47), or copied from FinishRecovery(v, S) (L52–L53).
     Recovered(S) is P's first entry of v after v's own config entry, if any (in Raft it doubles
     as the new term's empty entry and commits the old tail); P's queued commands follow it in
     arrival order. By A7 every later entry of P executes after S (Principle 2).
     // while paused, P still sends heartbeats without entries, so no new election starts
```

### Phase 1: detect the view change, freeze the fast path

```text
Coordinator C, on T1 with new view v:
L1   C.view ← v
L2   C.k ← 0
L3   send BeginRecovery(v) to replicas(v); retry until maj(v) reply

Any Jetpack replica R, on receiving BeginRecovery(v) from coordinator C:
L4   if v ≥ R.new_view and v > R.last_normal_view then      // gate
L5       if v > R.new_view then join(v)            // pause processing commands
L6       send BeginRecoveryOK(v, R.last_normal_view) to C
L7   else
L8       send Nack(R.new_view, R.last_normal_view, ⊥) to C
```

### Phase 2: decide the recovery set (one Paxos round for v_n)

```text
Coordinator C, on receiving BeginRecoveryOK(C.view, ·) from maj(C.view) replicas of replicas(C.view):
     // learn(last_normal_view) ran on each reply
L9   C.v_n ← the largest last_normal_view in those replies
L10  send Prepare(C.view, C.v_n, C.k) to replicas(C.v_n)

Any Jetpack replica R, on receiving Prepare(v, v_n, k) from coordinator C:   // learn(v_n) ran first
L11  if v < R.new_view or R.last_normal_view > v_n then     // step 1, align views: stale view, or v_n already recovered
L12      send Nack(R.new_view, R.last_normal_view, ⊥) to C  //   no ballot comparison
L13  else
L14      if v > R.new_view then join(v)            //   newer view: join it
L15      if k > R.max_seen_ballot[v_n] then        // step 2, same view: compare ballots (strict)
L16          R.max_seen_ballot[v_n] ← k            // on stable storage before replying
L17          if R.accepted[v_n] ≠ ⊥ then
L18              send PrepareOK(v, v_n, k, R.accepted[v_n]) to C
L19          else
L20              send PrepareOK(v, v_n, k, R.pool[v_n]) to C
L21      else
L22          send Nack(R.new_view, R.last_normal_view, R.max_seen_ballot[v_n]) to C

Coordinator C, on receiving PrepareOK(C.view, C.v_n, C.k, ·) from maj(C.v_n) replicas of replicas(C.v_n):
L23  if any reply carries an accepted (accepted_view, accepted_ballot, accepted_value) then
L24      C.rset ← the accepted_value with the largest (accepted_view, accepted_ballot)   // view first, then ballot
L25  else
L26      cmds ← union of the pools in the replies
L27      for c ∈ cmds do
L28          if c appears in ≥ t(C.v_n) of the replies then      // per command, not per key
L29              C.rset.insert(c)
L30  send Accept(C.view, C.v_n, C.k, C.rset) to replicas(C.v_n)

Any Jetpack replica R, on receiving Accept(v, v_n, k, S) from coordinator C:   // learn(v_n) ran first
L31  if v < R.new_view or R.last_normal_view > v_n then     // step 1: same as L11
L32      send Nack(R.new_view, R.last_normal_view, ⊥) to C
L33  else
L34      if v > R.new_view then join(v)
L35      if k ≥ R.max_seen_ballot[v_n] then        // step 2: same view, compare ballots
L36          R.max_seen_ballot[v_n] ← k
L37          R.accepted[v_n] ← (v, k, S)            // on stable storage before replying
L38          send AcceptOK(v, v_n, k) to C
L39      else
L40          send Nack(R.new_view, R.last_normal_view, R.max_seen_ballot[v_n]) to C

Coordinator C, on receiving Nack(new_view', last_normal_view', k'):   // learn(last_normal_view') ran first
L41  if new_view' > C.view or last_normal_view' ≥ C.view then
L42      stop coordinating            // a newer view exists: its proposers take over (T1);
                                      // or C.view is already normal: S arrives by FinishRecovery(C.view, S) (L52)
L43  else if last_normal_view' > C.v_n then
L44      C.v_n ← last_normal_view'; go to L10  // C.v_n was already recovered: recover the newer view
L45  else if k' ≠ ⊥ and k' ≥ C.k then
L46      C.k ← k' + 1; after a random backoff, go to L10   // same view, another coordinator
```

Notes.

- The two-step comparison is the lexicographic order on `(view, k)`. Prepare uses strict `>`,
  so at most one coordinator per `(view, k)` reaches Accept and no coordinator id is needed.
  `accepted` survives `join`; L24 compares the view first, then the ballot.
- L9 gives `C.v_n < C.view`, and L41 gives `last_normal_view' < C.view` at L43–L44, so
  `v_n < v` always holds in Prepare and Accept.
- A replica with `R.last_normal_view < v_n` (it missed FinishRecovery(v_n)) answers normally;
  its `pool[v_n]` is empty. A replica with `R.last_normal_view > v_n` Nacks, which moves the
  coordinator to the newer view: a replica past v_n means v_n's Recovered(·) is committed.
- The three values in a Nack never decrease within a view, so a late Nack cannot mislead.
- Two conflicting commands may both reach t(v_n); then neither was fast-committed and
  recovering either is safe.
- Cascading failures: by Principle 2 a new view does not become normal before v_n is
  recovered, so the coordinators of successive failed views all target the same v_n and
  converge on one set through the accepted values.
- Several coordinators of one view are safe. If a command fast-committed in w is still
  unrecovered, every majority reports w as the largest last normal view, so all coordinators
  learn the same v_n and Paxos gives one S. If they learn different v_n's, no such command
  exists and both recovery sets are harmless. Extra Recovered entries are deduplicated by
  command id (L50).

### Phase 3: resubmit and resume

```text
Coordinator C, on receiving AcceptOK(C.view, C.v_n, C.k) from maj(C.v_n) replicas of replicas(C.v_n):
L47  submit Recovered(C.rset) to C's own proposer (T2)   // one entry; Recovered(∅) is the no-op

When C's Recovered(C.rset) is committed on the original path:
L48  send FinishRecovery(C.view, C.rset) to replicas(C.view)
     // C's proposer resumes proposing (T2) right away: nothing below blocks it
L49  retransmit it periodically to every replica that has not replied FinishRecoveryOK(C.view),
     until all have, or until C learns a view > C.view     // asynchronous; liveness only

Original replica, executing Recovered(S):
L50  for each c ∈ S, in a fixed order: execute c unless already executed   // dedup by cmd id (N25)

Any Jetpack replica R, on receiving FinishRecovery(v, S) from coordinator C:
L51  learn(v)                        // if v ≥ R.new_view: R.last_normal_view ← v, R.new_view ← v,
                                     //   R.mode ← Normal (resume processing commands)
L52  if R.new_view = v and R's original replica is a proposer of v
           that has not yet submitted a Recovered(·) in v (neither by L47 nor by an earlier L53) then
L53      submit Recovered(S) to it   // its own copy; it resumes proposing when that commits (T2)
L54  send FinishRecoveryOK(v) to C   // also when R.last_normal_view ≥ v already: idempotent
```

Notes.

- Committing Recovered(S) is the stability marker (Principle 2). An empty S is still
  committed: otherwise v would have no committed entry, and in Raft a replica holding an
  uncommitted conflicting command of an older view could still win the next election and
  commit it ahead of v's fast-committed commands.
- With several proposers, Phase 2 is per view (any coordinator decides v's S) and Phase 3 is
  per proposer (each proposer's first entry in v is Recovered(S)). Reason: in Mencius, R1
  commits Recovered(S) in slot 40; if R2 resumed proposing now, its next command would land
  in slot 37 and execute before S. R2's own Paxos run cannot finish either (replicas that
  handled FinishRecovery have last_normal_view = 7 > v_n and Nack), so S travels in
  FinishRecovery.
- L51 lets the Jetpack replica ack again while its proposer still waits for its own
  Recovered to commit; this is safe because a fast commit needs every proposer's result to
  agree.
- L49 is asynchronous and blocks nothing; the only wait in the whole recovery is T2. A
  proposer that misses FinishRecovery never obtains S (its own run has been Nacked), so the
  retransmission is required with several proposers, not an optimization.
- Implementation: the original protocol does not need multi-command entries. The commands of
  S are submitted as ordinary requests, pipelined, and awaited together; an empty S submits a
  no-op. The equivalent condition is T2: a proposer proposes nothing else before its S is
  committed.
- `pool[w]`, `max_seen_ballot[w]`, `accepted[w]` of an old w are never read again; an
  implementation may reclaim them at any time. The protocol has no delete operation.

## §3 Engineering variant: the merged two-RPC recovery (paper Appendix B.2)

§2 is the reference and is what the TLA+ and Verus models check. The implementation
(`src/deptran/jetpack_rules.h`: `Pull` / `PullOk` / `ChooseRecoveryValue` / `Accept`) runs the
merged variant below. The one essential difference: when RPC1 is sent the coordinator does
not know v_n yet, so Prepare cannot name v_n, the replica's promise covers every
`w ≥ R.last_normal_view` at once, and the ballot is one per replica instead of one per w. Only
the changed lines are listed; everything else is as in §2.

```text
Coordinator C, on T1:
M1   C.view ← v;  C.k ← 0
M2   send Pull(v, C.k) to replicas(v)            // = BeginRecovery(v) + Prepare(v, ·, k), v_n not yet known

Any Jetpack replica R, on receiving Pull(v, k):
M3   if v < R.new_view or v ≤ R.last_normal_view then        // L4's gate
         send Nack(R.new_view, R.last_normal_view, ⊥) to C
M4   else
         if v > R.new_view then join(v)
         if k > R.max_seen_ballot then          // ONE ballot per replica, not per w
             R.max_seen_ballot ← k              //   = a promise for every w ≥ R.last_normal_view at once
             send PullOK(v, k, R.last_normal_view, R.pool[R.last_normal_view],
                         { w ↦ R.accepted[w] : w ≥ R.last_normal_view, R.accepted[w] ≠ ⊥ }) to C
         else send Nack(R.new_view, R.last_normal_view, R.max_seen_ballot) to C

Coordinator C, on PullOK(C.view, C.k, ·) from maj(C.view) replicas of replicas(C.view):
M5   C.v_n ← the largest last_normal_view in the replies            // L9
     if fewer than maj(C.v_n) replies come from replicas(C.v_n) then  // a replica removed between v_n and v (A6)
         send Prepare(C.view, C.v_n, C.k) to the missing ones (L10) and wait for them
     if some reply carries accepted[C.v_n] then                       // L23–L24
         C.rset ← the accepted_value with the largest (accepted_view, accepted_ballot)
     else                                                             // L26–L29
         count pool entries over the replies with last_normal_view = C.v_n (others count as empty),
         threshold t(C.v_n)
M6   send Accept(C.view, C.v_n, C.k, C.rset) to replicas(C.v_n)      // L30 onwards unchanged;
                                                                      // Accept uses k ≥ R.max_seen_ballot (single ballot)
```

Why it is equivalent (informal).

1. A wider promise does not break Paxos: it only Nacks more coordinators, never fewer. Every
   v_n instance sees a promise at least as strong as in §2; liveness is the backoff of L46.
2. The reply must carry every `accepted[w]` with `w ≥ last_normal_view`: a replica may hold
   `accepted[6]` while its last normal view is still 5 (it accepted during view 7's recovery
   of v_n = 6, and 7 did not complete). The coordinator needs that record when it decides
   v_n = 6. The implementation's `accepted` map is exactly this.
3. Quorums: BeginRecovery needs maj(v) of replicas(v), Prepare maj(v_n) of replicas(v_n). By
   A6 the two sets differ by at most one replica. After an addition, at most one of the maj(v)
   replies is from the new replica, so maj(v_n) is met; after a removal one reply may be
   missing, and M5 sends a Prepare to the removed replica.

Implementation notes.

- With one ballot per replica, two coordinators of one view always Nack each other's Pull,
  so the "different v_n, two independent instances" case of §2 cannot arise here.
- B.2's first optimization (metadata instead of command bodies) is pure implementation: the
  pool entries in PullOK are `(key, cmd id)` pairs and missing bodies are fetched before
  Accept. The implementation currently sends bodies.
- The implementation encodes a ballot as `(view << 32) | (counter << 8) | loc`: with the
  view in the high bits one integer realizes "compare the view first, then the ballot".

## §4 Requirements on the original protocol (summary)

1. Provide the view record (§0) and call T1 when a proposer learns a new view, before it
   appends any other entry of that view (Raft: after winning the election, before the term's
   empty entry; a config entry itself starts a new view and Recovered(·) follows it).
2. Keep sending heartbeats while paused (T1); queue original-path commands that arrive
   meanwhile (N11).
3. Provide `Propose(c)` (N20), `Pending(R.olog)` (N13), `SpecExec` on the executed state
   (N15), and an execution layer that deduplicates by command id and returns the first result
   (N25, L50).
4. Commit Recovered(S) as an ordinary entry (or a pipelined batch of ordinary requests) and
   notify Jetpack when it commits (L47–L48, L53).
5. Satisfy A1–A7. A5 and A7 are additions to the paper's A1–A4.
6. Persist Jetpack's state together with the original protocol's (§0, Persistence).

## §5 What the paper abbreviates and what this document supplies

The paper's text states the design; its pseudocode figure and several passages are shortened
for space. For each such place, "paper" is the printed form and "the pseudocode" is what this document
makes explicit. The models and the implementation follow this document.

| # | Topic | Paper | This document |
|---|---|---|---|
| 1 | Pool contents and recovery counting | Figure lines 14–16 pick "the one cmd" per key; §5 says all commands enter the pool | The pool holds only ack'd commands (N14); recovery counts per command with threshold t(v_n) (L26–L29); "all commands enter the pool" is how a shim implements `Pending(R.olog)` (N13) |
| 2 | Ballots and Nacks in the recovery Paxos | Prepare/Accept carry no ballot, no Nack; line 11 says "that accepted set" | Explicit ballot k, views compared before ballots, Prepare strict `>` / Accept `≥` (L15, L35); with several accepted values the largest (view, ballot) wins (L24); one Nack format and its handling order (L41–L46) |
| 3 | The replica's two views | BeginRecovery carries no view; the replica records no v | `BeginRecovery(v)`; `join(v)` records `R.new_view`; `R.last_normal_view` kept separately; the two invariants of §0 |
| 4 | How v_n is determined | Figure line 1 reads the last normal view from the original log | Not read from the log: BeginRecoveryOK carries last_normal_view and the coordinator takes the largest of a majority (L6, L9); no assumption that the new proposer's log is complete |
| 5 | The form of Recovered(S) | Lines 21–24 are two branches; no execution rule | One `Recovered(S)`, `S = ∅` is the no-op (L47); execution deduplicates by id and returns the first result (L50, N25); why an empty S is still committed (Phase 3 notes) |
| 6 | View checks on recovery messages | Only Prepare negotiates views; BeginRecovery and FinishRecovery are unconditional | Every recovery message is gated by `R.new_view` and `R.last_normal_view` (L4, L11, L31); a replica past v_n Nacks (L11); a replica joins the newer view before answering Prepare/Accept (L14, L34); nothing needs deleting |
| 7 | FastCmd in a stale view or during recovery | Only "pause processing commands" | `FastNack(last_normal_view, mode)` (N17–N18); a Normal proposer still proposes (N19); the client only moves its view forward and resends with the same id after a timeout (N8–N10) |
| 8 | The fast-commit return value | The published §3.3 drops "speculatively executes", while §3.4 and C2 rely on it; conflicts are checked against "uncommitted" commands | Proposers execute speculatively (N15) and must agree (N4); `Pending` is "not yet executed" (N13); assumption A5 |
| 9 | GC and recovery counting | §5 GC rule; C1 Case 3 says entries are retained "until recovery completes" | GC frozen during recovery, so a PrepareOK pool is a snapshot (N21, N24, §0 invariant); the dedup table is executed state; C1 Case 3 uses the GC rule (GC removes only committed and executed commands) and splits into "c committed (A1)" and "c in the snapshot" |
| 10 | Reconfiguration | Proposer re-election and membership change are handled alike; quorum formulas for n = 2f+1; figure line 3 sends BeginRecovery to v_n's members | A6 (one replica added or removed per change); quorum formulas for any n (§0); views are records with id (term, config index); BeginRecovery goes to replicas(v) and waits for maj(v), Prepare/Accept go to replicas(v_n) and wait for maj(v_n) with threshold t(v_n); a new replica starts at ⊥ |
| 11 | Trigger, coordinators, several proposers | Triggered "when Propose() sees a changed view"; Phase 3 hands the set to "the new proposer"; convergence of several coordinators and original-path commands during recovery are not discussed | Trigger after the new proposer is chosen and before its first entry (T1); every proposer of v runs a coordinator; random backoff on ballot contention (L46); the learn rule (§0); each proposer submits its own Recovered(S), FinishRecovery carries S (T2, L48, L52–L53); commands queue while paused (N11); assumption A7 |
| 12 | Where views come from, per protocol | "Provided by the original protocol" | Raft/MongoDB (term, config index); Copilot (pilot 0 ballot, pilot 1 ballot); Mencius one static view: if a server is down the fast path stops and the original path is unaffected (§0) |
| 13 | Delivery of FinishRecovery | No S, no ack, no retransmission | Carries S; FinishRecoveryOK; asynchronous retransmission until every replica acknowledged (L48–L49, L54), without which a proposer that missed it never obtains S |
| 14 | The merged two-RPC recovery | B.2 says the three operations "do not depend on one another" | With v_n unknown the promise covers every w, one ballot per replica, every accepted value travels, and a removed replica gets a Prepare (§3) |
| 15 | Persistence | Not stated | Jetpack state is persisted together with the original protocol's, written before the reply (§0) |
