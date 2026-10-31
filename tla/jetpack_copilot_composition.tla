---------------------- MODULE jetpack_copilot_composition ----------------------
\* Composition of Jetpack (jetpack.tla, written from pseudocode-the pseudocode) with
\* CoPilot (base_copilot.tla: two pilots, per-slot ballots).
\*
\* This wrapper:
\*   1. Declares the union of all variables (base + Jetpack + client +
\*      execution) plus one history variable of its own (firstSeq).
\*   2. INSTANCEs base_copilot.tla and jetpack.tla, mapping variables.
\*   3. Wraps base_copilot actions with UNCHANGED <<jetpackVars, clientVars,
\*      executionVars, firstSeq>> and Jetpack actions with UNCHANGED
\*      copilotOnlyVars.
\*   4. Supplies the CoPilot view (the pseudocode §0 / Q16): id = (ballot of pilot 0,
\*      ballot of pilot 1), lexicographic, encoded as B!EpochOf(b0, b1);
\*      members = Server (fixed membership); proposers = the two current
\*      pilots. Replacing either pilot, or a pilot raising its own ballot,
\*      starts a new view.
\*   5. Supplies the trigger (the pseudocode T1): every view change in base_copilot
\*      pauses BOTH pilots (ostate ToBeLeader; the unchanged pilot learns the
\*      view from the other pilot's election). Each paused pilot starts a
\*      coordinator for ViewOf(i) (WStartRecovery) and submits its own
\*      Recovered(S) as its first entry of the view (J!CompleteAccept, L47,
\*      or the copy from FinishRecovery, L52-L53). It becomes Leader again
\*      when that entry is committed in its own sequence (J!ResumeAfterRecovered,
\*      T2; gated here on the submission being for the current view). While
\*      ToBeLeader it still replicates (B!Replicate) but proposes no client
\*      command.
\*   6. Orders execution across the two sequences by CoPilot's dependencies
\*      (cpLog), around J!ApplyCommitted which applies one committed entry of
\*      one sequence at a time, expands Recovered(S) entries (J!EntrySeq) and
\*      skips already-executed commands (N25).
\*
\* CoPilot uses per-server proposer ids (Proposer = Server): sequence j is
\* server j's own sequence for ever (a server that takes over a slot continues
\* in its own sequence), so J's applied[j] (committed entries of sequence j
\* applied so far) is exactly CoPilot's per-pilot in-order execution (the pseudocode A7);
\* no separate progress bookkeeping is needed. The dependency order is a
\* guard on top of it (DepsSatisfied).

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, Client, CmdId, Key, MaxPilotChanges, MaxRestarts

(****************************************************************************)
(* Variables                                                                *)
(****************************************************************************)

VARIABLES
    messages,

    \* Base protocol interface (shared with Jetpack).
    currentTerm,
    ostate,
    log,
    commitIndex,

    \* CoPilot-specific variables (base_copilot).
    votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
    role, cpLog, cpBallot, pilotBallot, pilotChangeCtr, restartCtr,

    \* Jetpack per-server variables.
    rstate, cstate, subm,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from, client_issued,

    \* Execution tracking.
    original_execution_cmds, execution_cmds, applied, fast_committed,

    \* Wrapper history: firstSeq[c] = the sequence whose entry first executed
    \* command c (CoPilot executes a command once even if both pilots
    \* proposed it, N20/N25; the duplicate is a no-op).
    firstSeq

copilotOnlyVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                     role, cpLog, cpBallot, pilotBallot, pilotChangeCtr, restartCtr>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
copilotVars   == <<role, cpLog, cpBallot, pilotBallot>>
auxVars       == <<pilotChangeCtr, restartCtr>>
jetpackVars   == <<rstate, cstate, subm>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from, client_issued>>
executionVars == <<original_execution_cmds, execution_cmds, applied, fast_committed>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars, copilotVars,
          auxVars, jetpackVars, clientVars, executionVars, firstSeq>>

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_copilot

\* CoPilot: per-server proposer ids. The initial view's proposers are the
\* two initial pilots exactly as B!InitBaseVars sets them, its epoch is the
\* encoding of their initial ballots (1, 1).
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "CoPilotNoOp"],
                          InitialMembers <- Server,
                          Proposer <- Server,
                          ProposerOf <- LAMBDA i : i,
                          InitialProposers <- {B!PilotOf(1), B!CopilotOf(1)},
                          InitialEpoch <- B!EpochOf(1, 1)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Quorum       == B!Quorum

InitialEpoch == B!EpochOf(1, 1)

