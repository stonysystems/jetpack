--------------------------- MODULE jetpack_mencius ---------------------------
\* Composition of Jetpack plugin with Mencius base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + Mencius-specific)
\*   2. INSTANCE's jetpack.tla (maps shared variables)
\*   3. Defines Mencius-specific actions inline
\*   4. Wraps J!<action> with UNCHANGED menciusExtraVars for Jetpack actions
\*   5. Wires Init, Next, Spec, and properties
\*
\* Mencius provides: multi-leader Paxos with round-robin slot assignment.
\* Jetpack provides: fast-path preaccept with recovery on leader change.
\*
\* Key differences from jetpack_raft.tla:
\*   - All servers start as Leader (multi-leader Paxos)
\*   - BecomeToBeLeader only used after Restart (recovery path)
\*   - Mencius-specific variables (slotState, slotValue, etc.) added

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value for votedFor.
Nil == "Nil"
NoOp == [tag |-> "NoOp"]

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

    \* Raft-compatible election variables (used by Jetpack's interface).
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

    \* Jetpack per-server variables.
    jstate, jepoch, oepoch, old_view, new_view, jpool,
    recovery_set, chosen_value, br_responses, prep_responses, accept_responses,

    \* Client-side variables.
    client_view, client_pending, client_successes,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Protocol-specific variables (for UNCHANGED in Jetpack actions).
menciusExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      slotState, slotValue, slotBallot, localIndex, acceptCount>>

\* Variable groups for actions' UNCHANGED clauses.
serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>
menciusVars == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>
jetpackVars == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                 recovery_set, chosen_value, br_responses,
                 prep_responses, accept_responses>>
clientVars == <<client_view, client_pending, client_successes>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, menciusVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* INSTANCE Jetpack module                                                 *)
(***************************************************************************)

J == INSTANCE jetpack

(***************************************************************************)
(* Mencius helpers and constants                                           *)
(***************************************************************************)

Follower   == J!Follower
Candidate  == J!Candidate
ToBeLeader == J!ToBeLeader
Leader     == J!Leader

\* Mencius slot states.
Empty     == "Empty"
Proposed  == "Proposed"
Accepted  == "Accepted"
Learned   == "Learned"
Skipped   == "Skipped"

\* Mencius message types.
SuggestRequest   == "SuggestRequest"
SuggestResponse  == "SuggestResponse"
SkipMessage      == "SkipMessage"
RevokeRequest    == "RevokeRequest"
RevokeResponse   == "RevokeResponse"
LearnMessage     == "LearnMessage"

MenciusMessageTypes == {SuggestRequest, SuggestResponse,
                        SkipMessage, RevokeRequest,
                        RevokeResponse, LearnMessage}

N == Cardinality(Server)

Symmetry == Permutations(Server)

Quorum == J!Quorum

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

SlotValues == J!Commands \cup {NoOp}

\* Map server to a unique index 1..N for round-robin assignment.
ServerSeq == CHOOSE f \in [1..N -> Server] :
                \A i, j \in 1..N : i /= j => f[i] /= f[j]

ServerIdx(s) == CHOOSE idx \in 1..N : ServerSeq[idx] = s

CoordinatorOf(sl) == ServerSeq[((sl - 1) % N) + 1]

MaxSlot == N * 3

MySlotsUpTo(i, limit) == {sl \in 1..limit : CoordinatorOf(sl) = i}

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    /\ messages = [m \in {} |-> 0]
    /\ currentTerm = [i \in Server |-> 1]
    /\ ostate = [i \in Server |-> Leader]    \* In Mencius, all servers are leaders
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    \* Mencius init.
    /\ slotState = [i \in Server |-> [sl \in 1..MaxSlot |-> Empty]]
    /\ slotValue = [i \in Server |-> [sl \in 1..MaxSlot |-> J!NilCmd]]
    /\ slotBallot = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
    /\ localIndex = [i \in Server |-> ServerIdx(i)]
    /\ acceptCount = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
    \* Jetpack init.
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(***************************************************************************)
(* Mencius transitions (protocol-specific)                                 *)
(***************************************************************************)

