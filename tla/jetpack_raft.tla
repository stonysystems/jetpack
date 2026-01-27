------------------------------- MODULE jetpack_raft -------------------------------
\* NOTE: This file is named jetpack+raft.tla. TLA+ module names cannot contain
\* '+', so the module name uses an underscore. Rename the file if your tooling
\* requires an exact match.

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value used as a "nil" placeholder.
Nil == "Nil"
\* Typed nils for record values (avoid record vs. non-record equality).
NilCmd == [tag |-> "NilCmd"]
NilJPool == [tag |-> "NilJPool"]
NilPrepResp == [tag |-> "NilPrepResp"]

\* Raft roles.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Jetpack states.
Ready            == "Ready"
Recovery         == "Recovery"
AfterBeginRecovery == "AfterBeginRecovery"
AfterPrepare     == "AfterPrepare"
AfterAccept      == "AfterAccept"
AfterResubmit    == "AfterResubmit"

\* Raft message types.
RequestVoteRequest   == "RequestVoteRequest"
RequestVoteResponse  == "RequestVoteResponse"
AppendEntriesRequest == "AppendEntriesRequest"
AppendEntriesResponse == "AppendEntriesResponse"

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

RaftMessageTypes == {RequestVoteRequest, RequestVoteResponse,
                     AppendEntriesRequest, AppendEntriesResponse}
JetpackMessageTypes == {PreacceptRequest, PreacceptResponse,
                        BeginRecoveryRequest, BeginRecoveryResponse,
                        JetpackPrepareRequest, JetpackPrepareResponse,
                        JetpackAcceptRequest, JetpackAcceptResponse,
                        FinishRecoveryRequest}

(***************************************************************************)
(* Shared data types                                                       *)
(***************************************************************************)

\* Commands are identified by cmd_id and apply to a key.
Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

\* Views include an epoch and the replicas that participate.
View == [epoch: Nat,
         proposing_replica_ids: SUBSET Server,
         replica_ids: SUBSET Server]

IsView(v) ==
    /\ v \in View
    /\ v.replica_ids /= {}
    /\ v.proposing_replica_ids \subseteq v.replica_ids

DefaultView ==
    [epoch |-> 1,
     proposing_replica_ids |-> Server,
     replica_ids |-> Server]

\* Log entries store Raft term and a command.
LogEntry == { [term |-> t, value |-> v] : t \in Nat, v \in Commands }

\* Jetpack pool record.
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
    elections,
\*    allLogs,

    \* Raft per-server variables.
    currentTerm,
    ostate,
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    voterLog,
    nextIndex,
    matchIndex,

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
    fastpath_success_cmds,
    executed_cmds

serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted, voterLog>>
leaderVars == <<nextIndex, matchIndex, elections>>
jetpackVars == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                 recovery_set, chosen_value, br_responses,
                 prep_responses, accept_responses>>
clientVars == <<client_view, client_pending, client_successes,
                fastpath_success_cmds, executed_cmds>>

vars == <<messages, \* allLogs,
          logVars, jetpackVars, clientVars>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

\* Symmetry reduction over servers.
Symmetry == Permutations(Server)

\* Simple majority quorum over all servers.
Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

\* Quorum for a given view.
JQuorum(v) == {q \in SUBSET(v.replica_ids) :
                   Cardinality(q) * 2 > Cardinality(v.replica_ids)}

\* Fast-path quorum must include all proposers and any two fast-path quorums
\* must intersect in a quorum.
FastpathQuorum(v) ==
    {q \in JQuorum(v) :
        /\ v.proposing_replica_ids \subseteq q
        /\ \A q2 \in JQuorum(v) :
             v.proposing_replica_ids \subseteq q2 => (q \cap q2) \in JQuorum(v)}

\* Term of the last entry in a log.
LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

\* Return min/max from a set (undefined for empty set).
Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

\* Convert a sequence into the set of its elements.
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

\* Uniqueness helper for commands.
LogCmdIds ==
    UNION { {log[i][k].value.cmd_id : k \in 1..Len(log[i])} : i \in Server }

