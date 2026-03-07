--------------------------------- MODULE raft ---------------------------------
\* Standalone Raft consensus protocol for independent verification.
\* For Jetpack composition, use base_raft.tla (which adds the ToBeLeader
\* state that jetpack.tla intercepts for recovery).

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

Follower   == "Follower"
Candidate  == "Candidate"
Leader     == "Leader"

RequestVoteRequest   == "RequestVoteRequest"
RequestVoteResponse  == "RequestVoteResponse"
AppendEntriesRequest == "AppendEntriesRequest"
AppendEntriesResponse == "AppendEntriesResponse"

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

    \* Raft per-server variables.
    currentTerm,
    ostate,
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* Execution tracking variables.
    execution_cmds

serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars,
          execution_cmds>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Symmetry == Permutations(Server)

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

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

LogCmdIds ==
    UNION { {log[i][k].value.cmd_id : k \in 1..Len(log[i])} : i \in Server }

ExecCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(execution_cmds)}

UsedCmdIds == LogCmdIds \cup ExecCmdIds

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin UsedCmdIds}

LogCmdAt(i, k) == IF k <= Len(log[i]) THEN log[i][k].value ELSE NilCmd

MaxLogLen == Max({Len(log[i]) : i \in Server} \cup {0})

ExecAt(k) == IF k <= Len(execution_cmds) THEN execution_cmds[k] ELSE NilCmd

CommittedCmds(i) ==
    IF commitIndex[i] = 0 THEN <<>>
    ELSE [k \in 1..commitIndex[i] |-> log[i][k].value]

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
    /\ execution_cmds = <<>>

(***************************************************************************)
(* Raft transitions                                                        *)
(***************************************************************************)

Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, execution_cmds>>

Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, execution_cmds>>

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
                   execution_cmds>>

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
                   execution_cmds>>

BecomeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = Leader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   execution_cmds>>

ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ v \in Commands
    /\ LET entry == [term |-> currentTerm[i], value |-> v]
       IN log' = [log EXCEPT ![i] = Append(log[i], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, execution_cmds>>

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
                   execution_cmds>>

ApplyCommitted(i) ==
    /\ ostate[i] = Leader
    /\ commitIndex[i] > Len(execution_cmds)
    /\ LET nextExecIndex == Len(execution_cmds) + 1
           nextCmd == log[i][nextExecIndex].value
       IN execution_cmds' = Append(execution_cmds, nextCmd)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars>>

(***************************************************************************)
(* Message handlers                                                        *)
(***************************************************************************)

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
                      execution_cmds>>

HandleRequestVoteResponse(i, j, m) ==
    /\ m.mterm = currentTerm[i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] =
                              votesResponded[i] \cup {j}]
    /\ \/ /\ m.mvoteGranted
          /\ votesGranted' = [votesGranted EXCEPT ![i] =
                                  votesGranted[i] \cup {j}]
       \/ /\ ~m.mvoteGranted
          /\ UNCHANGED votesGranted
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, leaderVars, logVars, execution_cmds>>

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
             /\ ostate[i] = Candidate
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
       /\ UNCHANGED <<candidateVars, leaderVars, execution_cmds>>

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
    /\ UNCHANGED <<serverVars, candidateVars, logVars, execution_cmds>>

UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars,
                   execution_cmds>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   execution_cmds>>

Receive(m) ==
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

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   execution_cmds>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   execution_cmds>>

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : Timeout(i)
    \/ \E i, j \in Server : RequestVote(i, j)
    \/ \E i \in Server : BecomeLeader(i)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E i \in Server : ApplyCommitted(i)
    \/ \E i, j \in Server : AppendEntries(i, j)
    \/ \E i \in Server, v \in Commands : ClientRequest(i, v)
    \/ \E m \in DOMAIN messages : Receive(m)
    \/ \E m \in DOMAIN messages : DuplicateMessage(m)
    \/ \E m \in DOMAIN messages : DropMessage(m)

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 5
    /\ \A i \in Server : Len(log[i]) <= 4
    /\ Len(execution_cmds) <= 4

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 2
    /\ \A i \in Server : Len(log[i]) <= 2
    /\ Len(execution_cmds) <= 2

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* Committed entries at the same index agree across all servers.
CommittedLogAgreement ==
    \A i, j \in Server :
        LET ci == commitIndex[i]
            cj == commitIndex[j]
            limit == Min({ci, cj} \cup {0})
        IN \A k \in 1..limit :
            log[i][k] = log[j][k]

\* A leader for a given term is unique.
ElectionSafety ==
    \A i, j \in Server :
        (/\ ostate[i] = Leader
         /\ ostate[j] = Leader
         /\ currentTerm[i] = currentTerm[j])
        => (i = j)

MaxLogExecLen == Max({MaxLogLen, Len(execution_cmds)})

\* Logs agree at each index (using length guards to avoid TLC type errors).
LogAgreement ==
    /\ MaxLogLen >= 0
    /\ \A i, j \in Server :
         \A k \in 1..MaxLogLen :
            \/ k > Len(log[i])
            \/ k > Len(log[j])
            \/ log[i][k] = log[j][k]

\* Log order matches execution_cmds, allowing NilCmd for missing entries.
LogOrderMatchesExecution ==
    /\ MaxLogExecLen >= 0
    /\ \A i \in Server :
         \A k \in 1..MaxLogExecLen :
            LET lc == LogCmdAt(i, k)
                ec == ExecAt(k)
            IN \/ lc = ec
               \/ lc = NilCmd
               \/ ec = NilCmd

Safety == [](CommittedLogAgreement /\ ElectionSafety /\ LogOrderMatchesExecution)

SpecSafety == Spec => Safety

=============================================================================
