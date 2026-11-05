--------------------------- MODULE base_mongodb --------------------------------
\* MongoDB replication protocol with Raft single-server reconfig, adapted for
\* Jetpack composition.
\*
\* Ported from https://github.com/visualzhou/mongo-repl-tla
\* (RaftMongoWithRaftReconfig.tla) and reshaped to match the
\* base_raft.tla / base_copilot.tla / base_mencius.tla interface so
\* jetpack_mongodb_composition.tla can INSTANCE this module.
\*
\* Two paths into Jetpack recovery (the pseudocode (docs/pseudocode.md) T1-T2):
\*   1. Election:  Candidate -> ToBeLeader -> [recovery] -> Leader.
\*                 BecomeToBeLeader stages no pendingConfig.
\*   2. Reconfig:  Leader -> ToBeLeader (BeginReconfig stages
\*                 pendingConfig[i] := newConfig) -> AppendPendingConfigToLog
\*                 appends the config entry and extends configs while the
\*                 leader is paused -> [recovery in the NEW config, for the
\*                 view (term, index of that config entry)] -> Leader.
\* In both paths the wrapper's ResumeAfterRecovered (the proposer's own
\* Recovered(S) is committed) is what moves ToBeLeader -> Leader.
\*
\* Single-server membership change only: each Reconfig adds or removes at most
\* one server, and is gated on the previous config entry being committed and
\* an entry from the current term being committed.
\*
\* Log entries are [command, term, value] like base_raft's, because Jetpack
\* reads entry.command: AppendCommand entries carry a client command in value;
\* ConfigCommand entries carry value.configVersion (an index into configs).
\* The config a server operates under is the one of the latest ConfigCommand
\* entry in its log (RaftMongo tagged every entry with a configVersion
\* instead; Jetpack's own entries carry none, so the tag moved to the config
\* entry).
\*
\* 3-D Log: log[i]["sole"][k], commitIndex[i]["sole"] (single replication
\* stream, like Raft).
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex,
\*   configs, pendingConfig, electionCtr, restartCtr, reconfigCtr

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key,
          MaxElections, MaxRestarts, MaxReconfigs

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Log entry command tags.
AppendCommand == "AppendCommand"
ConfigCommand == "ConfigCommand"

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
    pendingConfig,
    electionCtr, restartCtr, reconfigCtr

serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
configVars    == <<configs, pendingConfig>>
auxVars       == <<electionCtr, restartCtr, reconfigCtr>>
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                   configs, pendingConfig, electionCtr, restartCtr, reconfigCtr>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term
LogTerm(i, index) == IF index = 0 THEN 0 ELSE log[i]["sole"][index].term

IsConfigEntry(e) == e.command = ConfigCommand

\* Index of the latest config entry in i's log, or 0 if none (the initial
\* config has no log entry).
LatestConfigIndex(i) ==
    LET idxs == {k \in 1..Len(log[i]["sole"]) : IsConfigEntry(log[i]["sole"][k])}
    IN IF idxs = {} THEN 0 ELSE Max(idxs)

\* Config version active at node i: that of its latest config entry, or 1
\* (the initial config) if it has none.
GetConfigVersion(i) ==
    IF LatestConfigIndex(i) = 0
    THEN 1
    ELSE log[i]["sole"][LatestConfigIndex(i)].value.configVersion

\* The members of the config that node i is currently operating under.
ServerViewOn(i) == configs[GetConfigVersion(i)]

\* Quorums of i's current config view.
Quorum(i) == {q \in SUBSET(ServerViewOn(i)) :
                  Cardinality(q) * 2 > Cardinality(ServerViewOn(i))}

\* Whether the previous config entry committed (or is the initial config,
\* which is committed by definition).
PrevConfigCommitted(i) ==
    \/ LatestConfigIndex(i) = 0  \* initial config: no log entry, vacuously committed
    \/ commitIndex[i]["sole"] >= LatestConfigIndex(i)

\* Whether the leader has committed an entry in its current term.
SomeEntryCommittedInCurrentTerm(i) ==
    \E k \in 1..commitIndex[i]["sole"] :
        log[i]["sole"][k].term = currentTerm[i]

\* Unsound with the CHOOSE'd initial primary below; kept for configs that
\* want it and know that.
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

