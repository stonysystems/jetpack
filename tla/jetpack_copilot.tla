--------------------------- MODULE jetpack_copilot ---------------------------
\* Composition of Jetpack plugin with CoPilot base protocol.
\*
\* This wrapper module:
\*   1. Declares all variables (shared + CoPilot-specific)
\*   2. INSTANCE's jetpack.tla (maps shared variables)
\*   3. Defines CoPilot-specific actions inline
\*   4. Wraps J!<action> with UNCHANGED copilotVars for Jetpack actions
\*   5. Wires Init, Next, Spec, and properties
\*
\* CoPilot provides: dual-leader (pilot + copilot) replication with
\* dependency tracking and fast takeover.
\* Jetpack provides: fast-path preaccept with recovery on leader change.

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value for votedFor.
Nil == "Nil"
NilDep == [tag |-> "NilDep"]

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

    \* CoPilot-specific variables.
    role,
    cpLog,
    cpBallot,

    \* Jetpack per-server variables.
    jstate, jepoch, oepoch, old_view, new_view, jpool,
    recovery_set, chosen_value, br_responses, prep_responses, accept_responses,

    \* Client-side variables.
    client_view, client_pending, client_successes,

    \* Execution tracking.
    original_execution_cmds, execution_cmds

\* Protocol-specific variables (for UNCHANGED in Jetpack actions).
copilotExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      role, cpLog, cpBallot>>

\* Variable groups for actions' UNCHANGED clauses.
serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>
copilotVars == <<role, cpLog, cpBallot>>
jetpackVars == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                 recovery_set, chosen_value, br_responses,
                 prep_responses, accept_responses>>
clientVars == <<client_view, client_pending, client_successes>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, copilotVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* INSTANCE Jetpack module                                                 *)
(***************************************************************************)

J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "CoPilotNoOp"]

(***************************************************************************)
(* CoPilot helpers and constants                                           *)
(***************************************************************************)

Follower   == J!Follower
Candidate  == J!Candidate
ToBeLeader == J!ToBeLeader
Leader     == J!Leader

\* CoPilot roles.
Pilot      == "Pilot"
Copilot    == "Copilot"
Acceptor   == "Acceptor"

\* CoPilot-specific entry states.
PreAccepted  == "PreAccepted"
Accepted     == "Accepted"
Committed    == "Committed"

\* CoPilot message types.
CoPilotPreAcceptRequest   == "CoPilotPreAcceptRequest"
CoPilotPreAcceptResponse  == "CoPilotPreAcceptResponse"
CoPilotAcceptRequest      == "CoPilotAcceptRequest"
CoPilotAcceptResponse     == "CoPilotAcceptResponse"
CoPilotCommitRequest      == "CoPilotCommitRequest"

CoPilotMessageTypes == {CoPilotPreAcceptRequest, CoPilotPreAcceptResponse,
                        CoPilotAcceptRequest, CoPilotAcceptResponse,
                        CoPilotCommitRequest}

Symmetry == Permutations(Server)

Quorum == J!Quorum

\* CoPilot helpers.
ServerSeq == CHOOSE f \in [1..Cardinality(Server) -> Server] :
                \A i, j \in 1..Cardinality(Server) : i /= j => f[i] /= f[j]

PilotOf(term) == ServerSeq[((term - 1) % Cardinality(Server)) + 1]
CopilotOf(term) == ServerSeq[(term % Cardinality(Server)) + 1]

IsPilotOrCopilot(i) == role[i] \in {Pilot, Copilot}

DepsFor(i, cmd) ==
    {k \in 1..Len(cpLog[i]) :
        /\ cpLog[i][k].cmd.key = cmd.key
        /\ cpLog[i][k].cmd /= cmd}

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
    \* CoPilot init.
    /\ role = [i \in Server |-> IF i = PilotOf(1) THEN Pilot
                                 ELSE IF i = CopilotOf(1) THEN Copilot
                                 ELSE Acceptor]
    /\ cpLog = [i \in Server |-> <<>>]
    /\ cpBallot = [i \in Server |-> 0]
    \* Jetpack init.
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(***************************************************************************)
(* CoPilot transitions (protocol-specific)                                 *)
(***************************************************************************)

\* A pilot or copilot proposes a command via CoPilot protocol.
Propose(i, v) ==
    /\ IsPilotOrCopilot(i)
    /\ v \in J!AvailableCommands
    /\ LET deps == DepsFor(i, v)
           newEntry == [cmd |-> v, deps |-> deps,
                        status |-> PreAccepted, ballot |-> cpBallot[i]]
           newLogEntry == [term |-> currentTerm[i], value |-> v]
           msgSet == { [mtype |-> CoPilotPreAcceptRequest,
                        mterm |-> currentTerm[i],
                        msource |-> i,
                        mdest |-> s,
                        mcmd |-> v,
                        mdeps |-> deps,
                        mballot |-> cpBallot[i],
                        mindex |-> Len(cpLog[i]) + 1] : s \in Server \ {i} }
       IN /\ cpLog' = [cpLog EXCEPT ![i] = Append(cpLog[i], newEntry)]
          /\ log' = [log EXCEPT ![i] = Append(log[i], newLogEntry)]
          /\ messages' = J!AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         role, cpBallot, jetpackVars, clientVars, executionVars>>

