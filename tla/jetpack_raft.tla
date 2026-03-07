------------------------------- MODULE jetpack_raft -------------------------------
\* Composition of Jetpack plugin with Raft base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + Raft-specific + Jetpack + client + execution)
\*   2. INSTANCE's base_raft.tla (Raft protocol) and jetpack.tla (plugin)
\*   3. Wraps base protocol actions with UNCHANGED <<jetpackVars, clientVars, executionVars>>
\*   4. Wraps Jetpack actions with UNCHANGED raftVars
\*   5. Wires Init, Next, Spec, and properties

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

    \* Raft-specific variables.
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
raftVars      == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex>>
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

(***************************************************************************)
(* INSTANCE base protocol and Jetpack modules                              *)
(***************************************************************************)

B == INSTANCE base_raft

\* Raft: single proposer, all entries belong to one sequence.
\* The entry argument is ignored — Raft assigns all positions to "sole".
RaftProposerOfEntry(k, entry) == "sole"

J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "RaftNoOp"],
                          Proposer <- {"sole"},
                          ProposerOfEntry <- RaftProposerOfEntry

(***************************************************************************)
(* Re-exported constants                                                   *)
(***************************************************************************)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Symmetry     == B!Symmetry
Quorum       == B!Quorum

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

Timeout(i) ==
    /\ B!Timeout(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RequestVote(i, j) ==
    /\ B!RequestVote(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AppendEntries(i, j) ==
    /\ B!AppendEntries(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Leader executes the next committed log entry.
ApplyCommitted(i) ==
    /\ J!ApplyCommitted(i)
    /\ UNCHANGED raftVars

(***************************************************************************)
(* Wrapped Raft message handlers                                           *)
(***************************************************************************)

RaftReceive(m) ==
    /\ B!RaftReceive(m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED raftVars)                    *)
(***************************************************************************)

WClientSendPreaccept(c) ==
    /\ J!ClientSendPreaccept(c)
    /\ UNCHANGED raftVars

WHandlePreacceptRequest(i, m) ==
    /\ J!HandlePreacceptRequest(i, m)
    /\ UNCHANGED raftVars

WHandlePreacceptResponse(c, m) ==
    /\ J!HandlePreacceptResponse(c, m)
    /\ UNCHANGED raftVars

WSendBeginRecovery(i) ==
    /\ J!SendBeginRecovery(i)
    /\ UNCHANGED raftVars

WHandleBeginRecoveryRequest(i, m) ==
    /\ J!HandleBeginRecoveryRequest(i, m)
    /\ UNCHANGED raftVars

WHandleBeginRecoveryResponse(i, m) ==
    /\ J!HandleBeginRecoveryResponse(i, m)
    /\ UNCHANGED raftVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED raftVars

WSendPrepare(i) ==
    /\ J!SendPrepare(i)
    /\ UNCHANGED raftVars

WHandlePrepareRequest(i, m) ==
    /\ J!HandlePrepareRequest(i, m)
    /\ UNCHANGED raftVars

WHandlePrepareResponse(i, m) ==
    /\ J!HandlePrepareResponse(i, m)
    /\ UNCHANGED raftVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED raftVars

WSendAccept(i) ==
    /\ J!SendAccept(i)
    /\ UNCHANGED raftVars

WHandleAcceptRequest(i, m) ==
    /\ J!HandleAcceptRequest(i, m)
    /\ UNCHANGED raftVars

WHandleAcceptResponse(i, m) ==
    /\ J!HandleAcceptResponse(i, m)
    /\ UNCHANGED raftVars

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED raftVars

WResubmit(i) ==
    /\ J!Resubmit(i)
    /\ UNCHANGED raftVars

WCompleteResubmit(i) ==
    /\ J!CompleteResubmit(i)
    /\ UNCHANGED raftVars

WFinishRecovery(i) ==
    /\ J!FinishRecovery(i)
    /\ UNCHANGED raftVars

WHandleFinishRecovery(i, m) ==
    /\ J!HandleFinishRecovery(i, m)
    /\ UNCHANGED raftVars

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype \in B!RaftMessageTypes
          /\ RaftReceive(m)
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

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : Timeout(i)
       \/ \E i, j \in Server : RequestVote(i, j)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server : AdvanceCommitIndex(i)
       \/ \E i \in Server : ApplyCommitted(i)
       \/ \E i, j \in Server : AppendEntries(i, j)
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
    /\ \A i \in Server : Len(log[i]) <= 4
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

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

CommittedLogAgreement == J!CommittedLogAgreement
MultiSequenceLogAgreement == J!MultiSequenceLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

Safety == [](CommittedLogAgreement /\ MultiSequenceLogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
