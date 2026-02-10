--------------------------- MODULE jetpack_copilot ---------------------------
\* Composition of Jetpack plugin with CoPilot base protocol.
\* Follows the same monolithic pattern as jetpack_raft.tla.
\*
\* CoPilot provides: dual-leader (pilot + copilot) replication with
\* dependency tracking and fast takeover.
\* Jetpack provides: fast-path preaccept with recovery on leader change.
\*
\* Key differences from jetpack_raft.tla:
\*   - BecomeLeader replaced by BecomeToBeLeader (Jetpack recovery)
\*   - CoPilot-specific variables (role, cpLog, cpBallot) added
\*   - CoPilot message types routed alongside Jetpack message types
\*   - CoPilot's FastTakeover triggers Jetpack recovery

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value used as a "nil" placeholder.
Nil == "Nil"
\* Typed nils for record values (avoid record vs. non-record equality).
NilCmd == [tag |-> "NilCmd"]
NilJPool == [tag |-> "NilJPool"]
NilPrepResp == [tag |-> "NilPrepResp"]
NilDep == [tag |-> "NilDep"]

\* Server states (Raft-compatible + Jetpack's ToBeLeader).
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* CoPilot roles.
Pilot      == "Pilot"
Copilot    == "Copilot"
Acceptor   == "Acceptor"

\* CoPilot-specific entry states.
PreAccepted  == "PreAccepted"
Accepted     == "Accepted"
Committed    == "Committed"

\* Jetpack states.
Ready            == "Ready"
Recovery         == "Recovery"
AfterBeginRecovery == "AfterBeginRecovery"
AfterPrepare     == "AfterPrepare"
AfterAccept      == "AfterAccept"
AfterResubmit    == "AfterResubmit"

\* CoPilot message types.
CoPilotPreAcceptRequest   == "CoPilotPreAcceptRequest"
CoPilotPreAcceptResponse  == "CoPilotPreAcceptResponse"
CoPilotAcceptRequest      == "CoPilotAcceptRequest"
CoPilotAcceptResponse     == "CoPilotAcceptResponse"
CoPilotCommitRequest      == "CoPilotCommitRequest"

\* Jetpack message types.
PreacceptRequest      == "PreacceptRequest"
PreacceptResponse     == "PreacceptResponse"
BeginRecoveryRequest  == "BeginRecoveryRequest"
BeginRecoveryResponse == "BeginRecoveryResponse"
JetpackPrepareRequest == "JetpackPrepareRequest"
JetpackPrepareResponse == "JetpackPrepareResponse"
JetpackAcceptRequest  == "JetpackAcceptRequest"
JetpackAcceptResponse == "JetpackAcceptResponse"
FinishRecoveryRequest == "FinishRecoveryRequest"

CoPilotMessageTypes == {CoPilotPreAcceptRequest, CoPilotPreAcceptResponse,
                        CoPilotAcceptRequest, CoPilotAcceptResponse,
                        CoPilotCommitRequest}
JetpackMessageTypes == {PreacceptRequest, PreacceptResponse,
                        BeginRecoveryRequest, BeginRecoveryResponse,
                        JetpackPrepareRequest, JetpackPrepareResponse,
                        JetpackAcceptRequest, JetpackAcceptResponse,
                        FinishRecoveryRequest}

(***************************************************************************)
(* Shared data types                                                       *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

View == [epoch: Nat,
         proposing_replica_ids: SUBSET Server,
         replica_ids: SUBSET Server]

DefaultView ==
    [epoch |-> 1,
     proposing_replica_ids |-> Server,
     replica_ids |-> Server]

LogEntry == { [term |-> t, value |-> v] : t \in Nat, v \in Commands }

JPool == [max_seen_ballot: Nat,
          accepted_ballot: Nat,
          accepted_value: SUBSET Commands,
          pool: [Key -> Commands \cup {NilCmd}]]

EmptyJPool ==
    [max_seen_ballot |-> 0,
     accepted_ballot |-> 0,
     accepted_value |-> {},
     pool |-> [k \in Key |-> NilCmd]]

JPoolCommands(p) == {p.pool[k] : k \in Key} \ {NilCmd}

PrepResp == [accepted_ballot: Nat, accepted_value: SUBSET Commands]

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,

    \* Per-server variables (shared interface).
    currentTerm,
    ostate,
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* CoPilot-specific per-server variables.
    role,
    cpLog,
    cpBallot,

    \* Jetpack per-server variables.
    jstate,
    jepoch,
    oepoch,
    old_view,
    new_view,
    jpool,
    recovery_set,
    chosen_value,
    br_responses,
    prep_responses,
    accept_responses,

    \* Client-side variables.
    client_view,
    client_pending,
    client_successes,

    \* Execution tracking variables.
    original_execution_cmds,
    execution_cmds

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
(* Helpers                                                                 *)
(***************************************************************************)

Symmetry == Permutations(Server)

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

JQuorum(v) == {q \in SUBSET(v.replica_ids) :
                   Cardinality(q) * 2 > Cardinality(v.replica_ids)}

FastpathQuorum(v) ==
    {q \in JQuorum(v) :
        /\ v.proposing_replica_ids \subseteq q
        /\ \A q2 \in JQuorum(v) :
             v.proposing_replica_ids \subseteq q2 => (q \cap q2) \in JQuorum(v)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

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

RECURSIVE RemoveCmd(_,_)
RemoveCmd(seq, cmd) ==
    IF seq = <<>> THEN <<>>
    ELSE LET head == seq[1]
             tail == SubSeq(seq, 2, Len(seq))
         IN IF head = cmd
            THEN RemoveCmd(tail, cmd)
            ELSE <<head>> \o RemoveCmd(tail, cmd)

RECURSIVE Dedup(_)
Dedup(seq) ==
    IF seq = <<>> THEN <<>>
    ELSE LET head == seq[1]
             tail == SubSeq(seq, 2, Len(seq))
         IN <<head>> \o Dedup(RemoveCmd(tail, head))

LogCmdIds ==
    UNION { {log[i][k].value.cmd_id : k \in 1..Len(log[i])} : i \in Server }

ExecCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(execution_cmds)}

OriginalExecCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(original_execution_cmds)}

UsedCmdIds ==
    LogCmdIds \cup ExecCmdIds \cup OriginalExecCmdIds

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin UsedCmdIds}

