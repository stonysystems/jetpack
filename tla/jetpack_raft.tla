------------------------------- MODULE jetpack_raft -------------------------------
\* Composition of Jetpack plugin with Raft base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + Raft-specific)
\*   2. INSTANCE's jetpack.tla (maps shared variables)
\*   3. Defines Raft-specific actions inline
\*   4. Wraps J!<action> with UNCHANGED raftVars for Jetpack actions
\*   5. Wires Init, Next, Spec, and properties

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value for Raft votedFor.
Nil == "Nil"

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
    client_view, client_pending, client_successes,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Raft-specific variable tuple (for UNCHANGED in Jetpack actions).
raftVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex>>

\* Variable groups for Raft actions' UNCHANGED clauses.
serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>
jetpackVars == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                 recovery_set, chosen_value, br_responses,
                 prep_responses, accept_responses>>
clientVars == <<client_view, client_pending, client_successes>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* INSTANCE Jetpack module                                                 *)
(***************************************************************************)

J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "RaftNoOp"]

(***************************************************************************)
(* Raft helpers and constants                                              *)
(***************************************************************************)

Follower   == J!Follower
Candidate  == J!Candidate
ToBeLeader == J!ToBeLeader
Leader     == J!Leader

\* Raft message types.
RequestVoteRequest   == "RequestVoteRequest"
RequestVoteResponse  == "RequestVoteResponse"
AppendEntriesRequest == "AppendEntriesRequest"
AppendEntriesResponse == "AppendEntriesResponse"

RaftMessageTypes == {RequestVoteRequest, RequestVoteResponse,
                     AppendEntriesRequest, AppendEntriesResponse}

Symmetry == Permutations(Server)

Quorum == J!Quorum

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    /\ messages = [m \in {} |-> 0]
    /\ currentTerm = [i \in Server |-> 1]
    /\ ostate = [i \in Server |-> Follower]
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(***************************************************************************)
(* Raft transitions (protocol-specific)                                    *)
(***************************************************************************)

Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   jetpackVars, clientVars, executionVars>>

Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, jetpackVars, clientVars, executionVars>>

RequestVote(i, j) ==
    /\ ostate[i] = Candidate
    /\ i /= j
    /\ j \notin votesResponded[i]
    /\ J!Send([mtype         |-> RequestVoteRequest,
               mterm         |-> currentTerm[i],
               mlastLogTerm  |-> LastTerm(log[i]),
               mlastLogIndex |-> Len(log[i]),
               msource       |-> i,
               mdest         |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars, executionVars>>

AppendEntries(i, j) ==
    /\ i /= j
    /\ ostate[i] = Leader
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm == IF prevLogIndex > 0 THEN
                              log[i][prevLogIndex].term
                          ELSE
                              0
           lastEntry == J!Min({Len(log[i]), nextIndex[i][j]})
           entries == SubSeq(log[i], nextIndex[i][j], lastEntry)
       IN J!Send([mtype          |-> AppendEntriesRequest,
                  mterm          |-> currentTerm[i],
                  mprevLogIndex  |-> prevLogIndex,
                  mprevLogTerm   |-> prevLogTerm,
                  mentries       |-> entries,
                  mlog           |-> log[i],
                  mcommitIndex   |-> J!Min({commitIndex[i], lastEntry}),
                  msource        |-> i,
                  mdest          |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars, executionVars>>

\* Candidate transitions to ToBeLeader; Jetpack recovery must finish
\* before the node becomes Leader.
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ v \in J!Commands
    /\ LET entry == [term |-> currentTerm[i], value |-> v]
       IN log' = [log EXCEPT ![i] = Append(log[i], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ ostate[i] = Leader
    /\ LET Agree(index) == {i} \cup {k \in Server : matchIndex[i][k] >= index}
           agreeIndexes == {index \in 1..Len(log[i]) : Agree(index) \in Quorum}
           newCommitIndex ==
              IF /\ agreeIndexes /= {}
                 /\ log[i][J!Max(agreeIndexes)].term = currentTerm[i]
              THEN
                  J!Max(agreeIndexes)
              ELSE
                  commitIndex[i]
       IN commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   jetpackVars, clientVars, executionVars>>

\* Leader executes the next committed log entry.
ApplyCommitted(i) ==
    /\ J!ApplyCommitted(i)
    /\ UNCHANGED raftVars

HandleRequestVoteRequest(i, j, m) ==
    LET logOk == \/ m.mlastLogTerm > LastTerm(log[i])
                 \/ /\ m.mlastLogTerm = LastTerm(log[i])
                    /\ m.mlastLogIndex >= Len(log[i])
        grant == /\ m.mterm = currentTerm[i]
                 /\ logOk
                 /\ votedFor[i] \in {Nil, j}
    IN /\ m.mterm <= currentTerm[i]
       /\ \/ grant  /\ votedFor' = [votedFor EXCEPT ![i] = j]
          \/ ~grant /\ UNCHANGED votedFor
       /\ J!Reply([mtype        |-> RequestVoteResponse,
                   mterm        |-> currentTerm[i],
                   mvoteGranted |-> grant,
                   mlog         |-> log[i],
                   msource      |-> i,
                   mdest        |-> j],
                   m)
       /\ UNCHANGED <<ostate, currentTerm, candidateVars, leaderVars, logVars,
                      jetpackVars, clientVars, executionVars>>

HandleRequestVoteResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] =
                              votesResponded[i] \cup {j}]
    /\ \/ /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] =
                                  votesGranted[i] \cup {j}]
       \/ /\ ~m.mvoteGranted
          /\ UNCHANGED votesGranted
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, leaderVars, logVars, jetpackVars, clientVars, executionVars>>

