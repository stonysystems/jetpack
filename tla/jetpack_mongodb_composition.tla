-------------------------- MODULE jetpack_mongodb_composition --------------------------
\* Composition of Jetpack plugin with MongoDB base protocol (with Raft
\* single-server reconfig).
\*
\* Jetpack recovery has two entry points, both routed through ostate=ToBeLeader:
\*   1. Election:   B!BecomeToBeLeader (Candidate -> ToBeLeader) +
\*                  J!SendBeginRecovery / ... / J!FinishRecovery.
\*   2. Reconfig:   B!BeginReconfig (Leader -> ToBeLeader, stage pendingConfig)
\*                  + J!SendBeginRecovery / ... / WFinishReconfig (inlines
\*                  the J!FinishRecovery body and additionally appends the
\*                  config entry, extends configs, clears pendingConfig).
\*
\* Recovery in the reconfig path runs in the OLD config: the new config entry
\* is not appended (and configs is not extended) until WFinishReconfig fires,
\* atomically with ostate ToBeLeader -> Leader.
\*
\* Wrapping pattern:
\*   - Base protocol actions wrapped with UNCHANGED <<jetpackVars, clientVars,
\*     executionVars>>.
\*   - Jetpack actions wrapped with UNCHANGED mongodbVars (which now includes
\*     configs and pendingConfig, so Jetpack does not touch them).
\*   - Reconfig finish lives at the composition level because it crosses the
\*     boundary (mutates log, configs, pendingConfig AND jetpack state).

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

    \* Reconfig variables (MongoDB-specific; Jetpack does not touch).
    configs,
    pendingConfig,

    \* Jetpack per-server variables.
    jstate, jepoch, oepoch, old_view, new_view, jpool,
    recovery_set, chosen_value, br_responses, prep_responses, accept_responses,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Variable groups for UNCHANGED clauses.
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                   configs, pendingConfig>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
configVars    == <<configs, pendingConfig>>
jetpackVars   == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, configVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_mongodb

\* MongoDB: single proposer "sole". ProposerOf maps every server to "sole".
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "MongoDbNoOp"],
                          InitialMembers <- Server,
                          Proposer <- {"sole"},
                          ProposerOf <- LAMBDA i : "sole"

(****************************************************************************)
(* Re-exported constants                                                    *)
(****************************************************************************)

Nil          == B!Nil
Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
Symmetry     == B!Symmetry

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

\* Election entry into recovery: Candidate -> ToBeLeader.
BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Reconfig entry into recovery: Leader -> ToBeLeader, stage pendingConfig.
\* The actual config entry is not appended until WFinishReconfig (below).
BeginReconfig(i, newConfig) ==
    /\ B!BeginReconfig(i, newConfig)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Apply the next committed log entry. MongoDB has a single proposer, so
\* execution order is simply log order.
ApplyCommitted(i) ==
    /\ ostate[i] = Leader
    /\ LET ci == commitIndex[i]["sole"]
           execIdx == Len(original_execution_cmds) + 1
       IN /\ execIdx <= ci
          /\ LET entry == log[i]["sole"][execIdx]
             IN /\ original_execution_cmds' = Append(original_execution_cmds, entry.value)
                /\ execution_cmds' = Append(execution_cmds, entry.value)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   configVars, jetpackVars, clientVars>>

(****************************************************************************)
(* Wrapped MongoDB message handlers                                         *)
(****************************************************************************)

MongoDbReceive(m) ==
    /\ B!MongoDbReceive(m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped Jetpack transitions (UNCHANGED mongodbVars now also covers       *)
(* configs and pendingConfig, so Jetpack actions cannot touch them).        *)
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

\* Election-path recovery completion: only fires when no reconfig is staged.
WFinishRecovery(i) ==
    /\ pendingConfig[i] = Nil
    /\ J!FinishRecovery(i)
    /\ UNCHANGED mongodbVars

