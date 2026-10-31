---------------------- MODULE jetpack_mencius_composition ----------------------
\* Composition of Jetpack (jetpack.tla, written from the pseudocode (docs/pseudocode.md)) with
\* Mencius (base_mencius.tla: multi-leader Paxos with round-robin slots).
\*
\* This wrapper:
\*   1. Declares the union of all variables (base + Jetpack + client + execution).
\*   2. INSTANCEs base_mencius.tla and jetpack.tla, mapping variables.
\*   3. Wraps base_mencius actions with UNCHANGED <<jetpackVars, clientVars,
\*      executionVars>> and Jetpack actions with UNCHANGED menciusExtraVars.
\*   4. Supplies the Mencius view (the pseudocode §0 / Q16): ONE static view for the
\*      whole run, DefaultView = [epoch 1, replicas = Server, proposers =
\*      Server]. Mencius has no election and no leader ballot: every server
\*      is a proposer, and its own failure handling is revoke/skip, which
\*      never changes the proposer set. So there is no view change, no
\*      recovery (no coordinator ever starts; cstate / subm stay at their
\*      initial values and rstate stays Normal in DefaultView), and the pool
\*      is used for conflict detection only (N13). A fast commit needs every
\*      server's ack (sq(v) = n since proposers(v) = replicas(v) = Server):
\*      if any server is down the fast path simply stops until it is back,
\*      and the original path is unaffected.
\*
\* ---- Mencius logs and the three places where the wrapper does not call   ----
\* ---- jetpack.tla verbatim (each is the pseudocode line, in Mencius terms)        ----
\*
\* base_mencius derives log[i][j] from the slot array: position k of owner j
\* is slot SlotFor(j, k), and an entry exists only once that slot is
\* Learned/Skipped at i. A suggested-but-unchosen value lives in
\* slotValue[i][sl] (state Proposed / Accepted), not in log. Therefore:
\*
\*   (a) N19–N20 "Propose(c): the original protocol appends c to R.olog by
\*       its own mechanism" is a Mencius Suggest of c in i's next slot
\*       (B!Suggest's state change, inlined so the SuggestRequests go out in
\*       the same step as the FastAck/FastNack). J!HandleFastCmd instead
\*       appends to log[i][ProposerOf(i)] directly, which would put an entry
\*       at a position whose slot is still Empty (or later chosen with a
\*       different value), so it is not used; HandleFastCmd below is the
\*       same N12–N20 line by line, with N20 = Suggest.
\*       The proposal is in the same step as the ack on purpose: a server's
\*       own entries execute in the order it proposed them (A7, one owner's
\*       slots increase), so every command i proposes after acking c lands
\*       in a later slot than i's copy of c.
\*   (b) Pending(R.olog) (N13) is PendingM below: every non-Empty slot at i
\*       (own suggestions, accepted suggestions of others, chosen slots)
\*       minus the executed commands. J!Pending only reads the log, i.e.
\*       chosen slots, and would let a replica ack a command that conflicts
\*       with its own in-flight suggestion.
\*   (c) ApplyCommitted executes in round-robin slot order across all
\*       sequences (Mencius in-order execution, A3), using jetpack.tla's
\*       applied[j] as the per-sequence cursor: the next slot to execute is
\*       Min_j SlotFor(j, applied[j] + 1). Skipped slots (NoOp) and commands
\*       already executed through another owner's earlier copy are skipped
\*       (N25: duplicates across sequences are the normal Mencius case).
\*
\* Everything else of the fast path goes through jetpack.tla unchanged:
\* J!ClientSendFastCmd (N1), J!ClientReceive (N2–N9), J!GC (N21/N24).
\*
\* Not wired (left in base_mencius, unused here): BecomeToBeLeader and
\* EmptyViewChange. They existed to force a server into ToBeLeader so the old
\* wrapper could run a Jetpack recovery; under the pseudocode Mencius has no view change,
\* so no recovery action (StartRecovery / CompleteBeginRecovery / ... /
\* StopCoordinating) is in Next.

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, Client, CmdId, Key,
          MaxRestarts,     \* bound on Restart steps (0 disables them)
          MaxRevokes       \* bound on Revoke steps (0 disables them)

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,

    \* Base protocol interface (shared with Jetpack).
    currentTerm,
    ostate,
    log,
    commitIndex,

    \* Raft-shaped election variables kept by base_mencius (unused here).
    votedFor,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* Mencius-specific variables.
    slotState,
    slotValue,
    slotBallot,
    localIndex,
    acceptCount,

    \* Wrapper counters (state-space bounds).
    restartCtr, revokeCtr,

    \* Jetpack per-server variables (cstate and subm never leave their
    \* initial values: no recovery in Mencius).
    rstate, cstate, subm,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from, client_issued,

    \* Execution tracking.
    original_execution_cmds, execution_cmds, applied, fast_committed