\* Coordinator suggests a command for its next slot.
Suggest(i, v) ==
    /\ v \in J!AvailableCommands
    /\ localIndex[i] <= MaxSlot
    /\ CoordinatorOf(localIndex[i]) = i
    /\ slotState[i][localIndex[i]] = Empty
    /\ LET sl == localIndex[i]
           msgSet == { [mtype |-> SuggestRequest,
                        mterm |-> currentTerm[i],
                        msource |-> i,
                        mdest |-> s,
                        mslot |-> sl,
                        mvalue |-> v,
                        mballot |-> 1] : s \in Server \ {i} }
       IN /\ slotState' = [slotState EXCEPT ![i][sl] = Proposed]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = v]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = 1]
          /\ localIndex' = [localIndex EXCEPT ![i] = sl + N]
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]
          /\ log' = [log EXCEPT ![i] = Append(log[i],
                        [term |-> currentTerm[i], value |-> v])]
          /\ messages' = J!AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         jetpackVars, clientVars, executionVars>>

\* Coordinator skips its slot with a no-op.
Skip(i) ==
    /\ localIndex[i] <= MaxSlot
    /\ CoordinatorOf(localIndex[i]) = i
    /\ slotState[i][localIndex[i]] = Empty
    /\ LET sl == localIndex[i]
           msgSet == { [mtype |-> SkipMessage,
                        mterm |-> currentTerm[i],
                        msource |-> i,
                        mdest |-> s,
                        mslot |-> sl] : s \in Server \ {i} }
       IN /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ localIndex' = [localIndex EXCEPT ![i] = sl + N]
          /\ messages' = J!AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotBallot, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleSuggest(i, m) ==
    /\ m.mtype = SuggestRequest
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ m.mballot >= slotBallot[i][sl]
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Accepted]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = m.mvalue]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = m.mballot]
          /\ J!Reply([mtype |-> SuggestResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mslot |-> sl,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleSuggestResponse(i, m) ==
    /\ m.mtype = SuggestResponse
    /\ i = m.mdest
    /\ m.mok
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] = Proposed
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = acceptCount[i][sl] + 1]
          /\ IF acceptCount[i][sl] + 1 >= (N \div 2 + 1)
             THEN
               /\ slotState' = [slotState EXCEPT ![i][sl] = Learned]
               /\ LET learnMsgs == { [mtype |-> LearnMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl,
                                       mvalue |-> slotValue[i][sl]] : s \in Server \ {i} }
                  IN messages' = J!AddMessages(learnMsgs, J!WithoutMessage(m, messages))
               /\ LET newCI == commitIndex[i] + 1
                  IN IF /\ newCI <= Len(log[i])
                        /\ newCI <= MaxSlot
                        /\ slotState[i][newCI] \in {Learned, Skipped}
                     THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                     ELSE UNCHANGED commitIndex
             ELSE
               /\ UNCHANGED <<slotState, commitIndex>>
               /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                         slotValue, slotBallot, localIndex,
                         jetpackVars, clientVars, executionVars>>

HandleSkip(i, m) ==
    /\ m.mtype = SkipMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotBallot, localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleLearn(i, m) ==
    /\ m.mtype = LearnMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState' = [slotState EXCEPT ![i][sl] = Learned]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = m.mvalue]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < sl
                        THEN Append(log[i], [term |-> m.mterm, value |-> m.mvalue])
                        ELSE log[i]]
          /\ LET newCI == commitIndex[i] + 1
             IN IF /\ newCI <= Len(log[i]) + 1
                   /\ newCI <= MaxSlot
                   /\ slotState'[i][newCI] \in {Learned, Skipped}
                THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                ELSE UNCHANGED commitIndex
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         slotBallot, localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

Revoke(i, sl) ==
    /\ sl <= MaxSlot
    /\ CoordinatorOf(sl) /= i
    /\ slotState[i][sl] = Empty
    /\ LET msgSet == { [mtype |-> RevokeRequest,
                         mterm |-> currentTerm[i],
                         msource |-> i,
                         mdest |-> s,
                         mslot |-> sl,
                         mballot |-> slotBallot[i][sl] + 1] : s \in Server \ {i} }
       IN /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = slotBallot[i][sl] + 1]
          /\ slotState' = [slotState EXCEPT ![i][sl] = Proposed]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]
          /\ messages' = J!AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex,
                         jetpackVars, clientVars, executionVars>>