HasConflict(pool, cmd) ==
    /\ pool[cmd.key] /= NilCmd
    /\ pool[cmd.key] /= cmd

RecoveryCommands(i, qs) ==
    {cmd \in Commands :
        Cardinality({s \in qs : cmd \in JPoolCommands(br_responses[i][s])}) * 2
            > Cardinality(qs)}

ExecAt(k) == IF k <= Len(execution_cmds) THEN execution_cmds[k] ELSE NilCmd

MaxExecLen == Len(execution_cmds)

CommittedCmds(i) ==
    IF commitIndex[i] = 0 THEN <<>>
    ELSE [k \in 1..commitIndex[i] |-> log[i][k].value]

LogEntryAt(i, k) == IF k <= Len(log[i]) THEN log[i][k] ELSE Nil
LogCmdAt(i, k) == IF k <= Len(log[i]) THEN log[i][k].value ELSE NilCmd

MaxLogLen == Max({Len(log[i]) : i \in Server} \cup {0})
MaxLogExecLen == Max({MaxLogLen, Len(execution_cmds)})

IsPrefix(p, s) ==
    /\ Len(p) <= Len(s)
    /\ \A k \in 1..Len(p) : p[k] = s[k]

ChosenExecutedInView(i) ==
    \A cmd \in chosen_value[i] :
        \A s \in new_view[i].replica_ids :
            cmd \in SeqToSet(CommittedCmds(s))

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
    /\ jstate = [i \in Server |-> Ready]
    /\ jepoch = [i \in Server |-> DefaultView.epoch]
    /\ oepoch = [i \in Server |-> DefaultView.epoch]
    /\ old_view = [i \in Server |-> DefaultView]
    /\ new_view = [i \in Server |-> DefaultView]
    /\ jpool = [i \in Server |-> EmptyJPool]
    /\ recovery_set = [i \in Server |-> {}]
    /\ chosen_value = [i \in Server |-> {}]
    /\ br_responses = [i \in Server |-> [j \in Server |-> NilJPool]]
    /\ prep_responses = [i \in Server |-> [j \in Server |-> NilPrepResp]]
    /\ accept_responses = [i \in Server |-> [j \in Server |-> FALSE]]
    \* Client init.
    /\ client_view = [c \in Client |-> DefaultView]
    /\ client_pending = [c \in Client |-> NilCmd]
    /\ client_successes = [c \in Client |-> {}]
    \* Execution init.
    /\ original_execution_cmds = <<>>
    /\ execution_cmds = <<>>

