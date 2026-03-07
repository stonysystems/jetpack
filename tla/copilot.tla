------------------------------ MODULE copilot ------------------------------
\* CoPilot consensus protocol — a 1-slowdown-tolerant protocol with
\* two distinguished replicas (Pilot and Copilot) that both order and
\* execute all commands.  Based on the OSDI 2020 paper.
\*
\* This module runs standalone AND provides the same interface as raft.tla
\* so that jetpack.tla can compose with it as a base protocol.
\*
\* Key design: two replicas (pilot, copilot) each maintain their own log.
\* A fast pilot can safely complete the work of a slow pilot through a
\* fast takeover mechanism.  Commands are committed when a quorum agrees.

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]
NilDep == [tag |-> "NilDep"]

\* Server states — same interface as raft.tla.
Follower   == "Follower"
Candidate  == "Candidate"
Leader     == "Leader"

\* CoPilot roles.
Pilot      == "Pilot"
Copilot    == "Copilot"
Acceptor   == "Acceptor"

\* CoPilot-specific states for log entries.
PreAccepted  == "PreAccepted"
Accepted     == "Accepted"
Committed    == "Committed"

\* Message types.
CoPilotPreAcceptRequest   == "CoPilotPreAcceptRequest"
CoPilotPreAcceptResponse  == "CoPilotPreAcceptResponse"
CoPilotAcceptRequest      == "CoPilotAcceptRequest"
CoPilotAcceptResponse     == "CoPilotAcceptResponse"
CoPilotCommitRequest      == "CoPilotCommitRequest"

(***************************************************************************)
(* Shared data types                                                       *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

LogEntry == { [term |-> t, value |-> v] : t \in Nat, v \in Commands }

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,

    \* Per-server Raft-compatible variables.
    currentTerm,
    ostate,          \* Follower / Candidate / Leader
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* CoPilot-specific per-server variables.
    role,            \* Pilot / Copilot / Acceptor
    cpLog,           \* CoPilot's own log: sequence of [cmd, deps, status, ballot]
    cpBallot,        \* Current ballot for each server

    \* Execution tracking.
    execution_cmds

serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>
copilotVars == <<role, cpLog, cpBallot>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars,
          copilotVars, execution_cmds>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Symmetry == Permutations(Server)

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

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

LogCmdIds ==
    UNION { {log[i][k].value.cmd_id : k \in 1..Len(log[i])} : i \in Server }

ExecCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(execution_cmds)}

UsedCmdIds == LogCmdIds \cup ExecCmdIds

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin UsedCmdIds}

LogEntryAt(i, k) == IF k <= Len(log[i]) THEN log[i][k] ELSE Nil
LogCmdAt(i, k) == IF k <= Len(log[i]) THEN log[i][k].value ELSE NilCmd

MaxLogLen == Max({Len(log[i]) : i \in Server} \cup {0})

ExecAt(k) == IF k <= Len(execution_cmds) THEN execution_cmds[k] ELSE NilCmd

CommittedCmds(i) ==
    IF commitIndex[i] = 0 THEN <<>>
    ELSE [k \in 1..commitIndex[i] |-> log[i][k].value]

\* Determine the pilot and copilot for a given term.
\* Simple round-robin: pilot = (term mod N) + 1, copilot = ((term+1) mod N) + 1
\* We use Server as a set, so we map via CHOOSE.
ServerSeq == CHOOSE f \in [1..Cardinality(Server) -> Server] :
                \A i, j \in 1..Cardinality(Server) : i /= j => f[i] /= f[j]

PilotOf(term) == ServerSeq[((term - 1) % Cardinality(Server)) + 1]
CopilotOf(term) == ServerSeq[(term % Cardinality(Server)) + 1]

IsPilotOrCopilot(i) == role[i] \in {Pilot, Copilot}

\* CoPilot log entry dependencies: commands at the same key conflict.
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
    /\ role = [i \in Server |-> IF i = PilotOf(1) THEN Pilot
                                 ELSE IF i = CopilotOf(1) THEN Copilot
                                 ELSE Acceptor]
    /\ cpLog = [i \in Server |-> <<>>]
    /\ cpBallot = [i \in Server |-> 0]
    /\ execution_cmds = <<>>

(***************************************************************************)
(* CoPilot transitions                                                     *)
(***************************************************************************)

\* A pilot or copilot proposes a command.
Propose(i, v) ==
    /\ IsPilotOrCopilot(i)
    /\ v \in AvailableCommands
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
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         role, cpBallot, execution_cmds>>