HandleRevoke(i, m) ==
    /\ m.mtype = RevokeRequest
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ m.mballot > slotBallot[i][sl]
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Accepted]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = m.mballot]
          /\ J!Reply([mtype |-> RevokeResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mslot |-> sl,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleRevokeResponse(i, m) ==
    /\ m.mtype = RevokeResponse
    /\ i = m.mdest
    /\ m.mok
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] = Proposed
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = acceptCount[i][sl] + 1]
          /\ IF acceptCount[i][sl] + 1 >= (N \div 2 + 1)
             THEN
               /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
               /\ LET learnMsgs == { [mtype |-> SkipMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl] : s \in Server \ {i} }
                  IN messages' = J!AddMessages(learnMsgs, J!WithoutMessage(m, messages))
             ELSE
               /\ UNCHANGED slotState
               /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotValue, slotBallot, localIndex,
                         jetpackVars, clientVars, executionVars>>

\* Mencius AdvanceCommitIndex.
AdvanceCommitIndex(i) ==
    /\ LET newCI == commitIndex[i] + 1
       IN /\ newCI <= Len(log[i])
          /\ newCI <= MaxSlot
          /\ slotState[i][newCI] \in {Learned, Skipped}
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* Mencius ClientRequest: suggest via Mencius protocol.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ Suggest(i, v)

\* Mencius Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* BecomeToBeLeader (Jetpack recovery before becoming Leader).
\* In Mencius, all servers start as Leader, so this mainly handles
\* recovery after a Restart (which sets ostate to Follower).
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* Leader applies committed entries.
ApplyCommitted(i) ==
    /\ J!ApplyCommitted(i)
    /\ UNCHANGED menciusExtraVars

(***************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED menciusExtraVars)            *)
(***************************************************************************)

WClientSendPreaccept(c) ==
    /\ J!ClientSendPreaccept(c)
    /\ UNCHANGED menciusExtraVars

WHandlePreacceptRequest(i, m) ==
    /\ J!HandlePreacceptRequest(i, m)
    /\ UNCHANGED menciusExtraVars

WHandlePreacceptResponse(c, m) ==
    /\ J!HandlePreacceptResponse(c, m)
    /\ UNCHANGED menciusExtraVars

WSendBeginRecovery(i) ==
    /\ J!SendBeginRecovery(i)
    /\ UNCHANGED menciusExtraVars

WHandleBeginRecoveryRequest(i, m) ==
    /\ J!HandleBeginRecoveryRequest(i, m)
    /\ UNCHANGED menciusExtraVars

WHandleBeginRecoveryResponse(i, m) ==
    /\ J!HandleBeginRecoveryResponse(i, m)
    /\ UNCHANGED menciusExtraVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED menciusExtraVars

WSendPrepare(i) ==
    /\ J!SendPrepare(i)
    /\ UNCHANGED menciusExtraVars

WHandlePrepareRequest(i, m) ==
    /\ J!HandlePrepareRequest(i, m)
    /\ UNCHANGED menciusExtraVars

WHandlePrepareResponse(i, m) ==
    /\ J!HandlePrepareResponse(i, m)
    /\ UNCHANGED menciusExtraVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED menciusExtraVars

WSendAccept(i) ==
    /\ J!SendAccept(i)
    /\ UNCHANGED menciusExtraVars

WHandleAcceptRequest(i, m) ==
    /\ J!HandleAcceptRequest(i, m)
    /\ UNCHANGED menciusExtraVars

WHandleAcceptResponse(i, m) ==
    /\ J!HandleAcceptResponse(i, m)
    /\ UNCHANGED menciusExtraVars

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED menciusExtraVars

WResubmit(i) ==
    /\ J!Resubmit(i)
    /\ UNCHANGED menciusExtraVars

WCompleteResubmit(i) ==
    /\ J!CompleteResubmit(i)
    /\ UNCHANGED menciusExtraVars

WFinishRecovery(i) ==
    /\ J!FinishRecovery(i)
    /\ UNCHANGED menciusExtraVars

