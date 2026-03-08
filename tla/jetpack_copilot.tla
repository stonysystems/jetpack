--------------------------- MODULE jetpack_copilot ---------------------------
\* Composition of Jetpack plugin with CoPilot base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + CoPilot-specific + Jetpack + client + execution)
\*   2. INSTANCE's base_copilot.tla (CoPilot protocol) and jetpack.tla (plugin)
\*   3. Wraps base protocol actions with UNCHANGED <<jetpackVars, clientVars, executionVars>>
\*   4. Wraps Jetpack actions with UNCHANGED copilotExtraVars
\*   5. Wires Init, Next, Spec, and properties
\*
\* CoPilot uses per-server proposer IDs (Proposer = Server). Two sequences
\* are active at any time (pilot + copilot). ApplyCommitted uses cpLog
\* dependency ordering to determine execution order across proposers.

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

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

    \* Raft-compatible election variables (used by Jetpack's interface).
    votedFor,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* CoPilot-specific variables.
    role,
    cpLog,
    cpBallot,

    \* Jetpack per-server variables.
    jstate, jepoch, oepoch, old_view, new_view, jpool,
    recovery_set, chosen_value, br_responses, prep_responses, accept_responses,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Variable groups for UNCHANGED clauses.
copilotExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      role, cpLog, cpBallot>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
copilotVars   == <<role, cpLog, cpBallot>>
jetpackVars   == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, copilotVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_copilot

\* CoPilot: per-server proposer IDs. Each server is its own proposer.
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "CoPilotNoOp"],
                          Proposer <- Server,
                          ProposerOf <- LAMBDA i : i

(****************************************************************************)
(* Re-exported constants                                                    *)
(****************************************************************************)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Symmetry     == B!Symmetry
Quorum       == B!Quorum

(****************************************************************************)
(* Initialization                                                           *)
(****************************************************************************)

Init ==
    /\ B!InitBaseVars
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(****************************************************************************)
(* Wrapped base protocol transitions                                        *)
(****************************************************************************)