(***************************************************************************)
(* CoPilot transitions                                                     *)
(***************************************************************************)

\* A pilot or copilot proposes a command via CoPilot protocol.
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
          /\ Reply([mtype |-> CoPilotPreAcceptResponse,
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
                               Max({commitIndex[i], m.mindex})]
          /\ Discard(m)
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
    /\ ostate[i] = Leader
    /\ commitIndex[i] > Len(original_execution_cmds)
    /\ LET nextExecIndex == Len(original_execution_cmds) + 1
           nextCmd == log[i][nextExecIndex].value
       IN /\ original_execution_cmds' =
              Append(original_execution_cmds, nextCmd)
          /\ execution_cmds' = Append(execution_cmds, nextCmd)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, jetpackVars, clientVars>>

(***************************************************************************)
(* Jetpack transitions                                                     *)
(***************************************************************************)

\* Client sends a Preaccept to all replicas in its view.
ClientSendPreaccept(c) ==
    /\ client_pending[c] = NilCmd
    /\ AvailableCommands /= {}
    /\ \E cmd \in AvailableCommands :
          LET view == client_view[c]
              msgSet == { [mtype  |-> PreacceptRequest,
                            msource |-> c,
                            mdest |-> s,
                            mepoch |-> view.epoch,
                            mview |-> view,
                            mcmd |-> cmd] : s \in view.replica_ids }
          IN /\ messages' = AddMessages(msgSet, messages)
             /\ client_pending' = [client_pending EXCEPT ![c] = cmd]
             /\ client_successes' = [client_successes EXCEPT ![c] = {}]
             /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                            copilotVars, jetpackVars, client_view, executionVars>>

HandlePreacceptRequest(i, m) ==
    /\ m.mtype = PreacceptRequest
    /\ i = m.mdest
    /\ LET cmd == m.mcmd
           epochOk == m.mepoch = jepoch[i]
           readyOk == jstate[i] = Ready
           noConflict == \lnot HasConflict(jpool[i].pool, cmd)
           accept == epochOk /\ readyOk /\ noConflict
           reply == [mtype   |-> PreacceptResponse,
                     msuccess |-> accept,
                     mjepoch |-> jepoch[i],
                     mview   |-> new_view[i],
                     mcmd    |-> cmd,
                     msource |-> i,
                     mdest   |-> m.msource]
           newLog == Append(log[i], [term |-> currentTerm[i], value |-> cmd])
       IN /\ jpool' = IF accept THEN
                          [jpool EXCEPT ![i].pool[cmd.key] = cmd]
                      ELSE
                          jpool
          /\ log' = IF epochOk /\ readyOk /\ ostate[i] = Leader
                    THEN [log EXCEPT ![i] = newLog]
                    ELSE log
          /\ Reply(reply, m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         copilotVars,
                         jstate, jepoch, oepoch, old_view, new_view,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, accept_responses,
                         clientVars, executionVars>>

HandlePreacceptResponse(c, m) ==
    /\ m.mtype = PreacceptResponse
    /\ m.mdest = c
    /\ client_pending[c] = m.mcmd
    /\ LET view == client_view[c]
           newSuccesses == IF m.msuccess
                           THEN client_successes[c] \cup {m.msource}
                           ELSE client_successes[c]
           fastOk == newSuccesses \in FastpathQuorum(view)
       IN /\ client_successes' =
              IF fastOk \/ \lnot m.msuccess
              THEN [client_successes EXCEPT ![c] = {}]
              ELSE [client_successes EXCEPT ![c] = newSuccesses]
          /\ client_pending' =
              IF fastOk \/ \lnot m.msuccess
              THEN [client_pending EXCEPT ![c] = NilCmd]
              ELSE [client_pending EXCEPT ![c] = client_pending[c]]
          /\ client_view' =
              IF \lnot m.msuccess
              THEN [client_view EXCEPT ![c] = m.mview]
              ELSE client_view
          /\ execution_cmds' =
              IF fastOk
              THEN Append(execution_cmds, m.mcmd)
              ELSE execution_cmds
          /\ original_execution_cmds' = original_execution_cmds
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         logVars, copilotVars, jetpackVars>>

SendBeginRecovery(i) ==
    /\ ostate[i] = ToBeLeader
    /\ jstate[i] = Ready
    /\ LET view == new_view[i]
           msgSet == { [mtype |-> BeginRecoveryRequest,
                        msource |-> i,
                        mdest |-> s,
                        mold_view |-> old_view[i],
                        mnew_view |-> new_view[i]] : s \in view.replica_ids }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ jstate' = [jstate EXCEPT ![i] = Recovery]
          /\ br_responses' = [br_responses EXCEPT ![i] = [s \in Server |-> NilJPool]]
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, prep_responses,
                         accept_responses, clientVars, executionVars>>

HandleBeginRecoveryRequest(i, m) ==
    /\ m.mtype = BeginRecoveryRequest
    /\ i = m.mdest
    /\ old_view' = [old_view EXCEPT ![i] = m.mold_view]
    /\ new_view' = [new_view EXCEPT ![i] = m.mnew_view]
    /\ oepoch' = [oepoch EXCEPT ![i] = m.mnew_view.epoch]
    /\ jstate' = [jstate EXCEPT ![i] = Recovery]
    /\ Reply([mtype |-> BeginRecoveryResponse,
              mjpool |-> jpool[i],
              msource |-> i,
              mdest |-> m.msource],
              m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jepoch, jpool, recovery_set, chosen_value,
                   br_responses, prep_responses, accept_responses,
                   clientVars, executionVars>>

HandleBeginRecoveryResponse(i, m) ==
    /\ m.mtype = BeginRecoveryResponse
    /\ i = m.mdest
    /\ jstate[i] = Recovery
    /\ br_responses' = [br_responses EXCEPT ![i][m.msource] = m.mjpool]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, prep_responses, accept_responses,
                   clientVars, executionVars>>

CompleteBeginRecovery(i) ==
    /\ jstate[i] = Recovery
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : br_responses[i][s] /= NilJPool
         /\ LET rec == RecoveryCommands(i, qs)
            IN /\ recovery_set' = [recovery_set EXCEPT ![i] = rec]
               /\ chosen_value' = [chosen_value EXCEPT ![i] = rec]
               /\ jstate' = [jstate EXCEPT ![i] = AfterBeginRecovery]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   br_responses, prep_responses, accept_responses,
                   clientVars, executionVars>>

SendPrepare(i) ==
    /\ jstate[i] = AfterBeginRecovery
    /\ LET view == new_view[i]
           msgSet == { [mtype |-> JetpackPrepareRequest,
                        moepoch |-> oepoch[i],
                        mjepoch |-> jepoch[i],
                        mmax_seen_ballot |-> jpool[i].max_seen_ballot,
                        msource |-> i,
                        mdest |-> s] : s \in view.replica_ids }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ prep_responses' = [prep_responses EXCEPT ![i] = [s \in Server |-> NilPrepResp]]
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         accept_responses, clientVars, executionVars>>

HandlePrepareRequest(i, m) ==
    /\ m.mtype = JetpackPrepareRequest
    /\ i = m.mdest
    /\ LET ok == /\ m.moepoch >= oepoch[i]
                 /\ m.mjepoch >= jepoch[i]
                 /\ m.mmax_seen_ballot >= jpool[i].max_seen_ballot
           reply == IF ok THEN
                       [mtype |-> JetpackPrepareResponse,
                        mok |-> TRUE,
                        maccepted_ballot |-> jpool[i].accepted_ballot,
                        maccepted_value |-> jpool[i].accepted_value,
                        moepoch |-> oepoch[i],
                        mjepoch |-> jepoch[i],
                        mmax_seen_ballot |-> m.mmax_seen_ballot,
                        msource |-> i,
                        mdest |-> m.msource]
                   ELSE
                       [mtype |-> JetpackPrepareResponse,
                        mok |-> FALSE,
                        maccepted_ballot |-> jpool[i].accepted_ballot,
                        maccepted_value |-> jpool[i].accepted_value,
                        moepoch |-> oepoch[i],
                        mjepoch |-> jepoch[i],
                        mmax_seen_ballot |-> jpool[i].max_seen_ballot,
                        msource |-> i,
                        mdest |-> m.msource]
       IN /\ oepoch' = IF ok THEN [oepoch EXCEPT ![i] = Max({oepoch[i], m.moepoch})]
                       ELSE oepoch
          /\ jepoch' = IF ok THEN [jepoch EXCEPT ![i] = Max({jepoch[i], m.mjepoch})]
                       ELSE jepoch
          /\ jpool' = IF ok THEN
                        [jpool EXCEPT ![i].max_seen_ballot = m.mmax_seen_ballot]
                      ELSE jpool
          /\ Reply(reply, m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jstate, old_view, new_view, recovery_set, chosen_value,
                         br_responses, prep_responses, accept_responses,
                         clientVars, executionVars>>

HandlePrepareResponse(i, m) ==
    /\ m.mtype = JetpackPrepareResponse
    /\ i = m.mdest
    /\ IF m.mok THEN
          /\ prep_responses' =
                 [prep_responses EXCEPT ![i][m.msource] =
                     [accepted_ballot |-> m.maccepted_ballot,
                      accepted_value |-> m.maccepted_value]]
          /\ UNCHANGED <<oepoch, jepoch, jpool>>
       ELSE
          /\ prep_responses' = prep_responses
          /\ oepoch' = [oepoch EXCEPT ![i] = Max({oepoch[i], m.moepoch})]
          /\ jepoch' = [jepoch EXCEPT ![i] = Max({jepoch[i], m.mjepoch})]
          /\ jpool' = [jpool EXCEPT ![i].max_seen_ballot =
                           Max({jpool[i].max_seen_ballot, m.mmax_seen_ballot})]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jstate, old_view, new_view, recovery_set, chosen_value,
                   br_responses, accept_responses, clientVars, executionVars>>

CompletePrepare(i) ==
    /\ jstate[i] = AfterBeginRecovery
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : prep_responses[i][s] /= NilPrepResp
         /\ LET respVals == {prep_responses[i][s] : s \in qs}
                ballots == {r.accepted_ballot : r \in respVals}
                maxb == IF ballots = {} THEN 0 ELSE Max(ballots)
                topVals == {r \in respVals : r.accepted_ballot = maxb}
                bestVals == {r.accepted_value : r \in topVals}
                pick == IF maxb = 0 \/ bestVals = {}
                        THEN chosen_value[i]
                        ELSE CHOOSE v \in bestVals : TRUE
            IN /\ chosen_value' = [chosen_value EXCEPT ![i] = pick]
               /\ jstate' = [jstate EXCEPT ![i] = AfterPrepare]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, br_responses, prep_responses,
                   accept_responses, clientVars, executionVars>>

SendAccept(i) ==
    /\ jstate[i] = AfterPrepare
    /\ LET view == new_view[i]
           msgSet == { [mtype |-> JetpackAcceptRequest,
                        moepoch |-> oepoch[i],
                        mjepoch |-> jepoch[i],
                        mmax_seen_ballot |-> jpool[i].max_seen_ballot,
                        mvalue |-> chosen_value[i],
                        msource |-> i,
                        mdest |-> s] : s \in view.replica_ids }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ accept_responses' = [accept_responses EXCEPT ![i] = [s \in Server |-> FALSE]]
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, clientVars, executionVars>>

HandleAcceptRequest(i, m) ==
    /\ m.mtype = JetpackAcceptRequest
    /\ i = m.mdest
    /\ LET ok == /\ m.moepoch >= oepoch[i]
                 /\ m.mjepoch >= jepoch[i]
                 /\ m.mmax_seen_ballot >= jpool[i].max_seen_ballot
           reply == IF ok THEN
                       [mtype |-> JetpackAcceptResponse,
                        mok |-> TRUE,
                        mmax_seen_ballot |-> m.mmax_seen_ballot,
                        msource |-> i,
                        mdest |-> m.msource]
                   ELSE
                       [mtype |-> JetpackAcceptResponse,
                        mok |-> FALSE,
                        mmax_seen_ballot |-> jpool[i].max_seen_ballot,
                        msource |-> i,
                        mdest |-> m.msource]
       IN /\ oepoch' = IF ok THEN [oepoch EXCEPT ![i] = Max({oepoch[i], m.moepoch})]
                       ELSE oepoch
          /\ jepoch' = IF ok THEN [jepoch EXCEPT ![i] = Max({jepoch[i], m.mjepoch})]
                       ELSE jepoch
          /\ jpool' = IF ok THEN
                        [jpool EXCEPT ![i].max_seen_ballot = m.mmax_seen_ballot,
                                         ![i].accepted_ballot = m.mmax_seen_ballot,
                                         ![i].accepted_value = m.mvalue]
                      ELSE jpool
          /\ Reply(reply, m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jstate, old_view, new_view, recovery_set, chosen_value,
                         br_responses, prep_responses, accept_responses,
                         clientVars, executionVars>>

HandleAcceptResponse(i, m) ==
    /\ m.mtype = JetpackAcceptResponse
    /\ i = m.mdest
    /\ IF m.mok THEN
          /\ accept_responses' =
                 [accept_responses EXCEPT ![i][m.msource] = TRUE]
          /\ UNCHANGED <<oepoch, jepoch, jpool>>
       ELSE
          /\ accept_responses' = accept_responses
          /\ jpool' = [jpool EXCEPT ![i].max_seen_ballot =
                          Max({jpool[i].max_seen_ballot, m.mmax_seen_ballot})]
          /\ UNCHANGED <<oepoch, jepoch>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jstate, old_view, new_view, recovery_set, chosen_value,
                   br_responses, prep_responses, clientVars, executionVars>>

CompleteAccept(i) ==
    /\ jstate[i] = AfterPrepare
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : accept_responses[i][s] = TRUE
         /\ jstate' = [jstate EXCEPT ![i] = AfterAccept]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses, clientVars, executionVars>>

Resubmit(i) ==
    /\ jstate[i] = AfterAccept
    /\ LET proposers == new_view[i].proposing_replica_ids
           msgSet == { [mtype |-> PreacceptRequest,
                        msource |-> i,
                        mdest |-> s,
                        mepoch |-> jepoch[i],
                        mview |-> new_view[i],
                        mcmd |-> cmd] :
                        s \in proposers, cmd \in chosen_value[i] }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars,
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, accept_responses, clientVars, executionVars>>

CompleteResubmit(i) ==
    /\ jstate[i] = AfterAccept
    /\ ChosenExecutedInView(i)
    /\ jstate' = [jstate EXCEPT ![i] = AfterResubmit]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   copilotVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses, clientVars, executionVars>>

FinishRecovery(i) ==
    /\ jstate[i] = AfterResubmit
    /\ LET view == new_view[i]
           msgSet == { [mtype |-> FinishRecoveryRequest,
                        moepoch |-> oepoch[i],
                        mnew_view |-> view,
                        msource |-> i,
                        mdest |-> s] : s \in view.replica_ids }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ jepoch' = [jepoch EXCEPT ![i] = oepoch[i]]
          /\ oepoch' = [oepoch EXCEPT ![i] = oepoch[i]]
          /\ old_view' = [old_view EXCEPT ![i] = view]
          /\ new_view' = [new_view EXCEPT ![i] = view]
          /\ jpool' = [jpool EXCEPT ![i] = EmptyJPool]
          /\ jstate' = [jstate EXCEPT ![i] = Ready]
          /\ recovery_set' = [recovery_set EXCEPT ![i] = {}]
          /\ chosen_value' = [chosen_value EXCEPT ![i] = {}]
          /\ br_responses' = [br_responses EXCEPT ![i] = [s \in Server |-> NilJPool]]
          /\ prep_responses' = [prep_responses EXCEPT ![i] = [s \in Server |-> NilPrepResp]]
          /\ accept_responses' = [accept_responses EXCEPT ![i] = [s \in Server |-> FALSE]]
          /\ ostate' = [ostate EXCEPT ![i] = Leader]
    /\ UNCHANGED <<currentTerm, votedFor, votesResponded,
                   votesGranted, nextIndex, matchIndex,
                   logVars, copilotVars, clientVars, executionVars>>

HandleFinishRecovery(i, m) ==
    /\ m.mtype = FinishRecoveryRequest
    /\ i = m.mdest
    /\ jepoch' = [jepoch EXCEPT ![i] = m.moepoch]
    /\ oepoch' = [oepoch EXCEPT ![i] = m.moepoch]
    /\ old_view' = [old_view EXCEPT ![i] = m.mnew_view]
    /\ new_view' = [new_view EXCEPT ![i] = m.mnew_view]
    /\ jpool' = [jpool EXCEPT ![i] = EmptyJPool]
    /\ jstate' = [jstate EXCEPT ![i] = Ready]
    /\ recovery_set' = [recovery_set EXCEPT ![i] = {}]
    /\ chosen_value' = [chosen_value EXCEPT ![i] = {}]
    /\ ostate' = [ostate EXCEPT ![i] = IF ostate[i] = ToBeLeader THEN Leader ELSE ostate[i]]
    /\ Discard(m)
    /\ UNCHANGED <<currentTerm, votedFor, votesResponded,
                   votesGranted, nextIndex, matchIndex,
                   logVars, copilotVars, br_responses, prep_responses,
                   accept_responses, clientVars, executionVars>>

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
       \/ /\ m.mtype = PreacceptRequest
          /\ HandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = PreacceptResponse
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         copilotVars, jetpackVars, clientVars, executionVars>>
       \/ /\ m.mtype = BeginRecoveryRequest
          /\ HandleBeginRecoveryRequest(m.mdest, m)
       \/ /\ m.mtype = BeginRecoveryResponse
          /\ HandleBeginRecoveryResponse(m.mdest, m)
       \/ /\ m.mtype = JetpackPrepareRequest
          /\ HandlePrepareRequest(m.mdest, m)
       \/ /\ m.mtype = JetpackPrepareResponse
          /\ HandlePrepareResponse(m.mdest, m)
       \/ /\ m.mtype = JetpackAcceptRequest
          /\ HandleAcceptRequest(m.mdest, m)
       \/ /\ m.mtype = JetpackAcceptResponse
          /\ HandleAcceptResponse(m.mdest, m)
       \/ /\ m.mtype = FinishRecoveryRequest
          /\ HandleFinishRecovery(m.mdest, m)

ClientReceive(m) ==
    /\ m.mdest \in Client
    /\ m.mtype = PreacceptResponse
    /\ HandlePreacceptResponse(m.mdest, m)

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   copilotVars, jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ Discard(m)
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
       \/ \E i \in Server, v \in Commands : ClientRequest(i, v)
       \/ \E i \in Server : FastTakeover(i)

       \/ \E c \in Client : ClientSendPreaccept(c)
       \/ \E i \in Server : SendBeginRecovery(i)
       \/ \E i \in Server : CompleteBeginRecovery(i)
       \/ \E i \in Server : SendPrepare(i)
       \/ \E i \in Server : CompletePrepare(i)
       \/ \E i \in Server : SendAccept(i)
       \/ \E i \in Server : CompleteAccept(i)
       \/ \E i \in Server : Resubmit(i)
       \/ \E i \in Server : CompleteResubmit(i)
       \/ \E i \in Server : FinishRecovery(i)

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

\* Log order matches execution_cmds (allowing NilCmd for missing).
LogOrderMatchesExecution ==
    /\ MaxLogExecLen >= 0
    /\ \A i \in Server :
         \A k \in 1..MaxLogExecLen :
            LET lc == LogCmdAt(i, k)
                ec == ExecAt(k)
            IN \/ lc = ec
               \/ lc = NilCmd
               \/ ec = NilCmd

\* Deduplicated original executions match execution_cmds.
ExecutionDedupMatches ==
    \/ IsPrefix(Dedup(original_execution_cmds), execution_cmds)
    \/ IsPrefix(Dedup(execution_cmds), original_execution_cmds)

\* Committed log entries agree across servers at each index.
\* Use length guards to avoid comparing records with Nil (TLC type error).
LogAgreement ==
    /\ MaxLogLen >= 0
    /\ \A i, j \in Server :
         \A k \in 1..MaxLogLen :
            \/ k > Len(log[i])
            \/ k > Len(log[j])
            \/ log[i][k] = log[j][k]

\* At most two active proposers (pilot + copilot) at any time.
ActiveProposerBound ==
    Cardinality({i \in Server : role[i] \in {Pilot, Copilot}}) <= 2

Safety == [](LogAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches /\ ActiveProposerBound)

SpecSafety == Spec => Safety

=============================================================================
