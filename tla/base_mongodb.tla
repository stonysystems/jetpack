--------------------------- MODULE base_mongodb --------------------------------
\* MongoDB replication protocol with Raft single-server reconfig, adapted for
\* Jetpack composition.
\*
\* Ported from https://github.com/visualzhou/mongo-repl-tla
\* (RaftMongoWithRaftReconfig.tla) and reshaped to match the
\* base_raft.tla / base_copilot.tla / base_mencius.tla interface so
\* jetpack_mongodb_composition.tla can INSTANCE this module.
\*
\* Two paths into Jetpack recovery:
\*   1. Election:  Candidate -> ToBeLeader -> [recovery] -> Leader.
\*                 BecomeToBeLeader stages no pendingConfig.
\*   2. Reconfig:  Leader -> ToBeLeader -> [recovery in OLD config] -> Leader,
\*                 with the new config entry appended at the resume step.
\*                 BeginReconfig stages pendingConfig[i] := newConfig.
\* Recovery runs against the OLD config in the reconfig path because the
\* config entry is not appended (and configs is not extended) until the
\* composition-level FinishReconfig action fires.
\*
\* Single-server membership change only: each Reconfig adds or removes at most
\* one server, and is gated on the previous config entry being committed and
\* an entry from the current term being committed.
\*
\* 3-D Log: log[i]["sole"][k], commitIndex[i]["sole"] (single replication
\* stream, like Raft).
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex,
\*   configs, pendingConfig

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* MongoDB replication message types. Pull-based replication uses no RPCs;
\* the message bag carries vote messages only.
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
    matchIndex,
    configs,
    pendingConfig

serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
configVars    == <<configs, pendingConfig>>
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                   configs, pendingConfig>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term
LogTerm(i, index) == IF index = 0 THEN 0 ELSE log[i]["sole"][index].term

\* Config version active at node i: the configVersion of i's last log entry,
\* or 1 if i's log is empty (initial config).
GetConfigVersion(i) ==
    IF Len(log[i]["sole"]) = 0
    THEN 1
    ELSE log[i]["sole"][Len(log[i]["sole"])].configVersion

\* Index of i's first log entry with the given configVersion, or 0 if none
\* (the initial config has no log entry).
GetConfigEntry(i, cv) ==
    LET idxs == {k \in 1..Len(log[i]["sole"]) :
                    log[i]["sole"][k].configVersion = cv}
    IN IF idxs = {} THEN 0 ELSE Min(idxs)

\* The members of the config that node i is currently operating under.
ServerViewOn(i) == configs[GetConfigVersion(i)]

\* Quorums of i's current config view.
Quorum(i) == {q \in SUBSET(ServerViewOn(i)) :
                  Cardinality(q) * 2 > Cardinality(ServerViewOn(i))}

\* Whether the previous config entry committed (or is the initial config,
\* which is committed by definition).
PrevConfigCommitted(i) ==
    LET cv == GetConfigVersion(i)
        idx == GetConfigEntry(i, cv)
    IN \/ idx = 0  \* initial config: no log entry, vacuously committed
       \/ commitIndex[i]["sole"] >= idx

\* Whether the leader has committed an entry in its current term.
SomeEntryCommittedInCurrentTerm(i) ==
    \E k \in 1..commitIndex[i]["sole"] :
        log[i]["sole"][k].term = currentTerm[i]

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
    /\ configs = << Server >>
    /\ pendingConfig = [i \in Server |-> Nil]

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
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, configs>>

Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, configVars>>

RequestVote(i, j) ==
    /\ ostate[i] = Candidate
    /\ i /= j
    /\ j \in ServerViewOn(i)
    /\ j \notin votesResponded[i]
    /\ Send([mtype         |-> RequestVoteRequest,
             mterm         |-> currentTerm[i],
             mlastLogTerm  |-> LastTerm(log[i]["sole"]),
             mlastLogIndex |-> Len(log[i]["sole"]),
             msource       |-> i,
             mdest         |-> j])
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars>>

\* Pull-based replication: follower i copies one entry from peer j's oplog.
\* Equivalent to RaftMongo's AppendOplog. j must be in i's config view.
AppendOplog(i, j) ==
    /\ i /= j
    /\ j \in ServerViewOn(i)
    /\ Len(log[i]["sole"]) < Len(log[j]["sole"])
    /\ LastTerm(log[i]["sole"]) = LogTerm(j, Len(log[i]["sole"]))
    /\ log' = [log EXCEPT ![i]["sole"] =
                   Append(log[i]["sole"],
                          log[j]["sole"][Len(log[i]["sole"]) + 1])]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars>>