WHandleFinishRecovery(i, m) ==
    /\ J!HandleFinishRecovery(i, m)
    /\ UNCHANGED mongodbVars

(****************************************************************************)
(* Reconfig-path recovery completion                                        *)
(*                                                                          *)
(* Inlines the body of J!FinishRecovery and additionally:                   *)
(*   - appends the new config entry to the leader's log                     *)
(*   - extends the configs sequence                                         *)
(*   - clears pendingConfig[i]                                              *)
(*                                                                          *)
(* Atomic with ostate ToBeLeader -> Leader, so client writes resume in the  *)
(* new config.                                                              *)
(****************************************************************************)

WFinishReconfig(i) ==
    /\ pendingConfig[i] /= Nil
    /\ jstate[i] = J!AfterResubmit
    /\ LET view == new_view[i]
           newCV == Len(configs) + 1
           configEntry == [term |-> currentTerm[i],
                           value |-> B!NilCmd,
                           configVersion |-> newCV]
           msgSet == { [mtype     |-> J!FinishRecoveryRequest,
                        moepoch   |-> oepoch[i],
                        mnew_view |-> view,
                        msource   |-> i,
                        mdest     |-> s] : s \in view.replica_ids }
       IN /\ messages' = J!AddMessages(msgSet, messages)
          \* Jetpack state cleanup (mirrors J!FinishRecovery body).
          /\ jepoch' = [jepoch EXCEPT ![i] = oepoch[i]]
          /\ oepoch' = [oepoch EXCEPT ![i] = oepoch[i]]
          /\ old_view' = [old_view EXCEPT ![i] = view]
          /\ new_view' = [new_view EXCEPT ![i] = view]
          /\ jpool' = [jpool EXCEPT ![i] = J!EmptyJPool]
          /\ jstate' = [jstate EXCEPT ![i] = J!Ready]
          /\ recovery_set' = [recovery_set EXCEPT ![i] = {}]
          /\ chosen_value' = [chosen_value EXCEPT ![i] = {}]
          /\ br_responses' = [br_responses EXCEPT ![i] =
                                  [s \in Server |-> J!NilJPool]]
          /\ prep_responses' = [prep_responses EXCEPT ![i] =
                                    [s \in Server |-> J!NilPrepResp]]
          /\ accept_responses' = [accept_responses EXCEPT ![i] =
                                      [s \in Server |-> FALSE]]
          \* Resume to Leader.
          /\ ostate' = [ostate EXCEPT ![i] = Leader]
          \* Append the new config entry and extend configs.
          /\ log' = [log EXCEPT ![i]["sole"] =
                         Append(log[i]["sole"], configEntry)]
          /\ configs' = Append(configs, pendingConfig[i])
          /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ UNCHANGED <<currentTerm, commitIndex, votedFor,
                   votesResponded, votesGranted, nextIndex, matchIndex,
                   clientVars, executionVars>>

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
                         configVars, jetpackVars, clientVars, executionVars>>
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
                   configVars, jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ J!Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   configVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : Timeout(i)
       \/ \E i, j \in Server : RequestVote(i, j)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server, c \in SUBSET Server : BeginReconfig(i, c)
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
       \/ \E i \in Server : WFinishReconfig(i)

       \/ \E m \in DOMAIN messages : ServerReceive(m)
       \/ \E m \in DOMAIN messages : ClientReceive(m)
       \/ \E m \in DOMAIN messages : DuplicateMessage(m)
       \/ \E m \in DOMAIN messages : DropMessage(m)

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 5
    /\ \A i \in Server : Len(log[i]["sole"]) <= 5
    /\ Len(original_execution_cmds) <= 5
    /\ Len(execution_cmds) <= 5
    /\ Len(configs) <= 2

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]["sole"]) <= 3
    /\ Len(original_execution_cmds) <= 3
    /\ Len(execution_cmds) <= 3
    /\ Len(configs) <= 2

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