ExecCmdIds ==
    UNION { {executed_cmds[i][k].cmd_id : k \in 1..Len(executed_cmds[i])} : i \in Server }

UsedCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(fastpath_success_cmds)} \cup
    LogCmdIds \cup
    ExecCmdIds

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin UsedCmdIds}

\* Key conflict check for a command in a pool.
HasConflict(pool, cmd) ==
    /\ pool[cmd.key] /= NilCmd
    /\ pool[cmd.key] /= cmd

\* Compute recovery set from a quorum of BeginRecovery responses.
RecoveryCommands(i, qs) ==
    {cmd \in Commands :
        Cardinality({s \in qs : cmd \in JPoolCommands(br_responses[i][s])}) * 2
            > Cardinality(qs)}

\* Read the "kth" executed command or NilCmd if out of range.
ExecAt(i, k) == IF k <= Len(executed_cmds[i]) THEN executed_cmds[i][k] ELSE NilCmd

MaxExecLen == Max({Len(executed_cmds[i]) : i \in Server} \cup {0})

\* All commands in chosen_value are executed by every replica in the view.
ChosenExecutedInView(i) ==
    \A cmd \in chosen_value[i] :
        \A s \in new_view[i].replica_ids :
            cmd \in SeqToSet(executed_cmds[s])

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

InitHistoryVars ==
    /\ elections = {}
\*    /\ allLogs = {}

InitServerVars ==
    /\ currentTerm = [i \in Server |-> 1]
    /\ ostate = [i \in Server |-> Follower]
    /\ votedFor = [i \in Server |-> Nil]

InitCandidateVars ==
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ voterLog = [i \in Server |-> [j \in Server |-> <<>>]]

InitLeaderVars ==
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]

InitLogVars ==
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]

InitJetpackVars ==
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

InitClientVars ==
    /\ client_view = [c \in Client |-> DefaultView]
    /\ client_pending = [c \in Client |-> NilCmd]
    /\ client_successes = [c \in Client |-> {}]
    /\ fastpath_success_cmds = <<>>
    /\ executed_cmds = [i \in Server |-> <<>>]

Init ==
    /\ messages = [m \in {} |-> 0]
    /\ InitHistoryVars
    /\ InitServerVars
    /\ InitCandidateVars
    /\ InitLeaderVars
    /\ InitLogVars
    /\ InitJetpackVars
    /\ InitClientVars

(***************************************************************************)
(* Raft transitions                                                        *)
(***************************************************************************)

Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ voterLog' = [voterLog EXCEPT ![i] = [j \in Server |-> <<>>]]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, elections,
                   jetpackVars, clientVars>>

Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ voterLog' = [voterLog EXCEPT ![i] = [j \in Server |-> IF j = i THEN log[i] ELSE <<>>]]
    /\ UNCHANGED <<messages, leaderVars, logVars, jetpackVars, clientVars>>