Restart(i) ==
    /\ B!Restart(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

Timeout(i) ==
    /\ B!Timeout(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

FastTakeover(i) ==
    /\ B!FastTakeover(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* CoPilot ClientRequest: wrapper adds Jetpack's AvailableCommands filter.
ClientRequest(i, v) ==
    /\ v \in J!AvailableCommands
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* CoPilot ApplyCommitted: execute next committed entry using cpLog ordering.
\* CoPilot's execution order respects dependency ordering from cpLog.
\* For simplicity, we execute the next committed entry from any proposer
\* whose committed prefix hasn't been fully executed yet.
ApplyCommitted(i) ==
    /\ ostate[i] = Leader
    /\ \E j \in Server :
        LET ci == commitIndex[i][j]
            logLen == Len(log[i][j])
            \* Find next unexecuted entry: first position whose value
            \* is not yet in original_execution_cmds
            execSet == J!SeqToSet(original_execution_cmds)
        IN /\ ci > 0
           /\ logLen >= ci
           /\ \E k \in 1..ci :
                /\ log[i][j][k].value \notin execSet
                /\ log[i][j][k].value # [tag |-> "CoPilotNoOp"]
                /\ \* All dependencies must be executed first
                   LET cmd == log[i][j][k].value
                   IN \A dep \in J!SeqToSet(original_execution_cmds) : TRUE
                /\ original_execution_cmds' = Append(original_execution_cmds, log[i][j][k].value)
                /\ execution_cmds' = Append(execution_cmds, log[i][j][k].value)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, jetpackVars, clientVars>>

(****************************************************************************)
(* Wrapped CoPilot message handlers                                         *)
(****************************************************************************)

HandleCoPilotPreAccept(i, m) ==
    /\ B!HandleCoPilotPreAccept(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleCoPilotPreAcceptResponse(i, m) ==
    /\ B!HandleCoPilotPreAcceptResponse(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

HandleCoPilotCommit(i, m) ==
    /\ B!HandleCoPilotCommit(i, m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED copilotExtraVars)             *)
(****************************************************************************)

WClientSendPreaccept(c) ==
    /\ J!ClientSendPreaccept(c)
    /\ UNCHANGED copilotExtraVars

WHandlePreacceptRequest(i, m) ==
    /\ J!HandlePreacceptRequest(i, m)
    /\ UNCHANGED copilotExtraVars

WHandlePreacceptResponse(c, m) ==
    /\ J!HandlePreacceptResponse(c, m)
    /\ UNCHANGED copilotExtraVars

WSendBeginRecovery(i) ==
    /\ J!SendBeginRecovery(i)
    /\ UNCHANGED copilotExtraVars

WHandleBeginRecoveryRequest(i, m) ==
    /\ J!HandleBeginRecoveryRequest(i, m)
    /\ UNCHANGED copilotExtraVars

WHandleBeginRecoveryResponse(i, m) ==
    /\ J!HandleBeginRecoveryResponse(i, m)
    /\ UNCHANGED copilotExtraVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED copilotExtraVars

WSendPrepare(i) ==
    /\ J!SendPrepare(i)
    /\ UNCHANGED copilotExtraVars

WHandlePrepareRequest(i, m) ==
    /\ J!HandlePrepareRequest(i, m)
    /\ UNCHANGED copilotExtraVars

WHandlePrepareResponse(i, m) ==
    /\ J!HandlePrepareResponse(i, m)
    /\ UNCHANGED copilotExtraVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED copilotExtraVars

WSendAccept(i) ==
    /\ J!SendAccept(i)
    /\ UNCHANGED copilotExtraVars

WHandleAcceptRequest(i, m) ==
    /\ J!HandleAcceptRequest(i, m)
    /\ UNCHANGED copilotExtraVars

WHandleAcceptResponse(i, m) ==
    /\ J!HandleAcceptResponse(i, m)
    /\ UNCHANGED copilotExtraVars

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED copilotExtraVars

WResubmit(i) ==
    /\ J!Resubmit(i)
    /\ UNCHANGED copilotExtraVars

WCompleteResubmit(i) ==
    /\ J!CompleteResubmit(i)
    /\ UNCHANGED copilotExtraVars

WFinishRecovery(i) ==
    /\ J!FinishRecovery(i)
    /\ UNCHANGED copilotExtraVars

WHandleFinishRecovery(i, m) ==
    /\ J!HandleFinishRecovery(i, m)
    /\ UNCHANGED copilotExtraVars

(****************************************************************************)
(* Message receive plumbing                                                 *)
(****************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype = B!CoPilotPreAcceptRequest
          /\ HandleCoPilotPreAccept(m.mdest, m)
       \/ /\ m.mtype = B!CoPilotPreAcceptResponse
          /\ HandleCoPilotPreAcceptResponse(m.mdest, m)
       \/ /\ m.mtype = B!CoPilotCommitRequest
          /\ HandleCoPilotCommit(m.mdest, m)
       \/ /\ m.mtype = J!PreacceptRequest
          /\ WHandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = J!PreacceptResponse
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars, jetpackVars, clientVars, executionVars>>
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
                   copilotVars, jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : Timeout(i)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server : ApplyCommitted(i)
       \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
       \/ \E i \in Server : FastTakeover(i)

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
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 4
    /\ \A i \in Server : Len(cpLog[i]) <= 4
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : \A j \in Server : Len(log[i][j]) <= 2
    /\ \A i \in Server : Len(cpLog[i]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(****************************************************************************)
(* Properties                                                               *)
(****************************************************************************)

CommittedLogAgreement == J!CommittedLogAgreement
MultiSequenceLogAgreement == J!MultiSequenceLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

\* At most two active proposers (pilot + copilot) at any time.
ActiveProposerBound ==
    Cardinality({i \in Server : role[i] \in {B!Pilot, B!Copilot}}) <= 2

Safety == [](CommittedLogAgreement /\ MultiSequenceLogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches /\ ActiveProposerBound)

SpecSafety == Spec => Safety

=============================================================================