HandleCoPilotPreAccept(i, m) ==
    /\ m.mtype = CoPilotPreAcceptRequest
    /\ i = m.mdest
    /\ m.mballot >= cpBallot[i]
    /\ LET cmd == m.mcmd
           localDeps == DepsFor(i, cmd)
           unionDeps == m.mdeps \cup localDeps
           newEntry == [cmd |-> cmd, deps |-> unionDeps,
                        status |-> PreAccepted, ballot |-> m.mballot]
           newLogEntry == [term |-> m.mterm, value |-> cmd]
       IN /\ cpLog' = [cpLog EXCEPT ![i] =
                          IF Len(cpLog[i]) < m.mindex
                          THEN Append(cpLog[i], newEntry)
                          ELSE [cpLog[i] EXCEPT ![m.mindex] = newEntry]]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < m.mindex
                        THEN Append(log[i], newLogEntry)
                        ELSE log[i]]
          /\ cpBallot' = [cpBallot EXCEPT ![i] = m.mballot]
          /\ J!Reply([mtype |-> CoPilotPreAcceptResponse,
                      mterm |-> currentTerm[i],
                      msource |-> i,
                      mdest |-> m.msource,
                      mdeps |-> unionDeps,
                      mindex |-> m.mindex,
                      mok |-> TRUE],
                      m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         role, jetpackVars, clientVars, executionVars>>

HandleCoPilotPreAcceptResponse(i, m) ==
    /\ m.mtype = CoPilotPreAcceptResponse
    /\ i = m.mdest
    /\ m.mok
    /\ m.mindex <= Len(cpLog[i])
    /\ cpLog[i][m.mindex].status = PreAccepted
    /\ LET entry == cpLog[i][m.mindex]
           finalDeps == entry.deps \cup m.mdeps
           newEntry == [entry EXCEPT !.deps = finalDeps, !.status = Committed]
       IN /\ cpLog' = [cpLog EXCEPT ![i][m.mindex] = newEntry]
          /\ commitIndex' = [commitIndex EXCEPT ![i] =
                               J!Max({commitIndex[i], m.mindex})]
          /\ LET commitMsgs == { [mtype |-> CoPilotCommitRequest,
                                  mterm |-> currentTerm[i],
                                  msource |-> i,
                                  mdest |-> s,
                                  mcmd |-> entry.cmd,
                                  mdeps |-> finalDeps,
                                  mindex |-> m.mindex] : s \in Server \ {i} }
             IN messages' = J!AddMessages(commitMsgs, J!WithoutMessage(m, messages))
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                         role, cpBallot, jetpackVars, clientVars, executionVars>>

HandleCoPilotCommit(i, m) ==
    /\ m.mtype = CoPilotCommitRequest
    /\ i = m.mdest
    /\ LET cmd == m.mcmd
           newEntry == [cmd |-> cmd, deps |-> m.mdeps,
                        status |-> Committed, ballot |-> cpBallot[i]]
           newLogEntry == [term |-> m.mterm, value |-> cmd]
       IN /\ cpLog' = [cpLog EXCEPT ![i] =
                          IF Len(cpLog[i]) < m.mindex
                          THEN Append(cpLog[i], newEntry)
                          ELSE [cpLog[i] EXCEPT ![m.mindex] = newEntry]]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < m.mindex
                        THEN Append(log[i], newLogEntry)
                        ELSE log[i]]
          /\ commitIndex' = [commitIndex EXCEPT ![i] =
                               J!Max({commitIndex[i], m.mindex})]
          /\ J!Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         role, cpBallot, jetpackVars, clientVars, executionVars>>

\* Fast takeover: copilot takes over pilot role, becomes ToBeLeader
\* for Jetpack recovery before becoming full Leader.
FastTakeover(i) ==
    /\ role[i] = Copilot
    /\ role' = [role EXCEPT ![i] = Pilot]
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, leaderVars,
                   logVars, cpLog, cpBallot, jetpackVars, clientVars, executionVars>>

\* CoPilot-compatible Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ role' = [role EXCEPT ![i] = Acceptor]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   cpLog, cpBallot, jetpackVars, clientVars, executionVars>>

\* Election timeout.
Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, copilotVars,
                   jetpackVars, clientVars, executionVars>>

\* Candidate transitions to ToBeLeader (Jetpack recovery must finish first).
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ role' = [j \in Server |-> IF j = i THEN Pilot
                                  ELSE IF role[j] = Pilot THEN Copilot
                                  ELSE role[j]]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   cpLog, cpBallot, jetpackVars, clientVars, executionVars>>

\* CoPilot ClientRequest: propose via CoPilot protocol.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ Propose(i, v)

\* Leader applies committed entries via Raft-compatible log.
ApplyCommitted(i) ==
    /\ J!ApplyCommitted(i)
    /\ UNCHANGED copilotExtraVars

(***************************************************************************)
(* Wrapped Jetpack transitions (add UNCHANGED copilotExtraVars)            *)
(***************************************************************************)

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

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype = CoPilotPreAcceptRequest
          /\ HandleCoPilotPreAccept(m.mdest, m)
       \/ /\ m.mtype = CoPilotPreAcceptResponse
          /\ HandleCoPilotPreAcceptResponse(m.mdest, m)
       \/ /\ m.mtype = CoPilotCommitRequest
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

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

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
    /\ \A i \in Server : Len(log[i]) <= 4
    /\ \A i \in Server : Len(cpLog[i]) <= 4
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ \A i \in Server : Len(cpLog[i]) <= 2
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

CommittedLogAgreement == J!CommittedLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches == J!ExecutionDedupMatches

\* At most two active proposers (pilot + copilot) at any time.
ActiveProposerBound ==
    Cardinality({i \in Server : role[i] \in {Pilot, Copilot}}) <= 2

Safety == [](CommittedLogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches /\ ActiveProposerBound)

SpecSafety == Spec => Safety

=============================================================================