\* One server starts as the primary of term 1 (as base_raft's InitBaseVars
\* does): it is the proposer of Jetpack's initial view. Logs start empty.
InitBaseVars ==
    LET leader == CHOOSE i \in Server : TRUE
    IN
        /\ messages = [m \in {} |-> 0]
        /\ currentTerm = [i \in Server |-> 1]
        /\ ostate = [i \in Server |-> IF i = leader THEN Leader ELSE Follower]
        /\ votedFor = [i \in Server |-> Nil]
        /\ log = [i \in Server |-> [x \in {"sole"} |-> <<>>]]
        /\ commitIndex = [i \in Server |-> [x \in {"sole"} |-> 0]]
        /\ votesResponded = [i \in Server |-> {}]
        /\ votesGranted = [i \in Server |-> {}]
        /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
        /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
        /\ configs = << Server >>
        /\ pendingConfig = [i \in Server |-> Nil]
        /\ electionCtr = 0
        /\ restartCtr = 0
        /\ reconfigCtr = 0

(***************************************************************************)
(* MongoDB transitions                                                     *)
(***************************************************************************)

Restart(i) ==
    /\ restartCtr < MaxRestarts
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = [x \in {"sole"} |-> 0]]
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ restartCtr' = restartCtr + 1
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, configs,
                   electionCtr, reconfigCtr>>

Timeout(i) ==
    /\ electionCtr < MaxElections
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ electionCtr' = electionCtr + 1
    /\ UNCHANGED <<messages, leaderVars, logVars, configVars,
                   restartCtr, reconfigCtr>>

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
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars,
                   auxVars>>

\* Pull-based replication: follower i copies one entry from peer j's oplog.
\* Equivalent to RaftMongo's AppendOplog, including its Follower guard (a
\* primary, paused or not, is append-only; no primary catch-up). j must be
\* in i's config view.
AppendOplog(i, j) ==
    /\ ostate[i] = Follower
    /\ i /= j
    /\ j \in ServerViewOn(i)
    /\ Len(log[i]["sole"]) < Len(log[j]["sole"])
    /\ LastTerm(log[i]["sole"]) = LogTerm(j, Len(log[i]["sole"]))
    /\ log' = [log EXCEPT ![i]["sole"] =
                   Append(log[i]["sole"],
                          log[j]["sole"][Len(log[i]["sole"]) + 1])]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars, auxVars>>

CanRollbackOplog(i, j) ==
    /\ j \in ServerViewOn(i)
    /\ Len(log[i]["sole"]) > 0
    /\ LastTerm(log[i]["sole"]) < LastTerm(log[j]["sole"])
    /\ \/ Len(log[i]["sole"]) > Len(log[j]["sole"])
       \/ /\ Len(log[i]["sole"]) <= Len(log[j]["sole"])
          /\ LastTerm(log[i]["sole"]) /= LogTerm(j, Len(log[i]["sole"]))

\* Follower i rewinds one oplog entry when its tail doesn't match j's. Only
\* a Follower rolls back: a stale primary steps down (UpdateTerm) first, so
\* an (index, term) pair names one entry (Log Matching).
RollbackOplog(i, j) ==
    /\ ostate[i] = Follower
    /\ CanRollbackOplog(i, j)
    /\ LET new == [index2 \in 1..(Len(log[i]["sole"]) - 1) |-> log[i]["sole"][index2]]
       IN log' = [log EXCEPT ![i]["sole"] = new]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars, auxVars>>

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
                   configVars, auxVars>>

\* Leader stages a single-server membership change and pauses (the pseudocode T1).
\* The config entry is appended next by AppendPendingConfigToLog, while the
\* leader is still paused; it starts the new view, and Jetpack recovery for
\* that view runs before the leader resumes.
BeginReconfig(i, newConfig) ==
    /\ reconfigCtr < MaxReconfigs
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
    /\ reconfigCtr' = reconfigCtr + 1
    \* Reset replication bookkeeping for the upcoming recovery, mirroring
    \* what BecomeToBeLeader does on the election path.
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]["sole"]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   configs, electionCtr, restartCtr>>