CanRollbackOplog(i, j) ==
    /\ j \in ServerViewOn(i)
    /\ Len(log[i]["sole"]) > 0
    /\ LastTerm(log[i]["sole"]) < LastTerm(log[j]["sole"])
    /\ \/ Len(log[i]["sole"]) > Len(log[j]["sole"])
       \/ /\ Len(log[i]["sole"]) <= Len(log[j]["sole"])
          /\ LastTerm(log[i]["sole"]) /= LogTerm(j, Len(log[i]["sole"]))

\* Follower i rewinds one oplog entry when its tail doesn't match j's.
RollbackOplog(i, j) ==
    /\ CanRollbackOplog(i, j)
    /\ LET new == [index2 \in 1..(Len(log[i]["sole"]) - 1) |-> log[i]["sole"][index2]]
       IN log' = [log EXCEPT ![i]["sole"] = new]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars>>

\* Candidate transitions to ToBeLeader; Jetpack recovery must finish before
\* the node becomes Leader. Election path: pendingConfig stays Nil.
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum(i)
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   configVars>>

\* Leader stages a single-server membership change and pauses for Jetpack
\* recovery to run in the OLD config. The config entry is NOT appended yet
\* and configs is NOT extended yet — that happens at FinishReconfig (in the
\* composition), atomically with the resume to Leader.
BeginReconfig(i, newConfig) ==
    /\ ostate[i] = Leader
    /\ pendingConfig[i] = Nil
    /\ i \in newConfig
    /\ newConfig \subseteq Server
    \* Single-server change only.
    /\ Cardinality(ServerViewOn(i) \ newConfig) +
       Cardinality(newConfig \ ServerViewOn(i)) <= 1
    /\ newConfig /= ServerViewOn(i)
    \* Standard Raft preconditions: previous config committed, and an entry
    \* from the current term is committed.
    /\ PrevConfigCommitted(i)
    /\ SomeEntryCommittedInCurrentTerm(i)
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = newConfig]
    \* Reset replication bookkeeping for the upcoming recovery, mirroring
    \* what BecomeToBeLeader does on the election path.
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   configs>>

\* Primary accepts a client write: append to its own oplog. Tagged with the
\* current config version so followers know which config it belongs to.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ pendingConfig[i] = Nil
    /\ v \in Commands
    /\ LET entry == [term |-> currentTerm[i],
                     value |-> v,
                     configVersion |-> GetConfigVersion(i)]
       IN log' = [log EXCEPT ![i]["sole"] = Append(log[i]["sole"], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars>>

\* Primary advances its commit index when a quorum of its config view has
\* replicated the tail.
AdvanceCommitIndex(i) ==
    /\ ostate[i] = Leader
    /\ LET Agree(index) ==
               {i} \cup {k \in ServerViewOn(i) :
                           /\ Len(log[k]["sole"]) >= index
                           /\ LogTerm(i, index) = LogTerm(k, index)}
           agreeIndexes == {index \in 1..Len(log[i]["sole"]) :
                                Agree(index) \in Quorum(i)}
           newCommitIndex ==
              IF /\ agreeIndexes /= {}
                 /\ log[i]["sole"][Max(agreeIndexes)].term = currentTerm[i]
              THEN
                  Max(agreeIndexes)
              ELSE
                  commitIndex[i]["sole"]
       IN commitIndex' = [commitIndex EXCEPT ![i]["sole"] = newCommitIndex]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   configVars>>

\* Follower i learns the commit point from peer j (heartbeat-like). Only
\* moves forward; never beyond i's own last-applied index.
LearnCommitPoint(i, j) ==
    /\ i /= j
    /\ j \in ServerViewOn(i)
    /\ commitIndex[j]["sole"] > commitIndex[i]["sole"]
    /\ LET bounded == Min({commitIndex[j]["sole"], Len(log[i]["sole"])})
       IN commitIndex' = [commitIndex EXCEPT ![i]["sole"] = bounded]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   configVars>>

(***************************************************************************)
(* Message handlers                                                        *)
(***************************************************************************)

HandleRequestVoteRequest(i, j, m) ==
    LET logOk == \/ m.mlastLogTerm > LastTerm(log[i]["sole"])
                 \/ /\ m.mlastLogTerm = LastTerm(log[i]["sole"])
                    /\ m.mlastLogIndex >= Len(log[i]["sole"])
        \* Voter only votes for candidates in its own config view.
        senderInView == j \in ServerViewOn(i)
        grant == /\ m.mterm = currentTerm[i]
                 /\ logOk
                 /\ votedFor[i] \in {Nil, j}
                 /\ senderInView
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
       /\ UNCHANGED <<ostate, currentTerm, candidateVars, leaderVars, logVars,
                      configVars>>

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
    /\ UNCHANGED <<serverVars, leaderVars, logVars, configVars>>

\* Term update via a vote message. Demotes leader to follower; clears any
\* pending reconfig the leader had staged (it can no longer drive recovery).
UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars, configs>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars>>

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
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars>>

=============================================================================
