--------------------------- MODULE base_mongodb --------------------------------
\* MongoDB replication protocol adapted for Jetpack composition.
\*
\* Ported from https://github.com/visualzhou/mongo-repl-tla (RaftMongo.tla)
\* and reshaped to match the base_raft.tla / base_copilot.tla / base_mencius.tla
\* interface so jetpack_mongodb_composition.tla can INSTANCE this module.
\*
\* Key differences from standalone mongodb.tla:
\*   - BecomePrimaryByMagic is replaced with BecomeToBeLeader (Candidate ->
\*     ToBeLeader). Jetpack recovery must finish before the node becomes Leader.
\*   - 3-D Log: log[i]["sole"][k], commitIndex[i]["sole"] — MongoDB, like
\*     Raft, uses a single replication stream ("sole" proposer).
\*   - No execution_cmds or ApplyCommitted (delegated to wrapper/Jetpack).
\*
\* MongoDB's replication model:
\*   - Followers PULL oplog entries from a sync source (peer) rather than
\*     the leader pushing (as in Raft's AppendEntries). AppendOplog here
\*     models one entry being copied.
\*   - RollbackOplog: a follower can rewind when its oplog diverges from a
\*     peer with a higher-term log.
\*   - Commit point learning: followers eventually learn the committed
\*     index from the sync source.
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

\* MongoDB replication message types. MongoDB's replication is pull-based,
\* so AppendOplog / RollbackOplog / LearnCommitPoint are direct peer-to-peer
\* transitions without RPCs; the message bag is retained only for Jetpack
\* interoperability and for the heartbeat-style election messages.
RequestVoteRequest  == "RequestVoteRequest"
RequestVoteResponse == "RequestVoteResponse"

MongoDbMessageTypes == {RequestVoteRequest, RequestVoteResponse}

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
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term
LogTerm(i, index) == IF index = 0 THEN 0 ELSE log[i]["sole"][index].term

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
    /\ log = [i \in Server |-> [x \in {"sole"} |-> <<>>]]
    /\ commitIndex = [i \in Server |-> [x \in {"sole"} |-> 0]]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]

(***************************************************************************)
(* MongoDB transitions                                                     *)
(***************************************************************************)

Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = [x \in {"sole"} |-> 0]]
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

\* Pull-based replication: follower i copies one entry from peer j's oplog.
\* Equivalent to RaftMongo's AppendOplog.
AppendOplog(i, j) ==
    /\ i /= j
    /\ Len(log[i]["sole"]) < Len(log[j]["sole"])
    /\ LastTerm(log[i]["sole"]) = LogTerm(j, Len(log[i]["sole"]))
    /\ log' = [log EXCEPT ![i]["sole"] =
                   Append(log[i]["sole"],
                          log[j]["sole"][Len(log[i]["sole"]) + 1])]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, commitIndex>>

CanRollbackOplog(i, j) ==
    /\ Len(log[i]["sole"]) > 0
    /\ LastTerm(log[i]["sole"]) < LastTerm(log[j]["sole"])
    /\ \/ Len(log[i]["sole"]) > Len(log[j]["sole"])
       \/ /\ Len(log[i]["sole"]) <= Len(log[j]["sole"])
          /\ LastTerm(log[i]["sole"]) /= LogTerm(j, Len(log[i]["sole"]))

\* Follower i rewinds one oplog entry when its tail doesn't match j's (j has
\* a strictly higher last term).
RollbackOplog(i, j) ==
    /\ CanRollbackOplog(i, j)
    /\ LET new == [index2 \in 1..(Len(log[i]["sole"]) - 1) |-> log[i]["sole"][index2]]
       IN log' = [log EXCEPT ![i]["sole"] = new]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, commitIndex>>

\* Candidate transitions to ToBeLeader; Jetpack recovery must finish before
\* the node becomes Leader. Equivalent of RaftMongo's BecomePrimaryByMagic.
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars>>

\* Empty view change: forces server i into ToBeLeader so the Jetpack
\* composition's recovery can fire. MongoDB is raft-like: it has an
\* election (BecomePrimaryByMagic, wrapped as BecomeToBeLeader above),
\* but no separate whole-ensemble view-change protocol — if the primary
\* loses quorum mid-operation, the uncommitted oplog tail is rolled back
\* and a new primary is elected. This action exposes a no-op hook that
\* the Jetpack composition can use to trigger recovery independently of
\* the election path. Can be enabled from any state other than ToBeLeader.
EmptyViewChange(i) ==
    /\ ostate[i] /= ToBeLeader
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, votedFor, candidateVars, logVars>>

\* Primary accepts a client write: append to its own oplog.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ v \in Commands
    /\ LET entry == [term |-> currentTerm[i], value |-> v]
       IN log' = [log EXCEPT ![i]["sole"] = Append(log[i]["sole"], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, commitIndex>>

\* Primary advances its commit index when a majority has replicated the tail.
AdvanceCommitIndex(i) ==
    /\ ostate[i] = Leader
    /\ LET Agree(index) ==
               {i} \cup {k \in Server :
                           /\ Len(log[k]["sole"]) >= index
                           /\ LogTerm(i, index) = LogTerm(k, index)}
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

\* Follower i learns the commit point from peer j (heartbeat-like). Only
\* moves forward; never beyond the follower's own last-applied index.
LearnCommitPoint(i, j) ==
    /\ i /= j
    /\ commitIndex[j]["sole"] > commitIndex[i]["sole"]
    /\ LET bounded == Min({commitIndex[j]["sole"], Len(log[i]["sole"])})
       IN commitIndex' = [commitIndex EXCEPT ![i]["sole"] = bounded]
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
(* MongoDB message receive dispatch                                        *)
(***************************************************************************)

MongoDbReceive(m) ==
    LET i == m.mdest
        j == m.msource
    IN \/ UpdateTerm(i, j, m)
       \/ /\ m.mtype = RequestVoteRequest
          /\ HandleRequestVoteRequest(i, j, m)
       \/ /\ m.mtype = RequestVoteResponse
          /\ \/ DropStaleResponse(i, j, m)
             \/ HandleRequestVoteResponse(i, j, m)

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