\* Emits the config entry while the leader is paused (ToBeLeader) and
\* extends configs with the staged member set; the entry starts the new view
\* (term, its index), and Jetpack's recovery for it runs next. cmd_id/key
\* sentinels keep the value shape uniform with the other entry kinds.
AppendPendingConfigToLog(i) ==
    /\ ostate[i] = ToBeLeader
    /\ pendingConfig[i] /= Nil
    /\ LET newCV == Len(configs) + 1
           entry == [command |-> ConfigCommand,
                     term    |-> currentTerm[i],
                     value   |-> [cmd_id        |-> Nil,
                                  key           |-> Nil,
                                  configVersion |-> newCV]]
       IN /\ log' = [log EXCEPT ![i]["sole"] = Append(log[i]["sole"], entry)]
          /\ configs' = Append(configs, pendingConfig[i])
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, auxVars>>

\* Primary accepts a client write: append to its own oplog. Only a Leader
\* proposes; a paused one (ToBeLeader, the pseudocode T1) queues until it resumes.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ pendingConfig[i] = Nil
    /\ v \in Commands
    /\ LET entry == [command |-> AppendCommand,
                     term    |-> currentTerm[i],
                     value   |-> v]
       IN log' = [log EXCEPT ![i]["sole"] = Append(log[i]["sole"], entry)]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars,
                   commitIndex, configVars, auxVars>>

\* Primary advances its commit index when a quorum of its config view has
\* replicated the tail. Committing keeps running while the primary is paused
\* by Jetpack (ToBeLeader, the pseudocode (docs/pseudocode.md) T1-T2): it must commit its own
\* Recovered entry (and a config entry) to resume. Only proposing new client
\* commands (ClientRequest, BeginReconfig) waits.
\* A member counts toward commitment only while it is in the primary's term:
\* in MongoDB a member that has moved to a newer term reports that term with
\* its position and the primary steps down instead of advancing the commit
\* point (MongoStaticRaft / MongoRaftReconfig: CommitEntry requires
\* currentTerm[s] = currentTerm[i] for every s in the quorum). Without it a
\* member that voted in a newer term and then pulled an entry from the old
\* primary would let that primary commit an entry the new term rolls back.
AdvanceCommitIndex(i) ==
    /\ ostate[i] \in {Leader, ToBeLeader}
    /\ LET Agree(index) ==
               {i} \cup {k \in ServerViewOn(i) :
                           /\ currentTerm[k] = currentTerm[i]
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
                   configVars, auxVars>>

\* Follower i learns the commit point from peer j (heartbeat-like). Only
\* moves forward; never beyond i's own log, and only when i's log agrees
\* with j's at the learned point (Log Matching then gives the whole prefix):
\* a follower whose tail diverges rolls back first.
LearnCommitPoint(i, j) ==
    /\ i /= j
    /\ j \in ServerViewOn(i)
    /\ commitIndex[j]["sole"] > commitIndex[i]["sole"]
    /\ LET bounded == Min({commitIndex[j]["sole"], Len(log[i]["sole"])})
       IN /\ bounded > commitIndex[i]["sole"]
          /\ LogTerm(i, bounded) = LogTerm(j, bounded)
          /\ commitIndex' = [commitIndex EXCEPT ![i]["sole"] = bounded]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   configVars, auxVars>>

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
                      configVars, auxVars>>

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
    /\ UNCHANGED <<serverVars, leaderVars, logVars, configVars, auxVars>>

\* Term update via a vote message. Demotes leader to follower; clears any
\* pending reconfig the leader had staged (it can no longer drive recovery).
UpdateTerm(i, j, m) ==
    /\ m.mterm > currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = m.mterm]
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votedFor' = [votedFor EXCEPT ![i] = Nil]
    /\ pendingConfig' = [pendingConfig EXCEPT ![i] = Nil]
    /\ UNCHANGED <<messages, candidateVars, leaderVars, logVars, configs,
                   auxVars>>

DropStaleResponse(i, j, m) ==
    /\ m.mterm < currentTerm[i]
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars,
                   auxVars>>

(***************************************************************************)
(* MongoDB message receive dispatch                                        *)
(***************************************************************************)

\* Callers must check m.mtype \in MongoDbMessageTypes first: UpdateTerm reads
\* m.mterm, which Jetpack messages do not carry.
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
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars,
                   auxVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, configVars,
                   auxVars>>

=============================================================================
