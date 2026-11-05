-------------------------- MODULE jetpack_mongodb_composition --------------------------
\* Composition of Jetpack (jetpack.tla, written from the pseudocode (docs/pseudocode.md)) with
\* MongoDB replication (base_mongodb.tla, with Raft single-server reconfig).
\*
\* This wrapper:
\*   1. Declares the union of all variables (base + Jetpack + client + execution).
\*   2. INSTANCEs base_mongodb.tla and jetpack.tla, mapping variables.
\*   3. Wraps base_mongodb actions with UNCHANGED <<jetpackVars, clientVars,
\*      executionVars>> and Jetpack actions with UNCHANGED mongodbVars (which
\*      includes configs and pendingConfig, so Jetpack does not touch them).
\*   4. Supplies the MongoDB view (the pseudocode §0 / Q16): id = (term, index of the
\*      latest config entry), encoded as term * EpochStride + index; members =
\*      the config of that entry (configs[cv]); proposers = {primary}. The
\*      initial config has no log entry, so the initial view is (1, 0).
\*   5. Supplies the trigger (the pseudocode T1): a server that became ToBeLeader (won an
\*      election, or appended a config entry as a paused primary) starts a
\*      coordinator for ViewOf(i) before appending any other entry; it becomes
\*      Leader again when its own Recovered(S) commits (J!ResumeAfterRecovered,
\*      T2). While ToBeLeader, followers still pull from it (AppendOplog) and
\*      it still commits (AdvanceCommitIndex), but it proposes no client
\*      command.
\*
\* Jetpack recovery has two entry points, both routed through ostate=ToBeLeader:
\*   1. Election:   BecomeToBeLeader (Candidate -> ToBeLeader) -> WStartRecovery
\*                  -> ... -> WResumeAfterRecovered.
\*   2. Reconfig:   BeginReconfig (Leader -> ToBeLeader, stage pendingConfig)
\*                  -> WAppendPendingConfigToLog (config entry; starts the
\*                  view (term, its index)) -> WStartRecovery -> ... ->
\*                  WResumeAfterRecovered.
\* Recovery in the reconfig path runs in the NEW config, after the config
\* entry: BeginRecovery goes to replicas(v), Prepare/Accept to replicas(v_n).
\*
\* MongoDB uses a single proposer "sole" — all entries belong to one sequence.

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, Client, CmdId, Key,
          MaxElections, MaxRestarts, MaxReconfigs

(****************************************************************************)
(* Variables                                                                *)
(****************************************************************************)

VARIABLES
    messages,

    \* Base protocol interface (shared with Jetpack).
    currentTerm,
    ostate,
    log,
    commitIndex,

    \* MongoDB-specific variables.
    votedFor,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* Reconfig variables (MongoDB-specific; Jetpack does not touch).
    configs,
    pendingConfig,
    electionCtr, restartCtr, reconfigCtr,

    \* Jetpack per-server variables.
    rstate, cstate, subm,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from, client_issued,

    \* Execution tracking.
    original_execution_cmds, execution_cmds, applied, fast_committed

\* Variable groups for UNCHANGED clauses.
mongodbVars   == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                   configs, pendingConfig, electionCtr, restartCtr, reconfigCtr>>
serverVars    == <<currentTerm, ostate, votedFor>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
configVars    == <<configs, pendingConfig>>
auxVars       == <<electionCtr, restartCtr, reconfigCtr>>
jetpackVars   == <<rstate, cstate, subm>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from, client_issued>>
executionVars == <<original_execution_cmds, execution_cmds, applied, fast_committed>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars, configVars,
          auxVars, jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* MongoDB view ids (the pseudocode Q16): (term, latest config index), lexicographic.   *)
(****************************************************************************)

EpochStride == 16                       \* > any log index reachable under the constraints
EpochOf(term, cfgIndex) == term * EpochStride + cfgIndex

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_mongodb

\* MongoDB: single proposer "sole"; every server is a member of the initial
\* config (configs = <<Server>>); the initial view's proposer is the initial
\* primary chosen by B!InitBaseVars (the same CHOOSE expression); the initial
\* config has no log entry, so the initial view is (term 1, index 0).
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "MongoDbNoOp"],
                          InitialMembers <- Server,
                          Proposer <- {"sole"},
                          ProposerOf <- LAMBDA i : "sole",
                          InitialProposers <- {CHOOSE i \in Server : TRUE},
                          InitialEpoch <- EpochOf(1, 0)