RequestVote(i, j) ==
    /\ ostate[i] = Candidate
    /\ i /= j
    /\ j \notin votesResponded[i]
    /\ Send([mtype         |-> RequestVoteRequest,
             mterm         |-> currentTerm[i],
             mlastLogTerm  |-> LastTerm(log[i]),
             mlastLogIndex |-> Len(log[i]),
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

AppendEntries(i, j) ==
    /\ i /= j
    /\ ostate[i] = Leader
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm == IF prevLogIndex > 0 THEN
                              log[i][prevLogIndex].term
                          ELSE
                              0
           lastEntry == Min({Len(log[i]), nextIndex[i][j]})
           entries == SubSeq(log[i], nextIndex[i][j], lastEntry)
       IN Send([mtype          |-> AppendEntriesRequest,
                mterm          |-> currentTerm[i],
                mprevLogIndex  |-> prevLogIndex,
                mprevLogTerm   |-> prevLogTerm,
                mentries       |-> entries,
                mlog           |-> log[i],
                mcommitIndex   |-> Min({commitIndex[i], lastEntry}),
                msource        |-> i,
                mdest          |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

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
    /\ elections' = elections \cup
                        {[eterm     |-> currentTerm[i],
                          eleader   |-> i,
                          elog      |-> log[i],
                          evotes    |-> votesGranted[i],
                          evoterLog |-> voterLog[i]]}
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   jetpackVars, clientVars>>

ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ v \in Commands
    /\ LET entry == [term |-> currentTerm[i], value |-> v]
       IN log' = [log EXCEPT ![i] = Append(log[i], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, jetpackVars, clientVars>>

AdvanceCommitIndex(i) ==
    /\ ostate[i] = Leader
    /\ LET Agree(index) == {i} \cup {k \in Server : matchIndex[i][k] >= index}
           agreeIndexes == {index \in 1..Len(log[i]) : Agree(index) \in Quorum}
           newCommitIndex ==
              IF /\ agreeIndexes /= {}
                 /\ log[i][Max(agreeIndexes)].term = currentTerm[i]
              THEN
                  Max(agreeIndexes)
              ELSE
                  commitIndex[i]
       IN commitIndex' = [commitIndex EXCEPT ![i] = newCommitIndex]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   jetpackVars, clientVars>>

\* Apply committed log entries to executed_cmds.
ApplyCommitted(i) ==
    /\ commitIndex[i] > Len(executed_cmds[i])
    /\ LET committedEntries == SubSeq(log[i], 1, commitIndex[i])
           committedCmds ==
               [k \in 1..Len(committedEntries) |-> committedEntries[k].value]
       IN executed_cmds' = [executed_cmds EXCEPT ![i] = committedCmds]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, client_view, client_pending, client_successes,
                   fastpath_success_cmds>>

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
       /\ Reply([mtype        |-> RequestVoteResponse,
                 mterm        |-> currentTerm[i],
                 mvoteGranted |-> grant,
                 mlog         |-> log[i],
                 msource      |-> i,
                 mdest        |-> j],
                 m)
       /\ UNCHANGED <<ostate, currentTerm, candidateVars, leaderVars, logVars,
                      jetpackVars, clientVars>>

HandleRequestVoteResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] =
                              votesResponded[i] \cup {j}]
    /\ \/ /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] =
                                  votesGranted[i] \cup {j}]
          /\ voterLog' = [voterLog EXCEPT ![i][j] = m.mlog]
       \/ /\ ~m.mvoteGranted
          /\ UNCHANGED <<votesGranted, voterLog>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, leaderVars, logVars, jetpackVars, clientVars>>

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
             /\ Reply([mtype       |-> AppendEntriesResponse,
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
                       /\ Reply([mtype       |-> AppendEntriesResponse,
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
       /\ UNCHANGED <<candidateVars, leaderVars, jetpackVars, clientVars>>

HandleAppendEntriesResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ \/ /\ m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] = m.mmatchIndex + 1]
          /\ matchIndex' = [matchIndex EXCEPT ![i][j] = m.mmatchIndex]
       \/ /\ \lnot m.msuccess
          /\ nextIndex' = [nextIndex EXCEPT ![i][j] =
                               Max({nextIndex[i][j] - 1, 1})]
          /\ UNCHANGED <<matchIndex>>
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, logVars, elections,
                   jetpackVars, clientVars>>

UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

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
                            jetpackVars, client_view, fastpath_success_cmds,
                            executed_cmds>>

\* Server handles Preaccept from client or another server.
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
                         jstate, jepoch, oepoch, old_view, new_view,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, accept_responses,
                         clientVars>>

\* Client handles Preaccept responses (fast-path success or view update).
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
          /\ fastpath_success_cmds' =
              IF fastOk
              THEN Append(fastpath_success_cmds, m.mcmd)
              ELSE fastpath_success_cmds
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         logVars, jetpackVars, executed_cmds>>

\* Candidate (now ToBeLeader) starts recovery.
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
                         jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, prep_responses,
                         accept_responses, clientVars>>

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
                   jepoch, jpool, recovery_set, chosen_value,
                   br_responses, prep_responses, accept_responses,
                   clientVars>>

HandleBeginRecoveryResponse(i, m) ==
    /\ m.mtype = BeginRecoveryResponse
    /\ i = m.mdest
    /\ jstate[i] = Recovery
    /\ br_responses' = [br_responses EXCEPT ![i][m.msource] = m.mjpool]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jstate, jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, prep_responses, accept_responses,
                   clientVars>>

CompleteBeginRecovery(i) ==
    /\ jstate[i] = Recovery
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : br_responses[i][s] /= NilJPool
         /\ LET rec == RecoveryCommands(i, qs)
            IN /\ recovery_set' = [recovery_set EXCEPT ![i] = rec]
               /\ chosen_value' = [chosen_value EXCEPT ![i] = rec]
               /\ jstate' = [jstate EXCEPT ![i] = AfterBeginRecovery]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   br_responses, prep_responses, accept_responses,
                   clientVars>>

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
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         accept_responses, clientVars>>

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
                         jstate, old_view, new_view, recovery_set, chosen_value,
                         br_responses, prep_responses, accept_responses,
                         clientVars>>

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
                   jstate, old_view, new_view, recovery_set, chosen_value,
                   br_responses, accept_responses, clientVars>>

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
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, br_responses, prep_responses,
                   accept_responses, clientVars>>

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
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, clientVars>>

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
                         jstate, old_view, new_view, recovery_set, chosen_value,
                         br_responses, prep_responses, accept_responses,
                         clientVars>>

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
                   jstate, old_view, new_view, recovery_set, chosen_value,
                   br_responses, prep_responses, clientVars>>

CompleteAccept(i) ==
    /\ jstate[i] = AfterPrepare
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : accept_responses[i][s] = TRUE
         /\ jstate' = [jstate EXCEPT ![i] = AfterAccept]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses, clientVars>>

\* Resubmit chosen_value via Preaccept to proposers (does not advance state).
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
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, accept_responses, clientVars>>

\* Advance to AfterResubmit once chosen_value has been executed in Raft.
CompleteResubmit(i) ==
    /\ jstate[i] = AfterAccept
    /\ ChosenExecutedInView(i)
    /\ jstate' = [jstate EXCEPT ![i] = AfterResubmit]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   jepoch, oepoch, old_view, new_view, jpool,
                   recovery_set, chosen_value, br_responses,
                   prep_responses, accept_responses, clientVars>>

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
                         votesGranted, voterLog, nextIndex, matchIndex,
                         elections, logVars, clientVars>>

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
                   votesGranted, voterLog, nextIndex, matchIndex,
                   elections, logVars, br_responses, prep_responses,
                   accept_responses, clientVars>>

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype \in RaftMessageTypes
          /\ RaftReceive(m)
       \/ /\ m.mtype = PreacceptRequest
          /\ HandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = PreacceptResponse
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         jetpackVars, clientVars>>
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
                   jetpackVars, clientVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   jetpackVars, clientVars>>

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
       \/ \E i \in Server, v \in Commands : ClientRequest(i, v)

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

\*    /\ allLogs' = allLogs \cup {log[i] : i \in Server}

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* Executed commands are identical or missing at any position.
ExecutedCmdsAgreement ==
    /\ MaxExecLen >= 0
    /\ \A i, j \in Server :
         \A k \in 1..MaxExecLen :
            LET ci == ExecAt(i, k)
                cj == ExecAt(j, k)
            IN \/ ci = cj
               \/ ci = NilCmd
               \/ cj = NilCmd

\* Durability: any fast-path success eventually appears in every executed_cmds.
Durability ==
    \A cmd \in Commands :
        cmd \in SeqToSet(fastpath_success_cmds)
        => <> (\A s \in Server : cmd \in SeqToSet(executed_cmds[s]))

\* Temporal wrappers for TLC configs.
Safety == []ExecutedCmdsAgreement
Liveness == Durability

\* Implication forms (useful for theorem statements or properties).
SpecSafety == Spec => Safety
SpecLiveness == Spec => Liveness

=============================================================================