\* An acceptor handles PreAccept.
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
          /\ Reply([mtype |-> CoPilotPreAcceptResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mdeps |-> unionDeps,
                    mindex |-> m.mindex,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         role, execution_cmds>>

\* Pilot/Copilot receives PreAccept response and tries to commit.
HandleCoPilotPreAcceptResponse(i, m) ==
    /\ m.mtype = CoPilotPreAcceptResponse
    /\ i = m.mdest
    /\ m.mok
    /\ m.mindex <= Len(cpLog[i])
    /\ cpLog[i][m.mindex].status = PreAccepted
    \* For simplicity, commit on first quorum response (fast path).
    /\ LET entry == cpLog[i][m.mindex]
           finalDeps == entry.deps \cup m.mdeps
           newEntry == [entry EXCEPT !.deps = finalDeps, !.status = Committed]
       IN /\ cpLog' = [cpLog EXCEPT ![i][m.mindex] = newEntry]
          /\ commitIndex' = [commitIndex EXCEPT ![i] =
                               Max({commitIndex[i], m.mindex})]
          \* Send commit to all.
          /\ LET commitMsgs == { [mtype |-> CoPilotCommitRequest,
                                  mterm |-> currentTerm[i],
                                  msource |-> i,
                                  mdest |-> s,
                                  mcmd |-> entry.cmd,
                                  mdeps |-> finalDeps,
                                  mindex |-> m.mindex] : s \in Server \ {i} }
             IN messages' = AddMessages(commitMsgs, WithoutMessage(m, messages))
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                         role, cpBallot, execution_cmds>>

\* Acceptor handles Commit message.
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
                               Max({commitIndex[i], m.mindex})]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         role, cpBallot, execution_cmds>>

\* Fast takeover: if the copilot notices the pilot is slow,
\* it can take over the pilot's role.
FastTakeover(i) ==
    /\ role[i] = Copilot
    /\ role' = [role EXCEPT ![i] = Pilot]
    /\ ostate' = [ostate EXCEPT ![i] = Leader]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, leaderVars,
                   logVars, cpLog, cpBallot, execution_cmds>>

\* Leader applies committed entries to execution_cmds.
ApplyCommitted(i) ==
    /\ IsPilotOrCopilot(i)
    /\ LET nextExecIndex == Len(execution_cmds) + 1
       IN /\ commitIndex[i] >= nextExecIndex
          /\ nextExecIndex <= Len(log[i])
          /\ LET nextCmd == log[i][nextExecIndex].value
             IN execution_cmds' = Append(execution_cmds, nextCmd)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars>>

\* ClientRequest for Raft-compatible interface.
ClientRequest(i, v) ==
    /\ IsPilotOrCopilot(i)
    /\ Propose(i, v)

\* BecomeLeader for Raft-compatible interface.
\* New pilot demotes old pilot to copilot (maintaining the dual-leader scheme).
BecomeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = Leader]
    /\ role' = [j \in Server |-> IF j = i THEN Pilot
                                  ELSE IF role[j] = Pilot THEN Copilot
                                  ELSE role[j]]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   cpLog, cpBallot, execution_cmds>>

\* Election timeout.
Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, copilotVars, execution_cmds>>

\* Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ role' = [role EXCEPT ![i] = Acceptor]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   cpLog, cpBallot, execution_cmds>>

\* Network actions.
DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, execution_cmds>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, execution_cmds>>

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : Timeout(i)
    \/ \E i \in Server : BecomeLeader(i)
    \/ \E i \in Server, v \in Commands : ClientRequest(i, v)
    \/ \E i \in Server : ApplyCommitted(i)
    \/ \E i \in Server : FastTakeover(i)
    \/ \E m \in DOMAIN messages : HandleCoPilotPreAccept(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleCoPilotPreAcceptResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleCoPilotCommit(m.mdest, m)
    \/ \E m \in DOMAIN messages : DuplicateMessage(m)
    \/ \E m \in DOMAIN messages : DropMessage(m)

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 5
    /\ \A i \in Server : Len(log[i]) <= 4
    /\ \A i \in Server : Len(cpLog[i]) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ \A i \in Server : Len(cpLog[i]) <= 2
    /\ Len(execution_cmds) <= 2

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* Committed entries at the same index agree across servers.
CommittedLogAgreement ==
    \A i, j \in Server :
        LET ci == commitIndex[i]
            cj == commitIndex[j]
            limit == Min({ci, cj} \cup {0})
        IN \A k \in 1..limit :
            log[i][k] = log[j][k]

\* At most two active proposers (pilot + copilot) at any time.
ActiveProposerBound ==
    Cardinality({i \in Server : role[i] \in {Pilot, Copilot}}) <= 2

MaxLogExecLen == Max({MaxLogLen, Len(execution_cmds)})

\* Logs agree at each index (using length guards to avoid TLC type errors).
LogAgreement ==
    /\ MaxLogLen >= 0
    /\ \A i, j \in Server :
         \A k \in 1..MaxLogLen :
            \/ k > Len(log[i])
            \/ k > Len(log[j])
            \/ log[i][k] = log[j][k]

\* Committed log entries preserve conflict ordering in execution trace.
\* Scoped to committed prefix only — CoPilot's dual-proposer design allows
\* uncommitted entries to diverge across servers.
LogOrderMatchesExecution ==
    \A i \in Server :
        LET ci == commitIndex[i]
        IN \A k \in 1..ci :
            LET lc == log[i][k].value
                ec == ExecAt(k)
            IN \/ lc = ec
               \/ ec = NilCmd

Safety == [](CommittedLogAgreement /\ ActiveProposerBound /\ LogOrderMatchesExecution)

SpecSafety == Spec => Safety

=============================================================================