(****************************************************************************)
(* Re-exported constants                                                    *)
(****************************************************************************)

Nil          == B!Nil
Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader

\* The view server i starts as a new proposer (T1): its current term, the
\* index of the latest config entry in its log, that config's members.
ViewOf(i) ==
    [epoch |-> EpochOf(currentTerm[i], B!LatestConfigIndex(i)),
     replica_ids |-> B!ServerViewOn(i),
     proposing_replica_ids |-> {i}]

(****************************************************************************)
(* Initialization                                                           *)
(****************************************************************************)

Init ==
    /\ B!InitBaseVars
    /\ J!InitJetpackVars
    /\ J!InitClientVars
    /\ J!InitExecutionVars

(****************************************************************************)
(* Wrapped base protocol transitions                                        *)
(****************************************************************************)

\* Restart keeps Jetpack's state: it is persisted with the base's (the pseudocode §0
\* Persistence, Q15).
Restart(i) ==
    /\ B!Restart(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

Timeout(i) ==
    /\ B!Timeout(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RequestVote(i, j) ==
    /\ B!RequestVote(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AppendOplog(i, j) ==
    /\ B!AppendOplog(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RollbackOplog(i, j) ==
    /\ B!RollbackOplog(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

LearnCommitPoint(i, j) ==
    /\ B!LearnCommitPoint(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Election entry into recovery: Candidate -> ToBeLeader.
BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Reconfiguration (the pseudocode T1–T2, Q11): the primary pauses (ToBeLeader), appends
\* the config entry, and that entry starts the new view (term, its index);
\* WStartRecovery then runs Jetpack recovery for it.
WBeginReconfig(i, newConfig) ==
    /\ B!BeginReconfig(i, newConfig)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

WAppendPendingConfigToLog(i) ==
    /\ B!AppendPendingConfigToLog(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped MongoDB message handlers                                         *)
(****************************************************************************)

\* Guarded by message type: B!MongoDbReceive reads m.mterm, which Jetpack
\* messages do not carry.
MongoDbReceive(m) ==
    /\ m.mtype \in B!MongoDbMessageTypes
    /\ B!MongoDbReceive(m)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped Jetpack transitions (each adds UNCHANGED mongodbVars)            *)
(****************************************************************************)

\* T1: a paused proposer starts the coordinator for its view. With a reconfig
\* staged the config entry is appended first (WAppendPendingConfigToLog), so
\* the view is the one that entry starts.
WStartRecovery(i) ==
    /\ ostate[i] = ToBeLeader
    /\ pendingConfig[i] = Nil
    /\ J!StartRecovery(i, ViewOf(i))
    /\ UNCHANGED mongodbVars

WClientResendFastCmd(c) ==
    /\ J!ClientResendFastCmd(c)
    /\ UNCHANGED mongodbVars

WClientSendFastCmd(c) ==
    /\ J!ClientSendFastCmd(c)
    /\ UNCHANGED mongodbVars

WGC(i, cmd) ==
    /\ J!GC(i, cmd)
    /\ UNCHANGED mongodbVars

\* MongoDB has a single proposer, so execution order is simply log order;
\* J!ApplyCommitted expands Recovered entries and executes each command once.
WApplyCommitted(i) ==
    /\ J!ApplyCommitted(i, "sole")
    /\ UNCHANGED mongodbVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED mongodbVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED mongodbVars

\* L47 submits Recovered(S) to the coordinator's own proposer: in MongoDB only
\* the (paused) primary writes its oplog, so a coordinator demoted by a newer
\* term (UpdateTerm, Restart) cannot submit; it stops once it learns the
\* newer view (J!StopCoordinating).
WCompleteAccept(i) ==
    /\ ostate[i] = ToBeLeader
    /\ J!CompleteAccept(i)
    /\ UNCHANGED mongodbVars

WResumeAfterRecovered(i) ==
    /\ J!ResumeAfterRecovered(i)
    /\ UNCHANGED mongodbVars

WRetransmitFinishRecovery(i) ==
    /\ J!RetransmitFinishRecovery(i)
    /\ UNCHANGED mongodbVars

WStopCoordinating(i) ==
    /\ J!StopCoordinating(i)
    /\ UNCHANGED mongodbVars

WServerReceive(m) ==
    /\ m.mdest \in Server
    /\ J!ServerReceive(m.mdest, m)
    /\ UNCHANGED mongodbVars

WClientReceive(m) ==
    /\ m.mdest \in Client
    /\ J!ClientReceive(m.mdest, m)
    /\ UNCHANGED mongodbVars

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : Timeout(i)
    \/ \E i, j \in Server : RequestVote(i, j)
    \/ \E i \in Server : BecomeToBeLeader(i)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E i, j \in Server : AppendOplog(i, j)
    \/ \E i, j \in Server : RollbackOplog(i, j)
    \/ \E i, j \in Server : LearnCommitPoint(i, j)
    \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
    \/ \E m \in DOMAIN messages : MongoDbReceive(m)

    \* Reconfig: pause, config entry, then Jetpack recovery for the new view
    \/ \E i \in Server, c \in SUBSET Server : WBeginReconfig(i, c)
    \/ \E i \in Server : WAppendPendingConfigToLog(i)

    \* Jetpack
    \/ \E c \in Client : WClientSendFastCmd(c)
    \/ \E c \in Client : WClientResendFastCmd(c)
    \/ \E i \in Server, cmd \in J!Commands : WGC(i, cmd)
    \/ \E i \in Server : WApplyCommitted(i)
    \/ \E i \in Server : WStartRecovery(i)
    \/ \E i \in Server : WCompleteBeginRecovery(i)
    \/ \E i \in Server : WCompletePrepare(i)
    \/ \E i \in Server : WCompleteAccept(i)
    \/ \E i \in Server : WResumeAfterRecovered(i)
    \/ \E i \in Server : WRetransmitFinishRecovery(i)
    \/ \E i \in Server : WStopCoordinating(i)
    \/ \E m \in DOMAIN messages : WServerReceive(m)
    \/ \E m \in DOMAIN messages : WClientReceive(m)

Spec == Init /\ [][Next]_vars

(****************************************************************************)
(* State constraints                                                        *)
(****************************************************************************)

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 6
    /\ \A i \in Server : Len(log[i]["sole"]) <= 5
    /\ Len(original_execution_cmds) <= 4
    /\ Len(execution_cmds) <= 4

\* n = 5, two clients, two keys (see jetpack_raft_composition.tla).
N5StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 30
    /\ \A i \in Server : Len(log[i]["sole"]) <= 6
    /\ Len(original_execution_cmds) <= 6
    /\ Len(execution_cmds) <= 6

\* Staged variant: at most two commands are issued before some replica installs
\* a view after the initial one, so a random simulation still has commands left
\* to fast-commit in the views that follow a recovery (uniform action choice
\* otherwise issues every command long before a recovery completes). A subset
\* of the behaviours above.
N5StagedConstraint ==
    /\ N5StateConstraint
    /\ (\A i \in Server : rstate[i].lnv.epoch = EpochOf(1, 0)) => Cardinality(client_issued) <= 2

\* Tighter constraint for quick exhaustive checking.
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 7
    /\ \A i \in Server : Len(log[i]["sole"]) <= 3
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(****************************************************************************)
(* Properties / invariants                                                  *)
(****************************************************************************)

CommittedLogAgreement    == J!CommittedLogAgreement
LogOrderMatchesExecution == J!LogOrderMatchesExecution
ExecutionDedupMatches    == J!ExecutionDedupMatches
ReplicaInvariants        == J!ReplicaInvariants
RecoveredAgreement       == J!RecoveredAgreement
FastCommitDurability     == J!FastCommitDurability
PoolsConflictFree        == J!PoolsConflictFree

\* Base-protocol invariants (as in the Raft wrapper).
NoLogDivergence ==
    \A s1, s2 \in Server :
        IF s1 = s2 THEN TRUE
        ELSE
            LET lowestCommonCI == IF commitIndex[s1]["sole"] < commitIndex[s2]["sole"]
                                  THEN commitIndex[s1]["sole"]
                                  ELSE commitIndex[s2]["sole"]
            IN IF lowestCommonCI > 0
               THEN \A index \in 1..lowestCommonCI :
                        log[s1]["sole"][index] = log[s2]["sole"][index]
               ELSE TRUE

\* A primary (paused or not) has at most one uncommitted config entry
\* (B!BeginReconfig waits for the previous one to commit).
MaxOneReconfigurationAtATime ==
    ~\E i \in Server :
        /\ ostate[i] \in {Leader, ToBeLeader}
        /\ \E ind1, ind2 \in DOMAIN log[i]["sole"] :
            /\ ind1 # ind2
            /\ B!IsConfigEntry(log[i]["sole"][ind1])
            /\ B!IsConfigEntry(log[i]["sole"][ind2])
            /\ commitIndex[i]["sole"] < ind1
            /\ commitIndex[i]["sole"] < ind2

\* At most one Leader (or paused leader) per term.
ElectionSafety ==
    \A i, j \in Server :
        (i # j /\ ostate[i] \in {Leader, ToBeLeader} /\ ostate[j] \in {Leader, ToBeLeader})
            => currentTerm[i] # currentTerm[j]

\* Principle 2 (the pseudocode T2) in MongoDB terms: before any client command of term t
\* (after the latest config entry) comes a Recovered entry of term t. The
\* initial view (term 1, no config entry) has no marker entry: the initial
\* primary needs no recovery, so its term-1 commands before any config entry
\* are exempt.
Principle2MongoDb ==
    \A i \in Server :
        LET lg == log[i]["sole"]
        IN \A n \in DOMAIN lg :
            lg[n].command = B!AppendCommand =>
                \/ /\ lg[n].term = 1
                   /\ \A p \in 1..(n - 1) : ~B!IsConfigEntry(lg[p])
                \/ \E m \in 1..(n - 1) :
                    /\ lg[m].term = lg[n].term
                    /\ lg[m].command = J!RecoveredCommand
                    /\ \A p \in (m + 1)..(n - 1) : ~B!IsConfigEntry(lg[p])

\* Messages still in flight (consumed message keys may stay with count 0).
LiveMsgs == {m \in DOMAIN messages : messages[m] > 0}

\* Views held by servers, coordinators and clients, or carried by live messages.
StateViews ==
    LET ms(T) == {m \in LiveMsgs : m.mtype \in T}
        withView == {J!FastCmd, J!FastAck, J!BeginRecovery, J!BeginRecoveryOK, J!Prepare,
                     J!PrepareOK, J!Accept, J!AcceptOK, J!FinishRecovery, J!FinishRecoveryOK}
        withLnv  == {J!FastNack, J!BeginRecoveryOK, J!Nack}
        withVn   == {J!Prepare, J!PrepareOK, J!Accept, J!AcceptOK, J!FinishRecovery}
    IN  {rstate[i].lnv : i \in Server} \cup {rstate[i].nv : i \in Server}
        \cup {cstate[i].view : i \in Server} \cup {cstate[i].vn : i \in Server}
        \cup {client_view[c] : c \in Client}
        \cup {m.mview : m \in ms(withView)}
        \cup {m.mlnv : m \in ms(withLnv)}
        \cup {m.mnv : m \in ms({J!Nack})}
        \cup {m.mvn : m \in ms(withVn)}

\* An epoch names one view record (the pseudocode §0).
EpochDeterminesMembership ==
    \A v, w \in StateViews :
        v.epoch = w.epoch => /\ v.replica_ids = w.replica_ids
                             /\ v.proposing_replica_ids = w.proposing_replica_ids

Safety ==
    [](CommittedLogAgreement
       /\ LogOrderMatchesExecution
       /\ ExecutionDedupMatches
       /\ ReplicaInvariants
       /\ RecoveredAgreement
       /\ FastCommitDurability
       /\ PoolsConflictFree
       /\ NoLogDivergence
       /\ MaxOneReconfigurationAtATime
       /\ ElectionSafety
       /\ Principle2MongoDb
       /\ EpochDeterminesMembership)

SpecSafety == Spec => Safety

(****************************************************************************)
(* Reachability probes: each of these is EXPECTED to be violated. Checking   *)
(* one as an INVARIANT makes TLC print a trace that reaches the behaviour,  *)
(* which shows the model exercises it (jetpack_mongodb_probe_*.cfg).        *)
(****************************************************************************)

Probe_NoFastCommit == fast_committed = {}
Probe_NoRecoveredCommitted ==
    \A i \in Server : \A k \in 1..commitIndex[i]["sole"] :
        log[i]["sole"][k].command /= J!RecoveredCommand
Probe_NoViewInstalled == \A i \in Server : rstate[i].lnv.epoch = EpochOf(1, 0)
Probe_NoFastCommitAfterRecovery ==
    \A fc \in fast_committed : fc.epoch = EpochOf(1, 0)

=============================================================================
