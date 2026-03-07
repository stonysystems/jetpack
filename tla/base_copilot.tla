--------------------------- MODULE base_copilot --------------------------------
\* CoPilot consensus protocol adapted for Jetpack composition.
\*
\* This module contains the CoPilot protocol state machine with the ToBeLeader
\* state (intercepted by Jetpack for recovery). It is designed to be
\* INSTANCE'd by a wrapper module that composes it with jetpack.tla.
\*
\* Key differences from standalone copilot.tla:
\*   - BecomeToBeLeader: Candidate -> ToBeLeader (not -> Leader)
\*   - FastTakeover transitions to ToBeLeader (not directly to Leader)
\*   - Propose uses v \in Commands (wrapper adds Jetpack's AvailableCommands filter)
\*   - No execution_cmds or ApplyCommitted (delegated to wrapper/Jetpack)
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex,
\*   role, cpLog, cpBallot

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilDep == [tag |-> "NilDep"]
NilCmd == [tag |-> "NilCmd"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* CoPilot roles.
Pilot    == "Pilot"
Copilot  == "Copilot"
Acceptor == "Acceptor"

\* CoPilot-specific entry states.
PreAccepted == "PreAccepted"
Accepted    == "Accepted"
Committed   == "Committed"

\* CoPilot message types.
CoPilotPreAcceptRequest   == "CoPilotPreAcceptRequest"
CoPilotPreAcceptResponse  == "CoPilotPreAcceptResponse"
CoPilotAcceptRequest      == "CoPilotAcceptRequest"
CoPilotAcceptResponse     == "CoPilotAcceptResponse"
CoPilotCommitRequest      == "CoPilotCommitRequest"

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,
    currentTerm,
    ostate,
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,
    role,
    cpLog,
    cpBallot

serverVars       == <<currentTerm, ostate, votedFor>>
candidateVars    == <<votesResponded, votesGranted>>
leaderVars       == <<nextIndex, matchIndex>>
logVars          == <<log, commitIndex>>
copilotVars      == <<role, cpLog, cpBallot>>
copilotExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      role, cpLog, cpBallot>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

Symmetry == Permutations(Server)

\* Canonical server sequence for role assignment.
ServerSeq == CHOOSE f \in [1..Cardinality(Server) -> Server] :
                \A i, j \in 1..Cardinality(Server) : i /= j => f[i] /= f[j]

PilotOf(term) == ServerSeq[((term - 1) % Cardinality(Server)) + 1]
CopilotOf(term) == ServerSeq[(term % Cardinality(Server)) + 1]

IsPilotOrCopilot(i) == role[i] \in {Pilot, Copilot}

DepsFor(i, cmd) ==
    {k \in 1..Len(cpLog[i]) :
        /\ cpLog[i][k].cmd.key = cmd.key
        /\ cpLog[i][k].cmd /= cmd}

\* Message bag helpers.
WithMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        [msgs EXCEPT ![m] = msgs[m] + 1]
    ELSE
        msgs @@ (m :> 1)

WithoutMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        IF msgs[m] <= 1 THEN [i \in DOMAIN msgs \ {m} |-> msgs[i]]
        ELSE [msgs EXCEPT ![m] = msgs[m] - 1]
    ELSE
        msgs

Send(m) == messages' = WithMessage(m, messages)
Discard(m) == messages' = WithoutMessage(m, messages)
Reply(response, request) ==
    messages' = WithoutMessage(request, WithMessage(response, messages))

RECURSIVE AddMessages(_,_)
AddMessages(ms, msgs) ==
    IF ms = {} THEN msgs
    ELSE LET m == CHOOSE x \in ms : TRUE
         IN AddMessages(ms \ {m}, WithMessage(m, msgs))

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

InitBaseVars ==
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
    /\ role = [i \in Server |-> IF i = PilotOf(1) THEN Pilot
                                 ELSE IF i = CopilotOf(1) THEN Copilot
                                 ELSE Acceptor]
    /\ cpLog = [i \in Server |-> <<>>]
    /\ cpBallot = [i \in Server |-> 0]

(***************************************************************************)
(* CoPilot transitions                                                     *)
(***************************************************************************)

\* A pilot or copilot proposes a command via CoPilot protocol.
\* Note: v \in Commands is a type guard only. The wrapper adds the Jetpack-aware
\* AvailableCommands filter (which also excludes commands in execution_cmds).
Propose(i, v) ==
    /\ IsPilotOrCopilot(i)
    /\ v \in Commands
    /\ LET deps == DepsFor(i, v)
           newEntry == [cmd |-> v, deps |-> deps,
                        status |-> PreAccepted, ballot |-> cpBallot[i]]
           newLogEntry == [term |-> currentTerm[i], value |-> v, proposer |-> i]
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
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         role, cpBallot>>

HandleCoPilotPreAccept(i, m) ==
    /\ m.mtype = CoPilotPreAcceptRequest
    /\ i = m.mdest
    /\ m.mballot >= cpBallot[i]
    /\ LET cmd == m.mcmd
           localDeps == DepsFor(i, cmd)
           unionDeps == m.mdeps \cup localDeps
           newEntry == [cmd |-> cmd, deps |-> unionDeps,
                        status |-> PreAccepted, ballot |-> m.mballot]
           newLogEntry == [term |-> m.mterm, value |-> cmd, proposer |-> m.msource]
       IN /\ cpLog' = [cpLog EXCEPT ![i] =
                          IF Len(cpLog[i]) < m.mindex
                          THEN Append(cpLog[i], newEntry)
                          ELSE [cpLog[i] EXCEPT ![m.mindex] = newEntry]]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < m.mindex
                        THEN Append(log[i], newLogEntry)
                        ELSE log[i]]
          /\ cpBallot' = [cpBallot EXCEPT ![i] = m.mballot]
          /\ Reply([mtype |-> CoPilotPreAcceptResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mdeps |-> unionDeps,
                    mindex |-> m.mindex,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex, role>>

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
                               Max({commitIndex[i], m.mindex})]
          /\ LET commitMsgs == { [mtype |-> CoPilotCommitRequest,
                                  mterm |-> currentTerm[i],
                                  msource |-> i,
                                  mdest |-> s,
                                  mcmd |-> entry.cmd,
                                  mdeps |-> finalDeps,
                                  mindex |-> m.mindex] : s \in Server \ {i} }
             IN messages' = AddMessages(commitMsgs, WithoutMessage(m, messages))
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                         role, cpBallot>>

HandleCoPilotCommit(i, m) ==
    /\ m.mtype = CoPilotCommitRequest
    /\ i = m.mdest
    /\ LET cmd == m.mcmd
           newEntry == [cmd |-> cmd, deps |-> m.mdeps,
                        status |-> Committed, ballot |-> cpBallot[i]]
           newLogEntry == [term |-> m.mterm, value |-> cmd, proposer |-> m.msource]
       IN /\ cpLog' = [cpLog EXCEPT ![i] =
                          IF Len(cpLog[i]) < m.mindex
                          THEN Append(cpLog[i], newEntry)
                          ELSE [cpLog[i] EXCEPT ![m.mindex] = newEntry]]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < m.mindex
                        THEN Append(log[i], newLogEntry)
                        ELSE log[i]]
          /\ commitIndex' = [commitIndex EXCEPT ![i] =
                               Max({commitIndex[i], m.mindex})]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         role, cpBallot>>

\* Fast takeover: copilot takes over pilot role, becomes ToBeLeader
\* for Jetpack recovery before becoming full Leader.
FastTakeover(i) ==
    /\ role[i] = Copilot
    /\ role' = [role EXCEPT ![i] = Pilot]
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, leaderVars,
                   logVars, cpLog, cpBallot>>

\* CoPilot-compatible Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ role' = [role EXCEPT ![i] = Acceptor]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, cpLog, cpBallot>>

\* Election timeout.
Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, copilotVars>>

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
                   cpLog, cpBallot>>

\* CoPilot ClientRequest: propose via CoPilot protocol.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ Propose(i, v)

(***************************************************************************)
(* Message plumbing                                                        *)
(***************************************************************************)

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, copilotVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, copilotVars>>

=============================================================================