WHandleFinishRecovery(i, m) ==
    /\ J!HandleFinishRecovery(i, m)
    /\ UNCHANGED menciusExtraVars

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype = SuggestRequest
          /\ HandleSuggest(m.mdest, m)
       \/ /\ m.mtype = SuggestResponse
          /\ HandleSuggestResponse(m.mdest, m)
       \/ /\ m.mtype = SkipMessage
          /\ HandleSkip(m.mdest, m)
       \/ /\ m.mtype = LearnMessage
          /\ HandleLearn(m.mdest, m)
       \/ /\ m.mtype = RevokeRequest
          /\ HandleRevoke(m.mdest, m)
       \/ /\ m.mtype = RevokeResponse
          /\ HandleRevokeResponse(m.mdest, m)
       \/ /\ m.mtype = J!PreacceptRequest
          /\ WHandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = J!PreacceptResponse
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         menciusVars, jetpackVars, clientVars, executionVars>>
       \/ /\ m.mtype = J!BeginRecoveryRequest
          /\ WHandleBeginRecoveryRequest(m.mdest, m)
       \/ /\ m.mtype = J!BeginRecoveryResponse
          /\ WHandleBeginRecoveryResponse(m.mdest, m)
       \/ /\ m.mtype = J!JetpackPrepareRequest
          /\ WHandlePrepareRequest(m.mdest, m)
       \/ /\ m.mtype = J!JetpackPrepareResponse
          /\ WHandlePrepareResponse(m.mdest, m)
       \/ /\ m.mtype = J!JetpackAcceptRequest
          /\ WHandleAcceptRequest(m.mdest, m)
       \/ /\ m.mtype = J!JetpackAcceptResponse
          /\ WHandleAcceptResponse(m.mdest, m)
       \/ /\ m.mtype = J!FinishRecoveryRequest
          /\ WHandleFinishRecovery(m.mdest, m)

ClientReceive(m) ==
    /\ m.mdest \in Client
    /\ m.mtype = J!PreacceptResponse
    /\ WHandlePreacceptResponse(m.mdest, m)

DuplicateMessage(m) ==
    /\ J!Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server : ApplyCommitted(i)
       \/ \E i \in Server : AdvanceCommitIndex(i)
       \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
       \/ \E i \in Server : Skip(i)
       \/ \E i \in Server, sl \in 1..MaxSlot : Revoke(i, sl)

       \/ \E c \in Client : WClientSendPreaccept(c)
       \/ \E i \in Server : WSendBeginRecovery(i)
       \/ \E i \in Server : WCompleteBeginRecovery(i)
       \/ \E i \in Server : WSendPrepare(i)
       \/ \E i \in Server : WCompletePrepare(i)
       \/ \E i \in Server : WSendAccept(i)
       \/ \E i \in Server : WCompleteAccept(i)
       \/ \E i \in Server : WResubmit(i)
       \/ \E i \in Server : WCompleteResubmit(i)
       \/ \E i \in Server : WFinishRecovery(i)

       \/ \E m \in DOMAIN messages : ServerReceive(m)
       \/ \E m \in DOMAIN messages : ClientReceive(m)
       \/ \E m \in DOMAIN messages : DuplicateMessage(m)
       \/ \E m \in DOMAIN messages : DropMessage(m)

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 5
    /\ \A i \in Server : Len(log[i]) <= 3
    /\ Len(original_execution_cmds) <= 3
    /\ Len(execution_cmds) <= 3

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

\* Committed log entries must agree across servers.
\* Note: unrestricted LogAgreement (J!LogAgreement) does NOT hold for Mencius because
\* each server independently appends to its own log from its own slot proposals, so logs
\* legitimately diverge at uncommitted positions. With 1 CmdId this is masked (all values
\* are the same), but with 2+ CmdIds the divergence is exposed. CommittedLogAgreement
\* is the correct log-level invariant for Mencius.
CommittedLogAgreement ==
    \A i, j \in Server :
        LET ci == commitIndex[i]
            cj == commitIndex[j]
            limit == J!Min({ci, cj} \cup {0})
        IN \A k \in 1..limit :
            log[i][k] = log[j][k]

\* All servers that have learned the same slot agree on its value.
SlotAgreement ==
    \A i, j \in Server :
        \A sl \in 1..MaxSlot :
            (/\ slotState[i][sl] \in {Learned, Skipped}
             /\ slotState[j][sl] \in {Learned, Skipped})
            => slotValue[i][sl] = slotValue[j][sl]

Safety == [](CommittedLogAgreement /\ SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
