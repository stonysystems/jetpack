--------------------------- MODULE jetpack_mencius ---------------------------
\* Composition of Jetpack plugin with Mencius base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + Mencius-specific + Jetpack + client + execution)
\*   2. INSTANCE's base_mencius.tla (Mencius protocol) and jetpack.tla (plugin)
\*   3. Wraps base protocol actions with UNCHANGED <<jetpackVars, clientVars, executionVars>>
\*   4. Wraps Jetpack actions with UNCHANGED menciusExtraVars
\*   5. Wires Init, Next, Spec, and properties
\*
\* Mencius provides: multi-leader Paxos with round-robin slot assignment.
\* Jetpack provides: fast-path preaccept with recovery on leader change.

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

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
    client_view, client_pending, client_successes, client_heard_from,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Variable groups for UNCHANGED clauses.
menciusExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      slotState, slotValue, slotBallot, localIndex, acceptCount>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
menciusVars   == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>
jetpackVars   == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, menciusVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* INSTANCE base protocol and Jetpack modules                              *)
(***************************************************************************)

B == INSTANCE base_mencius

\* Mencius: N sequences via round-robin. Slot k's proposer is its coordinator.
\* The entry argument is ignored — Mencius assigns by position (round-robin).
MenciusProposerOfEntry(k, entry) == B!CoordinatorOf(k)

J == INSTANCE jetpack WITH NoOpCmd <- B!NoOp,
                          Proposer <- Server,
                          ProposerOfEntry <- MenciusProposerOfEntry

(***************************************************************************)
(* Re-exported constants                                                   *)
(***************************************************************************)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Symmetry     == B!Symmetry
Quorum       == B!Quorum
MaxSlot      == B!MaxSlot

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    /\ B!InitBaseVars
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(***************************************************************************)
(* Wrapped base protocol transitions                                       *)
(***************************************************************************)

Restart(i) ==
    /\ B!Restart(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Mencius ClientRequest: wrapper adds Jetpack's AvailableCommands filter.
ClientRequest(i, v) ==
    /\ v \in J!AvailableCommands
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

Skip(i) ==
    /\ B!Skip(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

Revoke(i, sl) ==
    /\ B!Revoke(i, sl)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Leader applies committed entries.
ApplyCommitted(i) ==
    /\ J!ApplyCommitted(i)
    /\ UNCHANGED menciusExtraVars

(***************************************************************************)
(* Wrapped Mencius message handlers                                        *)
(***************************************************************************)

HandleSuggest(i, m) ==
    /\ B!HandleSuggest(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleSuggestResponse(i, m) ==
    /\ B!HandleSuggestResponse(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleSkip(i, m) ==
    /\ B!HandleSkip(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleLearn(i, m) ==
    /\ B!HandleLearn(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleRevoke(i, m) ==
    /\ B!HandleRevoke(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleRevokeResponse(i, m) ==
    /\ B!HandleRevokeResponse(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

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

\* Minimal constraint for fast smoke testing (no restarts).
TinyStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 1
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

CommittedLogAgreement == J!CommittedLogAgreement
MultiSequenceLogAgreement == J!MultiSequenceLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

\* All servers that have learned the same slot agree on its value.
SlotAgreement ==
    \A i, j \in Server :
        \A sl \in 1..MaxSlot :
            (/\ slotState[i][sl] \in {B!Learned, B!Skipped}
             /\ slotState[j][sl] \in {B!Learned, B!Skipped})
            => slotValue[i][sl] = slotValue[j][sl]

Safety == [](CommittedLogAgreement /\ MultiSequenceLogAgreement /\ SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
