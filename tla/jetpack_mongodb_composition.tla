-------------------------- MODULE jetpack_mongodb_composition --------------------------
\* Composition of Jetpack plugin with MongoDB base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + MongoDB-specific + Jetpack + client + execution)
\*   2. INSTANCE's base_mongodb.tla (MongoDB protocol) and jetpack.tla (plugin)
\*   3. Wraps base protocol actions with UNCHANGED <<jetpackVars, clientVars, executionVars>>
\*   4. Wraps Jetpack actions with UNCHANGED mongodbVars
\*   5. Wires Init, Next, Spec, and properties
\*
\* Like Raft, MongoDB uses a single replication stream ("sole" proposer), so
\* ApplyCommitted walks the sole sequence in order.

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

    \* MongoDB-specific variables.
    votedFor,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* Jetpack per-server variables.
    jstate, jepoch, oepoch, old_view, new_view, jpool,
    recovery_set, chosen_value, br_responses, prep_responses, accept_responses,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Variable groups for UNCHANGED clauses.
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
jetpackVars   == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_mongodb

\* MongoDB: single proposer "sole". ProposerOf maps every server to "sole".
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "MongoDbNoOp"],
                          Proposer <- {"sole"},
                          ProposerOf <- LAMBDA i : "sole"

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

RequestVote(i, j) ==
    /\ B!RequestVote(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AppendOplog(i, j) ==
    /\ B!AppendOplog(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RollbackOplog(i, j) ==
    /\ B!RollbackOplog(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

LearnCommitPoint(i, j) ==
    /\ B!LearnCommitPoint(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

EmptyViewChange(i) ==
    /\ B!EmptyViewChange(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* MongoDB ApplyCommitted: execute the next committed entry from the sole
\* sequence. Like Raft, MongoDB has only one proposer, so execution order
\* is simply log order.
ApplyCommitted(i) ==
    /\ ostate[i] = Leader
    /\ LET ci == commitIndex[i]["sole"]
           execIdx == Len(original_execution_cmds) + 1
       IN /\ execIdx <= ci
          /\ LET entry == log[i]["sole"][execIdx]
             IN /\ original_execution_cmds' = Append(original_execution_cmds, entry.value)
                /\ execution_cmds' = Append(execution_cmds, entry.value)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

(****************************************************************************)
(* Wrapped MongoDB message handlers                                         *)
(****************************************************************************)

MongoDbReceive(m) ==
    /\ B!MongoDbReceive(m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED mongodbVars)                  *)
(****************************************************************************)

WClientSendPreaccept(c) ==
    /\ J!ClientSendPreaccept(c)
    /\ UNCHANGED mongodbVars

WHandlePreacceptRequest(i, m) ==
    /\ J!HandlePreacceptRequest(i, m)
    /\ UNCHANGED mongodbVars

WHandlePreacceptResponse(c, m) ==
    /\ J!HandlePreacceptResponse(c, m)
    /\ UNCHANGED mongodbVars

WSendBeginRecovery(i) ==
    /\ J!SendBeginRecovery(i)
    /\ UNCHANGED mongodbVars

WHandleBeginRecoveryRequest(i, m) ==
    /\ J!HandleBeginRecoveryRequest(i, m)
    /\ UNCHANGED mongodbVars

WHandleBeginRecoveryResponse(i, m) ==
    /\ J!HandleBeginRecoveryResponse(i, m)
    /\ UNCHANGED mongodbVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED mongodbVars

WSendPrepare(i) ==
    /\ J!SendPrepare(i)
    /\ UNCHANGED mongodbVars

WHandlePrepareRequest(i, m) ==
    /\ J!HandlePrepareRequest(i, m)
    /\ UNCHANGED mongodbVars

WHandlePrepareResponse(i, m) ==
    /\ J!HandlePrepareResponse(i, m)
    /\ UNCHANGED mongodbVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED mongodbVars

WSendAccept(i) ==
    /\ J!SendAccept(i)
    /\ UNCHANGED mongodbVars

WHandleAcceptRequest(i, m) ==
    /\ J!HandleAcceptRequest(i, m)
    /\ UNCHANGED mongodbVars

WHandleAcceptResponse(i, m) ==
    /\ J!HandleAcceptResponse(i, m)
    /\ UNCHANGED mongodbVars

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED mongodbVars

WResubmit(i) ==
    /\ J!Resubmit(i)
    /\ UNCHANGED mongodbVars

WCompleteResubmit(i) ==
    /\ J!CompleteResubmit(i)
    /\ UNCHANGED mongodbVars

WFinishRecovery(i) ==
    /\ J!FinishRecovery(i)
    /\ UNCHANGED mongodbVars

WHandleFinishRecovery(i, m) ==
    /\ J!HandleFinishRecovery(i, m)
    /\ UNCHANGED mongodbVars

(****************************************************************************)
(* Message receive plumbing                                                 *)
(****************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype \in B!MongoDbMessageTypes
          /\ MongoDbReceive(m)
       \/ /\ m.mtype = J!PreacceptRequest
          /\ WHandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = J!PreacceptResponse
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         jetpackVars, clientVars, executionVars>>
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
                   jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : Timeout(i)
       \/ \E i, j \in Server : RequestVote(i, j)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server : EmptyViewChange(i)
       \/ \E i \in Server : AdvanceCommitIndex(i)
       \/ \E i \in Server : ApplyCommitted(i)
       \/ \E i, j \in Server : AppendOplog(i, j)
       \/ \E i, j \in Server : RollbackOplog(i, j)
       \/ \E i, j \in Server : LearnCommitPoint(i, j)
       \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)

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
    /\ \A i \in Server : Len(log[i]["sole"]) <= 4
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]["sole"]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(****************************************************************************)
(* Properties                                                               *)
(****************************************************************************)

CommittedLogAgreement == J!CommittedLogAgreement
MultiSequenceLogAgreement == J!MultiSequenceLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

Safety == [](CommittedLogAgreement /\ MultiSequenceLogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