\* Variable groups for UNCHANGED clauses.
menciusExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      slotState, slotValue, slotBallot, localIndex, acceptCount>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
menciusVars   == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>
auxVars       == <<restartCtr, revokeCtr>>
jetpackVars   == <<rstate, cstate, subm>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from, client_issued>>
executionVars == <<original_execution_cmds, execution_cmds, applied, fast_committed>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars, menciusVars,
          auxVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* INSTANCE base protocol and Jetpack modules                              *)
(***************************************************************************)

B == INSTANCE base_mencius

\* Mencius: every server is a proposer and owns its own sequence
\* (Proposer = Server, ProposerOf(i) = i). The one static view: epoch 1,
\* replicas = proposers = Server.
J == INSTANCE jetpack WITH NoOpCmd <- B!NoOp,
                          InitialMembers <- Server,
                          InitialProposers <- Server,
                          InitialEpoch <- 1,
                          Proposer <- Server,
                          ProposerOf <- LAMBDA i : i

(***************************************************************************)
(* Re-exported constants                                                   *)
(***************************************************************************)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Quorum       == B!Quorum
MaxSlot      == B!MaxSlot
NoOp         == B!NoOp

\* Permutations(Server). Not used by the cfgs: base_mencius fixes the
\* round-robin order with a CHOOSE over Server (ServerSeq), which is not
\* symmetric, so TLC's symmetry reduction would be unsound here.
Symmetry     == B!Symmetry

(***************************************************************************)
(* Mencius view of the original log (the pseudocode R.olog)                           *)
(***************************************************************************)

