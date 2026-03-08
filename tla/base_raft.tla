------------------------------ MODULE base_raft --------------------------------
\* Raft consensus protocol adapted for Jetpack composition.
\*
\* This module contains the Raft protocol state machine with the ToBeLeader
\* state (intercepted by Jetpack for recovery). It is designed to be
\* INSTANCE'd by a wrapper module that composes it with jetpack.tla.
\*
\* Key differences from standalone raft.tla:
\*   - BecomeToBeLeader: Candidate -> ToBeLeader (not -> Leader)
\*   - HandleAppendEntriesRequest steps down from {Candidate, ToBeLeader}
\*   - No execution_cmds or ApplyCommitted (delegated to wrapper/Jetpack)
\*
\* 3-D Log: log[i]["sole"][k], commitIndex[i]["sole"]
\* Raft uses a single proposer "sole" — all entries belong to one sequence.
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Raft message types.
RequestVoteRequest    == "RequestVoteRequest"
RequestVoteResponse   == "RequestVoteResponse"
AppendEntriesRequest  == "AppendEntriesRequest"
AppendEntriesResponse == "AppendEntriesResponse"

RaftMessageTypes == {RequestVoteRequest, RequestVoteResponse,
                     AppendEntriesRequest, AppendEntriesResponse}

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
    matchIndex

serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
raftVars      == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

Symmetry == Permutations(Server)

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

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

InitBaseVars ==
    /\ messages = [m \in {} |-> 0]
    /\ currentTerm = [i \in Server |-> 1]
    /\ ostate = [i \in Server |-> Follower]
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> ["sole" |-> <<>>]]
    /\ commitIndex = [i \in Server |-> ["sole" |-> 0]]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]

(***************************************************************************)
(* Raft transitions                                                        *)
(***************************************************************************)

Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = ["sole" |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log>>

Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars>>

RequestVote(i, j) ==
    /\ ostate[i] = Candidate
    /\ i /= j
    /\ j \notin votesResponded[i]
    /\ Send([mtype         |-> RequestVoteRequest,
             mterm         |-> currentTerm[i],
             mlastLogTerm  |-> LastTerm(log[i]["sole"]),
             mlastLogIndex |-> Len(log[i]["sole"]),
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

AppendEntries(i, j) ==
    /\ i /= j
    /\ ostate[i] = Leader
    /\ LET prevLogIndex == nextIndex[i][j] - 1
           prevLogTerm == IF prevLogIndex > 0 THEN
                              log[i]["sole"][prevLogIndex].term
                          ELSE
                              0
           lastEntry == Min({Len(log[i]["sole"]), nextIndex[i][j]})
           entries == SubSeq(log[i]["sole"], nextIndex[i][j], lastEntry)
       IN Send([mtype          |-> AppendEntriesRequest,
                mterm          |-> currentTerm[i],
                mprevLogIndex  |-> prevLogIndex,
                mprevLogTerm   |-> prevLogTerm,
                mentries       |-> entries,
                mlog           |-> log[i]["sole"],
                mcommitIndex   |-> Min({commitIndex[i]["sole"], lastEntry}),
                msource        |-> i,
                mdest          |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

\* Candidate transitions to ToBeLeader; Jetpack recovery must finish
\* before the node becomes Leader.
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars>>

ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ v \in Commands
    /\ LET entry == [term |-> currentTerm[i], value |-> v]
       IN log' = [log EXCEPT ![i]["sole"] = Append(log[i]["sole"], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, commitIndex>>

AdvanceCommitIndex(i) ==
    /\ ostate[i] = Leader
    /\ LET Agree(index) == {i} \cup {k \in Server : matchIndex[i][k] >= index}
           agreeIndexes == {index \in 1..Len(log[i]["sole"]) : Agree(index) \in Quorum}
           newCommitIndex ==
              IF /\ agreeIndexes /= {}
                 /\ log[i]["sole"][Max(agreeIndexes)].term = currentTerm[i]
              THEN
                  Max(agreeIndexes)
              ELSE
                  commitIndex[i]["sole"]
       IN commitIndex' = [commitIndex EXCEPT ![i]["sole"] = newCommitIndex]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log>>

(***************************************************************************)
(* Message handlers                                                        *)
(***************************************************************************)

HandleRequestVoteRequest(i, j, m) ==
    LET logOk == \/ m.mlastLogTerm > LastTerm(log[i]["sole"])
                 \/ /\ m.mlastLogTerm = LastTerm(log[i]["sole"])
                    /\ m.mlastLogIndex >= Len(log[i]["sole"])
        grant == /\ m.mterm = currentTerm[i]
                 /\ logOk
                 /\ votedFor[i] \in {Nil, j}
    IN /\ m.mterm <= currentTerm[i]
       /\ \/ grant  /\ votedFor' = [votedFor EXCEPT ![i] = j]
          \/ ~grant /\ UNCHANGED votedFor
       /\ Reply([mtype        |-> RequestVoteResponse,
                 mterm        |-> currentTerm[i],
                 mvoteGranted |-> grant,
                 mlog         |-> log[i]["sole"],
                 msource      |-> i,
                 mdest        |-> j],
                 m)
       /\ UNCHANGED <<ostate, currentTerm, candidateVars, leaderVars, logVars>>

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
    /\ UNCHANGED <<serverVars, leaderVars, logVars>>

HandleAppendEntriesRequest(i, j, m) ==
    LET logOk == \/ m.mprevLogIndex = 0
                 \/ /\ m.mprevLogIndex > 0
                    /\ m.mprevLogIndex <= Len(log[i]["sole"])
                    /\ m.mprevLogTerm = log[i]["sole"][m.mprevLogIndex].term
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
                             /\ Len(log[i]["sole"]) >= index
                             /\ log[i]["sole"][index].term = m.mentries[1].term
                       /\ commitIndex' = [commitIndex EXCEPT ![i]["sole"] =
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
                       /\ Len(log[i]["sole"]) >= index
                       /\ log[i]["sole"][index].term /= m.mentries[1].term
                       /\ LET new == [index2 \in 1..(Len(log[i]["sole"]) - 1) |->
                                          log[i]["sole"][index2]]
                          IN log' = [log EXCEPT ![i]["sole"] = new]
                       /\ UNCHANGED <<serverVars, commitIndex, messages>>
                   \/ \* no conflict: append entry
                       /\ m.mentries /= <<>>
                       /\ Len(log[i]["sole"]) = m.mprevLogIndex
                       /\ log' = [log EXCEPT ![i]["sole"] =
                                      Append(log[i]["sole"], m.mentries[1])]
                       /\ UNCHANGED <<serverVars, commitIndex, messages>>
       /\ UNCHANGED <<candidateVars, leaderVars>>

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
    /\ UNCHANGED <<serverVars, candidateVars, logVars>>

UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

(***************************************************************************)
(* Raft message receive dispatch                                           *)
(***************************************************************************)

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
(* Message plumbing                                                        *)
(***************************************************************************)

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

=============================================================================