HandleAppendEntriesRequest(i, j, m) ==
    LET logOk == \/ m.mprevLogIndex = 0
                 \/ /\ m.mprevLogIndex > 0
                    /\ m.mprevLogIndex <= Len(log[i])
                    /\ m.mprevLogTerm = log[i][m.mprevLogIndex].term
    IN /\ m.mterm <= currentTerm[i]
       /\ \/ /\ \* reject request
                \/ m.mterm < currentTerm[i]
                \/ /\ m.mterm = currentTerm[i]
                   /\ ostate[i] = Follower
                   /\ \lnot logOk
             /\ J!Reply([mtype       |-> AppendEntriesResponse,
                         mterm       |-> currentTerm[i],
                         msuccess    |-> FALSE,
                         mmatchIndex |-> 0,
                         msource     |-> i,
                         mdest       |-> j],
                         m)
             /\ UNCHANGED <<serverVars, logVars>>
          \/ \* return to follower state
             /\ m.mterm = currentTerm[i]
             /\ ostate[i] \in {Candidate, ToBeLeader}
             /\ ostate' = [ostate EXCEPT ![i] = Follower]
             /\ UNCHANGED <<currentTerm, votedFor, logVars, messages>>
          \/ \* accept request
             /\ m.mterm = currentTerm[i]
             /\ ostate[i] = Follower
             /\ logOk
             /\ LET index == m.mprevLogIndex + 1
                IN \/ \* already done with request
                       /\ \/ m.mentries = <<>>
                          \/ /\ m.mentries /= <<>>
                             /\ Len(log[i]) >= index
                             /\ log[i][index].term = m.mentries[1].term
                       /\ commitIndex' = [commitIndex EXCEPT ![i] =
                                              m.mcommitIndex]
                       /\ J!Reply([mtype       |-> AppendEntriesResponse,
                                   mterm       |-> currentTerm[i],
                                   msuccess    |-> TRUE,
                                   mmatchIndex |-> m.mprevLogIndex +
                                                   Len(m.mentries),
                                   msource     |-> i,
                                   mdest       |-> j],
                                   m)
                       /\ UNCHANGED <<serverVars, log>>
                   \/ \* conflict: remove 1 entry
                       /\ m.mentries /= <<>>
                       /\ Len(log[i]) >= index
                       /\ log[i][index].term /= m.mentries[1].term
                       /\ LET new == [index2 \in 1..(Len(log[i]) - 1) |->
                                          log[i][index2]]
                          IN log' = [log EXCEPT ![i] = new]
                       /\ UNCHANGED <<serverVars, commitIndex, messages>>
                   \/ \* no conflict: append entry
                       /\ m.mentries /= <<>>
                       /\ Len(log[i]) = m.mprevLogIndex
                       /\ log' = [log EXCEPT ![i] =
                                      Append(log[i], m.mentries[1])]
                       /\ UNCHANGED <<serverVars, commitIndex, messages>>
       /\ UNCHANGED <<candidateVars, leaderVars, jetpackVars, clientVars, executionVars>>

HandleAppendEntriesResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ \/ /\ m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] = m.mmatchIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mmatchIndex]
       \/ /\ \lnot m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
                               J!Max({nextIndex[i][j] - 1, 1})]
          /\ UNCHANGED <<matchIndex>>
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, logVars, jetpackVars, clientVars, executionVars>>

UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars, executionVars>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars, executionVars>>

RaftReceive(m) ==
    LET i == m.mdest
        j == m.msource
    IN \/ UpdateTerm(i, j, m)
       \/ /\ m.mtype = RequestVoteRequest
          /\ HandleRequestVoteRequest(i, j, m)
       \/ /\ m.mtype = RequestVoteResponse
          /\ \/ DropStaleResponse(i, j, m)
             \/ HandleRequestVoteResponse(i, j, m)
       \/ /\ m.mtype = AppendEntriesRequest
          /\ HandleAppendEntriesRequest(i, j, m)
       \/ /\ m.mtype = AppendEntriesResponse
          /\ \/ DropStaleResponse(i, j, m)
             \/ HandleAppendEntriesResponse(i, j, m)

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
    /\ \/ /\ m.mtype \in RaftMessageTypes
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
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

Safety == [](CommittedLogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