\* Values of all non-Empty slots at i: own suggestions (Proposed), others'
\* suggestions i accepted (Accepted), chosen slots (Learned/Skipped).
SlotCmds(i) ==
    {slotValue[i][sl] : sl \in {s \in 1..MaxSlot : slotState[i][s] # B!Empty}}

\* Values of i's own non-Empty slots.
OwnSlotCmds(i) ==
    {slotValue[i][sl] : sl \in {s \in 1..MaxSlot : /\ B!CoordinatorOf(s) = i
                                                    /\ slotState[i][s] # B!Empty}}

\* Pending(R.olog) (N13) for Mencius: entries of i's slot array that i has
\* not executed yet (a superset of J!Pending, which reads chosen slots only).
PendingM(i) == SlotCmds(i) \ J!Executed

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    /\ B!InitBaseVars
    /\ restartCtr = 0
    /\ revokeCtr = 0
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(***************************************************************************)
(* Wrapped base_mencius transitions                                        *)
(***************************************************************************)

\* Restart keeps Jetpack's state: it is persisted with the base's (the pseudocode §0
\* Persistence). In base_mencius a restarted server becomes Follower and
\* never proposes again (there is no action back to Leader without the
\* unwired BecomeToBeLeader); it still accepts, learns and acks (N12–N16).
Restart(i) ==
    /\ restartCtr < MaxRestarts
    /\ B!Restart(i)
    /\ restartCtr' = restartCtr + 1
    /\ UNCHANGED <<revokeCtr, jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

\* N11: a client submits c on the original path (to one Mencius server). The
\* command id is then used up (client_issued), as on the fast path: every
\* id is used once in the model (jetpack.tla, modeling choices).
ClientRequest(i, v) ==
    /\ v \in J!AvailableCommands
    /\ B!ClientRequest(i, v)
    /\ client_issued' = client_issued \cup {v}
    /\ UNCHANGED <<auxVars, jetpackVars, client_view, client_pending,
                   client_successes, client_heard_from, executionVars>>

Skip(i) ==
    /\ B!Skip(i)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

\* Mencius revokes the slots of a server it suspects has crashed. A suspected
\* server that is in fact alive learns the skip and re-suggests its value in
\* a later slot; base_mencius does not model that re-suggestion (HandleSkip
\* overwrites the owner's Proposed value with NoOp and the command is lost
\* from that owner's sequence, which breaks A7 for it). The wrapper therefore
\* revokes only slots of a restarted owner (ostate /= Leader), which proposes
\* nothing more.
Revoke(i, sl) ==
    /\ revokeCtr < MaxRevokes
    /\ ostate[B!CoordinatorOf(sl)] /= Leader
    /\ B!Revoke(i, sl)
    /\ revokeCtr' = revokeCtr + 1
    /\ UNCHANGED <<restartCtr, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Wrapped Mencius message handlers                                        *)
(***************************************************************************)

HandleSuggest(i, m) ==
    /\ B!HandleSuggest(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

HandleSuggestResponse(i, m) ==
    /\ B!HandleSuggestResponse(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

HandleSkip(i, m) ==
    /\ B!HandleSkip(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

HandleLearn(i, m) ==
    /\ B!HandleLearn(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

HandleRevoke(i, m) ==
    /\ B!HandleRevoke(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

HandleRevokeResponse(i, m) ==
    /\ B!HandleRevokeResponse(i, m)
    /\ UNCHANGED <<auxVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Jetpack fast path on a Mencius replica (the pseudocode N12–N20)                    *)
(***************************************************************************)

\* Same as J!HandleFastCmd line by line, except N13 uses PendingM and N20
\* (Propose) is a Mencius Suggest of c in i's next slot (B!Suggest's state
\* change with the SuggestRequests added to the reply's message update).
\* i proposes c unless it already has c in one of its own slots or c is
\* already chosen at i (a resend / an already-chosen copy, dedup'd by N25).
\* If i has no slot left (localIndex > MaxSlot, a model bound) or its next
\* slot is not Empty, it cannot propose anything (so A7 still holds for it).
HandleFastCmd(i, m) ==
    /\ m.mtype = J!FastCmd
    /\ i = m.mdest
    /\ LET v    == m.mview
           cmd  == m.mcmd
           r    == rstate[i]
           viewOk   == v.epoch = r.lnv.epoch /\ r.mode = J!Normal              \* N12
           conflict == \E d \in r.pool \cup PendingM(i) : J!CmdConflicts(d, cmd)  \* N13
           ack  == viewOk /\ ~conflict
           reply == IF ack
                    THEN [mtype |-> J!FastAck, msource |-> i, mdest |-> m.msource,
                          mview |-> v, mcmd |-> cmd]                           \* N16
                    ELSE [mtype |-> J!FastNack, msource |-> i, mdest |-> m.msource,
                          mlnv |-> r.lnv, mmode |-> r.mode, mcmd |-> cmd,
                          mconflict |-> viewOk]                                \* N18 (conflict: modeled timeout)
           sl   == localIndex[i]
           \* N19–N20: a Normal proposer proposes c regardless of conflicts or v.
           propose == /\ r.mode = J!Normal /\ ostate[i] = Leader
                      /\ cmd \notin OwnSlotCmds(i)
                      /\ cmd \notin J!LogCmds(i)
                      /\ sl <= MaxSlot
                      /\ slotState[i][sl] = B!Empty
           suggestMsgs == { [mtype |-> B!SuggestRequest,
                             mterm |-> currentTerm[i],
                             msource |-> i,
                             mdest |-> s,
                             mslot |-> sl,
                             mvalue |-> cmd,
                             mballot |-> 1] : s \in Server \ {i} }
       IN /\ rstate' = IF ack THEN [rstate EXCEPT ![i].pool = r.pool \cup {cmd}] ELSE rstate   \* N14
          /\ IF propose
             THEN /\ slotState'   = [slotState EXCEPT ![i][sl] = B!Proposed]
                  /\ slotValue'   = [slotValue EXCEPT ![i][sl] = cmd]
                  /\ slotBallot'  = [slotBallot EXCEPT ![i][sl] = 1]
                  /\ localIndex'  = [localIndex EXCEPT ![i] = sl + B!N]
                  /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]
                  /\ messages' = B!AddMessages(suggestMsgs,
                                     B!WithoutMessage(m, B!WithMessage(reply, messages)))
             ELSE /\ UNCHANGED menciusVars
                  /\ B!Reply(reply, m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, auxVars,
                         cstate, subm, clientVars, executionVars>>

(***************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED menciusExtraVars, auxVars)   *)
(***************************************************************************)

WClientSendFastCmd(c) ==
    /\ J!ClientSendFastCmd(c)
    /\ UNCHANGED <<menciusExtraVars, auxVars>>

\* N21 / N24: a Normal replica drops an executed command from its pool.
WGC(i, cmd) ==
    /\ J!GC(i, cmd)
    /\ UNCHANGED <<menciusExtraVars, auxVars>>

\* N25 in Mencius: execute committed slots in round-robin slot order across
\* all sequences. applied[j] is the number of positions of owner j's sequence
\* executed so far; as execution is in slot order, the executed slots are
\* exactly 1..S and the next one is Min_j SlotFor(j, applied[j] + 1). Any
\* server whose committed prefix contains that position may apply it
\* (committed prefixes agree: CommittedLogAgreement). A skipped slot (NoOp)
\* and a command already executed through an earlier copy are not executed.
ApplyCommitted(i) ==
    LET nextSlot == J!Min({B!SlotFor(j, applied[j] + 1) : j \in Server})
        j == B!CoordinatorOf(nextSlot)
        k == applied[j] + 1
    IN /\ nextSlot <= MaxSlot
       /\ k <= commitIndex[i][j]
       /\ LET e == log[i][j][k]
              newCmds == SelectSeq(J!EntrySeq(e), LAMBDA x : x # NoOp /\ x \notin J!Executed)
          IN /\ original_execution_cmds' = original_execution_cmds \o newCmds
             /\ execution_cmds' = execution_cmds \o newCmds
             /\ applied' = [applied EXCEPT ![j] = k]
       /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                      menciusVars, auxVars, jetpackVars, clientVars, fast_committed>>

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype = B!SuggestRequest
          /\ HandleSuggest(m.mdest, m)
       \/ /\ m.mtype = B!SuggestResponse
          /\ HandleSuggestResponse(m.mdest, m)
       \/ /\ m.mtype = B!SkipMessage
          /\ HandleSkip(m.mdest, m)
       \/ /\ m.mtype = B!LearnMessage
          /\ HandleLearn(m.mdest, m)
       \/ /\ m.mtype = B!RevokeRequest
          /\ HandleRevoke(m.mdest, m)
       \/ /\ m.mtype = B!RevokeResponse
          /\ HandleRevokeResponse(m.mdest, m)
       \/ /\ m.mtype = J!FastCmd
          /\ HandleFastCmd(m.mdest, m)

\* N2–N9 through jetpack.tla (FastAck / FastNack).
ClientReceive(m) ==
    /\ m.mdest \in Client
    /\ J!ClientReceive(m.mdest, m)
    /\ UNCHANGED <<menciusExtraVars, auxVars>>

\* A message its receiver can no longer handle (modeling, not protocol):
\* base_mencius's handlers are guarded by the slot's state, so a
\* SuggestRequest that arrives after the Learn of its slot, the second
\* SuggestResponse after the slot is already Learned, a Skip/Revoke for a
\* decided slot, and a FastAck/FastNack of a finished attempt (jetpack.tla
\* requires client_pending = m.mcmd) would stay in the bag forever. Such a
\* message is discarded, and discarded first (Next): the discard changes no
\* other variable and commutes with every step, so this only removes
\* interleavings.
Stale(m) ==
    LET i == m.mdest
    IN CASE m.mtype = B!SuggestRequest ->
                ~(/\ m.mballot >= slotBallot[i][m.mslot]
                  /\ slotState[i][m.mslot] \in {B!Empty, B!Proposed})
         [] m.mtype = B!SuggestResponse -> slotState[i][m.mslot] # B!Proposed
         [] m.mtype = B!SkipMessage -> slotState[i][m.mslot] \notin {B!Empty, B!Proposed}
         [] m.mtype = B!RevokeRequest ->
                ~(/\ m.mballot > slotBallot[i][m.mslot]
                  /\ slotState[i][m.mslot] \in {B!Empty, B!Proposed})
         [] m.mtype = B!RevokeResponse -> slotState[i][m.mslot] # B!Proposed
         [] m.mtype \in {J!FastAck, J!FastNack} -> client_pending[i] # m.mcmd
         [] OTHER -> FALSE

DiscardStale(m) ==
    /\ Stale(m)
    /\ B!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, menciusVars,
                   auxVars, jetpackVars, clientVars, executionVars>>

NoStaleMessages == \A m \in DOMAIN messages : ~Stale(m)

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    \/ \E m \in DOMAIN messages : DiscardStale(m)
    \/ /\ NoStaleMessages
       /\ \* Mencius
          \/ \E i \in Server : Restart(i)
          \/ \E i \in Server : AdvanceCommitIndex(i)
          \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
          \/ \E i \in Server : Skip(i)
          \/ \E i \in Server, sl \in 1..MaxSlot : Revoke(i, sl)

          \* Jetpack (fast path only: no view change, hence no recovery)
          \/ \E c \in Client : WClientSendFastCmd(c)
          \/ \E i \in Server, cmd \in J!Commands : WGC(i, cmd)
          \/ \E i \in Server : ApplyCommitted(i)

          \/ \E m \in DOMAIN messages : ServerReceive(m)
          \/ \E m \in DOMAIN messages : ClientReceive(m)

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* State constraints                                                       *)
(***************************************************************************)

\* Message budget 7 = one FastCmd round with every server's FastAck and
\* SuggestRequests in flight (3 acks + 6 suggests, two acks consumed), so a
\* fast commit is reachable in 7 steps. Each owner uses at most two of its
\* three slots (localIndex bound), so logs have at most two positions.
StateConstraint ==
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 7
    /\ \A i \in Server : localIndex[i] <= B!SlotFor(i, 3)
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 2
    /\ Len(original_execution_cmds) <= 3
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 7
    /\ \A i \in Server : localIndex[i] <= B!SlotFor(i, 3)
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 3

(***************************************************************************)
(* Properties / invariants                                                 *)
(***************************************************************************)

CommittedLogAgreement    == J!CommittedLogAgreement
ExecutionDedupMatches    == J!ExecutionDedupMatches
ReplicaInvariants        == J!ReplicaInvariants
FastCommitDurability     == J!FastCommitDurability   \* trivially true: lnv never advances
PoolsConflictFree        == J!PoolsConflictFree

\* Per-sequence version from jetpack.tla. It does NOT hold for Mencius and is
\* not checked: two owners may propose the same conflicting pair in opposite
\* orders (R1: c then e, R5: e then c, both nacked); execution dedups at the
\* earliest copy, so one owner's sequence order is necessarily not the
\* execution order. The Mencius form is SlotOrderMatchesExecution.
LogOrderMatchesExecution == J!LogOrderMatchesExecution

\* Committed slots at i in slot order (the Mencius execution order), each
\* command at its first copy, no NoOps.
PosOf(sl) == ((sl - 1) \div B!N) + 1

RECURSIVE SlotSeqFrom(_, _)
SlotSeqFrom(i, sl) ==
    IF sl > MaxSlot THEN <<>>
    ELSE LET j == B!CoordinatorOf(sl)
             k == PosOf(sl)
             here == IF k <= commitIndex[i][j] THEN <<log[i][j][k].value>> ELSE <<>>
         IN here \o SlotSeqFrom(i, sl + 1)

SlotSeq(i) == J!Dedup(J!FilterNoOps(SlotSeqFrom(i, 1)))

\* Committed slot order matches the execution trace for conflicting commands
\* (in particular a fast commit is never preceded by a conflicting command
\* that was chosen in a later slot).
SlotOrderMatchesExecution ==
    \A i \in Server : J!ConflictOrderPreserved(SlotSeq(i), J!FilterNoOps(execution_cmds))

\* All servers that have learned the same slot agree on its value.
SlotAgreement ==
    \A i, j \in Server :
        \A sl \in 1..MaxSlot :
            (/\ slotState[i][sl] \in {B!Learned, B!Skipped}
             /\ slotState[j][sl] \in {B!Learned, B!Skipped})
            => slotValue[i][sl] = slotValue[j][sl]

\* log[i][j] is exactly the chosen prefix of j's slots at i.
LogMatchesSlots ==
    \A i, j \in Server : \A k \in 1..Len(log[i][j]) :
        /\ slotState[i][B!SlotFor(j, k)] \in {B!Learned, B!Skipped}
        /\ log[i][j][k].value = slotValue[i][B!SlotFor(j, k)]

\* the pseudocode Q16 for Mencius: the one static view, never a recovery.
StaticView ==
    /\ \A i \in Server : /\ rstate[i].lnv = J!DefaultView
                         /\ rstate[i].nv = J!DefaultView
                         /\ rstate[i].mode = J!Normal
                         /\ cstate[i] = J!IdleCoord
                         /\ subm[i] = J!NoSubmission
    /\ \A c \in Client : client_view[c] = J!DefaultView

Safety ==
    [](CommittedLogAgreement
       /\ SlotOrderMatchesExecution
       /\ ExecutionDedupMatches
       /\ ReplicaInvariants
       /\ FastCommitDurability
       /\ PoolsConflictFree
       /\ SlotAgreement
       /\ LogMatchesSlots
       /\ StaticView)

SpecSafety == Spec => Safety

(***************************************************************************)
(* Reachability probes: each of these is EXPECTED to be violated. Checking  *)
(* one as an INVARIANT makes TLC print a trace that reaches the behaviour  *)
(* (jetpack_mencius_probe_*.cfg).                                          *)
(***************************************************************************)

Probe_NoFastCommit == fast_committed = {}

\* No command is chosen in two owners' sequences (the Mencius duplicate case).
Probe_NoCrossSequenceDuplicate ==
    \A i \in Server : \A j1, j2 \in Server : j1 # j2 =>
        \A k1 \in 1..commitIndex[i][j1], k2 \in 1..commitIndex[i][j2] :
            log[i][j1][k1].value = NoOp \/ log[i][j1][k1].value # log[i][j2][k2].value

=============================================================================