\* The view a paused pilot starts recovery for (T1): the current slot
\* ballots (b0, b1), fixed membership, the two current pilots. All servers
\* see the same view (the election is one step in base_copilot).
ViewOf(i) ==
    [epoch |-> B!ViewEpoch,
     replica_ids |-> Server,
     proposing_replica_ids |-> B!Pilots]

(****************************************************************************)
(* Initialization                                                           *)
(****************************************************************************)

Init ==
    /\ B!InitBaseVars
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars
    /\ firstSeq = [c \in {} |-> "none"]

(****************************************************************************)
(* Wrapped base_copilot transitions                                         *)
(****************************************************************************)

\* Restart keeps Jetpack's state: it is persisted with the base's (the pseudocode §0
\* Persistence, Q15).
Restart(i) ==
    /\ B!Restart(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

\* View changes (the pseudocode §0 Copilot view id, T1): both pilots of the new view
\* are paused by base_copilot; WStartRecovery then runs Jetpack recovery.
EmptyViewChange(i) ==
    /\ B!EmptyViewChange(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

FastTakeover(i, p) ==
    /\ B!FastTakeover(i, p)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

\* Original-path client command (the pseudocode N11).
ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

\* Replication of entries Jetpack appended (Recovered(S), fast-path
\* commands), also while paused (T1-T2).
Replicate(i) ==
    /\ B!Replicate(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

HandleCoPilotPreAccept(i, m) ==
    /\ B!HandleCoPilotPreAccept(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

HandleCoPilotPreAcceptResponse(i, m) ==
    /\ B!HandleCoPilotPreAcceptResponse(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

HandleCoPilotCommit(i, m) ==
    /\ B!HandleCoPilotCommit(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars, firstSeq>>

CopilotReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ HandleCoPilotPreAccept(m.mdest, m)
       \/ HandleCoPilotPreAcceptResponse(m.mdest, m)
       \/ HandleCoPilotCommit(m.mdest, m)

(****************************************************************************)
(* Execution order: CoPilot dependencies around J!ApplyCommitted            *)
(****************************************************************************)

\* The next committed entry of sequence j (position applied[j] + 1, as seen
\* on server i) may be executed when each dependency recorded in cpLog is
\* either already executed, or not committed on i (CoPilot would wait for it;
\* the model does not block on entries that may never commit, e.g. a replaced
\* pilot's), or in a mutual dependency with this entry (both conflicting
\* entries were proposed concurrently), which is broken by server rank:
\* the lower-ranked sequence goes first.
DepsSatisfied(i, j) ==
    LET n == applied[j] + 1
        deps == cpLog[i][j][n].deps
        Mutual(d) ==
            /\ d.k <= Len(cpLog[i][d.p])
            /\ \E d2 \in cpLog[i][d.p][d.k].deps : d2.p = j /\ d2.k >= n
    IN \A d \in deps :
         \/ d.k <= applied[d.p]
         \/ d.k > commitIndex[i][d.p]
         \/ Mutual(d) /\ B!Rank(j) < B!Rank(d.p)

\* N25 / L50 within CoPilot's order: J!ApplyCommitted executes the next
\* committed entry of sequence j once per command (Recovered(S) expanded by
\* J!EntrySeq, executed commands skipped). firstSeq records which sequence
\* first executed each command.
WApplyCommitted(i, j) ==
    /\ applied[j] < commitIndex[i][j]
    /\ DepsSatisfied(i, j)
    /\ J!ApplyCommitted(i, j)
    /\ LET e == log[i][j][applied[j] + 1]
           newCmds == SelectSeq(J!EntrySeq(e), LAMBDA x : x \notin J!Executed)
       IN firstSeq' = firstSeq @@ [c \in J!SeqToSet(newCmds) |-> j]
    /\ UNCHANGED copilotOnlyVars

(****************************************************************************)
(* Wrapped Jetpack transitions (each adds UNCHANGED copilotOnlyVars)        *)
(****************************************************************************)

\* T1: a paused pilot starts the coordinator for the view it is in. Both
\* pilots are paused by every view change, so both run this (one coordinator
\* per proposer; J!StartRecovery requires i \in v.proposing_replica_ids and
\* runs once per view).
WStartRecovery(i) ==
    /\ ostate[i] = ToBeLeader
    /\ J!StartRecovery(i, ViewOf(i))
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WClientSendFastCmd(c) ==
    /\ J!ClientSendFastCmd(c)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WGC(i, cmd) ==
    /\ J!GC(i, cmd)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

\* T2: a pilot resumes proposing only when its own Recovered(S) for the view
\* it is in now is committed. A Recovered of an older view that commits
\* after a further view change does not resume it (the pilot is paused for
\* the newer view and will submit a new Recovered for it, L47 / L53).
WResumeAfterRecovered(i) ==
    /\ subm[i].epoch = B!ViewEpoch
    /\ J!ResumeAfterRecovered(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WRetransmitFinishRecovery(i) ==
    /\ J!RetransmitFinishRecovery(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WStopCoordinating(i) ==
    /\ J!StopCoordinating(i)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WServerReceive(m) ==
    /\ m.mdest \in Server
    /\ J!ServerReceive(m.mdest, m)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

WClientReceive(m) ==
    /\ m.mdest \in Client
    /\ J!ClientReceive(m.mdest, m)
    /\ UNCHANGED <<copilotOnlyVars, firstSeq>>

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

\* Not wired (as in the Raft wrapper): B!Timeout / B!BecomeToBeLeader (a
\* vote-less election skeleton that cannot elect) and B!DuplicateMessage /
\* B!DropMessage (state space; the message bag already allows any delivery
\* order).
Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : EmptyViewChange(i)
    \/ \E i, p \in Server : FastTakeover(i, p)
    \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
    \/ \E i \in Server : Replicate(i)
    \/ \E m \in DOMAIN messages : CopilotReceive(m)

    \* Jetpack
    \/ \E c \in Client : WClientSendFastCmd(c)
    \/ \E i \in Server, cmd \in J!Commands : WGC(i, cmd)
    \/ \E i, j \in Server : WApplyCommitted(i, j)
    \/ \E i \in Server : WStartRecovery(i)
    \/ \E i \in Server : WCompleteBeginRecovery(i)
    \/ \E i \in Server : WCompletePrepare(i)
    \/ \E i \in Server : WCompleteAccept(i)
    \/ \E i \in Server : WResumeAfterRecovered(i)
    \/ \E i \in Server : WRetransmitFinishRecovery(i)
    \/ \E i \in Server : WStopCoordinating(i)
    \/ \E m \in DOMAIN messages : WServerReceive(m)
    \/ \E m \in DOMAIN messages : WClientReceive(m)

Spec == Init /\ [][Next]_vars

(****************************************************************************)
(* State constraints                                                        *)
(****************************************************************************)

StateConstraint ==
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 8
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 4
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 8
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 3
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(****************************************************************************)
(* Properties / invariants                                                  *)
(****************************************************************************)

CommittedLogAgreement    == J!CommittedLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches    == J!ExecutionDedupMatches
ReplicaInvariants        == J!ReplicaInvariants
RecoveredAgreement       == J!RecoveredAgreement
FastCommitDurability     == J!FastCommitDurability
PoolsConflictFree        == J!PoolsConflictFree

\* CoPilot variant of LogOrderMatchesExecution. Both pilots propose every
\* fast-path command (N20) and a client may hand the same command to either
\* pilot, so one command can sit in both sequences at different relative
\* positions; the second occurrence executes as a no-op (N25). The order of
\* a sequence therefore constrains only the commands it executed first (or
\* has not executed yet), and only their first occurrence in the sequence
\* (a command can recur in one sequence: proposed, then part of a later
\* Recovered(S), L47/L53; the recurrence is a no-op, N25). With a single
\* command the two properties coincide.
EffectiveSeq(i, j) ==
    J!Dedup(SelectSeq(J!CommittedCmdSeq(i, j),
                      LAMBDA c : c \notin DOMAIN firstSeq \/ firstSeq[c] = j))

LogOrderMatchesExecutionCopilot ==
    \A i \in Server : \A j \in Server :
        J!ConflictOrderPreserved(J!FilterNoOps(EffectiveSeq(i, j)),
                                 J!FilterNoOps(execution_cmds))

\* Exactly one holder per pilot slot (strengthens the old ActiveProposerBound).
TwoPilots ==
    /\ Cardinality({i \in Server : role[i] = B!Pilot}) = 1
    /\ Cardinality({i \in Server : role[i] = B!Copilot}) = 1

ActiveProposerBound == Cardinality(B!Pilots) <= 2

\* Every server's term is the current view epoch (the pseudocode §0 Copilot view id).
TermIsViewEpoch == \A i \in Server : currentTerm[i] = B!ViewEpoch

\* Base sanity: committed prefixes exist, cpLog never runs ahead of log.
CommitIndexWithinLog ==
    \A i, j \in Server : /\ commitIndex[i][j] <= Len(log[i][j])
                         /\ Len(cpLog[i][j]) <= Len(log[i][j])

\* Principle 2 (the pseudocode T2) in CoPilot terms, per pilot: in every sequence j (on
\* any server's copy), before any client-command entry appended in view v
\* (entry.term = v's epoch) there is j's own Recovered entry of view v. The
\* initial view needs no marker.
Principle2Copilot ==
    \A i \in Server : \A j \in Server :
        LET lg == log[i][j]
        IN \A n \in DOMAIN lg :
            (lg[n].command = B!AppendCommand /\ lg[n].term /= InitialEpoch) =>
                \E m \in 1..(n - 1) :
                    /\ lg[m].command = J!RecoveredCommand
                    /\ lg[m].value.by = j
                    /\ lg[m].value.vepoch = lg[n].term

\* T2 as a state invariant: a pilot proposes (Leader) only in the initial
\* view or after its own Recovered for the current view is committed.
ResumeOnlyAfterOwnRecovered ==
    \A i \in Server :
        ostate[i] = Leader =>
            \/ B!ViewEpoch = InitialEpoch
            \/ J!OwnRecoveredCommitted(i, B!ViewEpoch)

\* Only pilots are ever Leader or ToBeLeader.
OnlyPilotsLead ==
    \A i \in Server : ostate[i] \in {Leader, ToBeLeader} => B!IsPilotOrCopilot(i)

\* Messages still in flight (consumed message keys may stay with count 0).
LiveMsgs == {m \in DOMAIN messages : messages[m] > 0}

\* Views held by servers, coordinators and clients, or carried by live messages.
StateViews ==
    LET ms(T) == {m \in LiveMsgs : m.mtype \in T}
        withView == {J!FastCmd, J!FastAck, J!BeginRecovery, J!BeginRecoveryOK, J!Prepare,
                     J!PrepareOK, J!Accept, J!AcceptOK, J!FinishRecovery, J!FinishRecoveryOK}
        withLnv  == {J!FastNack, J!BeginRecoveryOK, J!Nack}
        withVn   == {J!Prepare, J!PrepareOK, J!Accept, J!AcceptOK, J!FinishRecovery}
    IN  {rstate[i].lnv : i \in Server} \cup {rstate[i].nv : i \in Server}
        \cup {cstate[i].view : i \in Server} \cup {cstate[i].vn : i \in Server}
        \cup {client_view[c] : c \in Client}
        \cup {ViewOf(i) : i \in Server}
        \cup {m.mview : m \in ms(withView)}
        \cup {m.mlnv : m \in ms(withLnv)}
        \cup {m.mnv : m \in ms({J!Nack})}
        \cup {m.mvn : m \in ms(withVn)}

\* An epoch names one view record (the pseudocode §0).
EpochDeterminesMembership ==
    \A v, w \in StateViews :
        v.epoch = w.epoch => /\ v.replica_ids = w.replica_ids
                             /\ v.proposing_replica_ids = w.proposing_replica_ids

Safety ==
    [](CommittedLogAgreement
       /\ LogOrderMatchesExecutionCopilot
       /\ ExecutionDedupMatches
       /\ ReplicaInvariants
       /\ RecoveredAgreement
       /\ FastCommitDurability
       /\ PoolsConflictFree
       /\ TwoPilots
       /\ TermIsViewEpoch
       /\ CommitIndexWithinLog
       /\ Principle2Copilot
       /\ ResumeOnlyAfterOwnRecovered
       /\ OnlyPilotsLead
       /\ EpochDeterminesMembership)

SpecSafety == Spec => Safety

(****************************************************************************)
(* Reachability probes: each of these is EXPECTED to be violated. Checking   *)
(* one as an INVARIANT makes TLC print a trace that reaches the behaviour,  *)
(* which shows the model exercises it (jetpack_copilot_probe_*.cfg).        *)
(****************************************************************************)

Probe_NoFastCommit == fast_committed = {}
Probe_NoRecoveredCommitted ==
    \A i, j \in Server : \A k \in 1..commitIndex[i][j] :
        log[i][j][k].command /= J!RecoveredCommand
Probe_NoViewInstalled == \A i \in Server : rstate[i].lnv.epoch = InitialEpoch
Probe_NoFastCommitAfterRecovery ==
    \A fc \in fast_committed : fc.epoch = InitialEpoch
\* Both pilots resumed in a non-initial view (each committed its own Recovered).
Probe_NoBothPilotsResumed ==
    ~(/\ B!ViewEpoch /= InitialEpoch
      /\ \A p \in B!Pilots : ostate[p] = Leader)

=============================================================================
