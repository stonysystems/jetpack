-------------------------- MODULE jetpack_raft_composition --------------------------
\* Composition of Jetpack (jetpack.tla, written from the pseudocode (docs/pseudocode.md)) with Raft
\* (base_raft.tla, with add/remove reconfiguration).
\*
\* This wrapper:
\*   1. Declares the union of all variables (base + Jetpack + client + execution).
\*   2. INSTANCEs base_raft.tla and jetpack.tla, mapping variables.
\*   3. Wraps base_raft actions with UNCHANGED <<jetpackVars, clientVars,
\*      executionVars>> and Jetpack actions with UNCHANGED raftOnlyVars.
\*   4. Supplies the Raft view (the pseudocode §0 / Q16): id = (term, index of the latest
\*      config entry), encoded as term * EpochStride + index; members = the
\*      latest config in the leader's log; proposers = {leader}.
\*   5. Supplies the trigger (the pseudocode T1): a server that became ToBeLeader (won an
\*      election, or appended a config entry as a paused leader) starts a
\*      coordinator for ViewOf(i) before appending any other entry; it becomes
\*      Leader again when its own Recovered(S) commits (J!ResumeAfterRecovered,
\*      T2). While ToBeLeader it still replicates and commits (base_raft) but
\*      proposes no client command.
\*
\* Raft uses a single proposer "sole" — all entries belong to one sequence.

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, Client, CmdId, Key, InitialMembers,
          MinClusterSize, MaxClusterSize,
          MaxElections, MaxRestarts,
          MaxAddReconfigs, MaxRemoveReconfigs,
          IncludeThesisBug

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

    \* Raft-specific variables.
    votedFor,
    votesGranted,
    nextIndex,
    matchIndex,
    config,
    pending_reconfig,
    electionCtr, restartCtr, addReconfigCtr, removeReconfigCtr,

    \* Jetpack per-server variables.
    rstate, cstate, subm,

    \* Client-side variables.
    client_view, client_pending, client_successes, client_heard_from, client_issued,

    \* Execution tracking.
    original_execution_cmds, execution_cmds, applied, fast_committed

\* Variable groups for UNCHANGED clauses.
raftOnlyVars  == <<votedFor, votesGranted, nextIndex, matchIndex,
                   config, pending_reconfig,
                   electionCtr, restartCtr, addReconfigCtr, removeReconfigCtr>>
serverVars    == <<config, currentTerm, ostate, votedFor>>
candidateVars == <<votesGranted>>
leaderVars    == <<nextIndex, matchIndex>>
logVars       == <<log, commitIndex>>
auxVars       == <<electionCtr, restartCtr, addReconfigCtr, removeReconfigCtr>>
jetpackVars   == <<rstate, cstate, subm>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from, client_issued>>
executionVars == <<original_execution_cmds, execution_cmds, applied, fast_committed>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars,
          pending_reconfig, auxVars,
          jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Raft view ids (the pseudocode Q16): (term, latest config index), lexicographic.      *)
(****************************************************************************)

EpochStride == 16                       \* > any log index reachable under the constraints
EpochOf(term, cfgIndex) == term * EpochStride + cfgIndex

(****************************************************************************)
(* INSTANCE base protocol and Jetpack modules                               *)
(****************************************************************************)

B == INSTANCE base_raft

\* Raft: single proposer "sole"; the initial view's proposer is the initial
\* leader chosen by B!InitBaseVars (the same CHOOSE expression); the initial
\* view starts at the InitClusterCommand entry (index 1, term 1).
J == INSTANCE jetpack WITH NoOpCmd <- [tag |-> "RaftNoOp"],
                          Proposer <- {"sole"},
                          ProposerOf <- LAMBDA i : "sole",
                          InitialProposers <- {CHOOSE i \in InitialMembers : TRUE},
                          InitialEpoch <- EpochOf(1, 1)

Follower     == B!Follower
Candidate    == B!Candidate
ToBeLeader   == B!ToBeLeader
Leader       == B!Leader
NotMember    == B!NotMember

ReconfigAdd    == B!ReconfigAdd
ReconfigRemove == B!ReconfigRemove

\* The view server i starts as a new proposer (T1): its current term, the
\* index of the latest config entry in its log, that config's members.
ViewOf(i) ==
    [epoch |-> EpochOf(currentTerm[i], B!MostRecentReconfigEntry(log[i]["sole"]).index),
     replica_ids |-> config[i].members,
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
(* Wrapped base_raft transitions                                            *)
(****************************************************************************)

\* Restart keeps Jetpack's state: it is persisted with the base's (the pseudocode §0
\* Persistence, Q15).
Restart(i) ==
    /\ B!Restart(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

UpdateTerm ==
    /\ B!UpdateTerm
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RequestVote(i) ==
    /\ B!RequestVote(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

BecomeToBeLeader(i) ==
    /\ B!BecomeToBeLeader(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

ClientRequest(i, v) ==
    /\ B!ClientRequest(i, v)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* State-space reduction (not a protocol change): AppendEntries is sent only
\* when the leader has entries for j. Empty heartbeats only carry the commit
\* index to followers, which no safety property here depends on (any server's
\* committed prefix is checked; the leader's always leads).
AppendEntries(i, j) ==
    /\ nextIndex[i][j] <= Len(log[i]["sole"])
    /\ B!AppendEntries(i, j)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

AdvanceCommitIndex(i) ==
    /\ B!AdvanceCommitIndex(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

RaftReceive ==
    /\ B!RaftReceive
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

\* Reconfiguration (the pseudocode T1–T2, Q11): the leader pauses (ToBeLeader), appends
\* the config entry, and that entry starts the new view (term, its index);
\* WStartRecovery then runs Jetpack recovery for it.
WRequestReconfig(i, op, target) ==
    /\ B!RequestReconfig(i, op, target)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

WAppendPendingReconfigToLog(i) ==
    /\ B!AppendPendingReconfigToLog(i)
    /\ UNCHANGED <<jetpackVars, clientVars, executionVars>>

(****************************************************************************)
(* Wrapped Jetpack transitions (each adds UNCHANGED raftOnlyVars)           *)
(****************************************************************************)

\* T1: a paused proposer starts the coordinator for its view. With a reconfig
\* pending the config entry is appended first (WAppendPendingReconfigToLog),
\* so the view is the one that entry starts.
WStartRecovery(i) ==
    /\ ostate[i] = ToBeLeader
    /\ pending_reconfig[i] = B!NoReconfig
    /\ J!StartRecovery(i, ViewOf(i))
    /\ UNCHANGED raftOnlyVars

WClientSendFastCmd(c) ==
    /\ J!ClientSendFastCmd(c)
    /\ UNCHANGED raftOnlyVars

WGC(i, cmd) ==
    /\ J!GC(i, cmd)
    /\ UNCHANGED raftOnlyVars

WApplyCommitted(i) ==
    /\ J!ApplyCommitted(i, "sole")
    /\ UNCHANGED raftOnlyVars

WCompleteBeginRecovery(i) ==
    /\ J!CompleteBeginRecovery(i)
    /\ UNCHANGED raftOnlyVars

WCompletePrepare(i) ==
    /\ J!CompletePrepare(i)
    /\ UNCHANGED raftOnlyVars

WCompleteAccept(i) ==
    /\ J!CompleteAccept(i)
    /\ UNCHANGED raftOnlyVars

WResumeAfterRecovered(i) ==
    /\ J!ResumeAfterRecovered(i)
    /\ UNCHANGED raftOnlyVars

WRetransmitFinishRecovery(i) ==
    /\ J!RetransmitFinishRecovery(i)
    /\ UNCHANGED raftOnlyVars

WStopCoordinating(i) ==
    /\ J!StopCoordinating(i)
    /\ UNCHANGED raftOnlyVars

WServerReceive(m) ==
    /\ m.mdest \in Server
    /\ J!ServerReceive(m.mdest, m)
    /\ UNCHANGED raftOnlyVars

WClientReceive(m) ==
    /\ m.mdest \in Client
    /\ J!ClientReceive(m.mdest, m)
    /\ UNCHANGED raftOnlyVars

(****************************************************************************)
(* Next-state relation                                                      *)
(****************************************************************************)

Next ==
    \/ \E i \in Server : Restart(i)
    \/ UpdateTerm
    \/ \E i \in Server : RequestVote(i)
    \/ \E i \in Server : BecomeToBeLeader(i)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E i, j \in Server : AppendEntries(i, j)
    \/ \E i \in Server, v \in J!Commands : ClientRequest(i, v)
    \/ RaftReceive

    \* Reconfig: pause, config entry, then Jetpack recovery for the new view
    \/ \E i \in Server, op \in {ReconfigAdd, ReconfigRemove}, t \in Server :
            WRequestReconfig(i, op, t)
    \/ \E i \in Server : WAppendPendingReconfigToLog(i)

    \* Jetpack
    \/ \E c \in Client : WClientSendFastCmd(c)
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

\* For the recovery-only config (no clients, no commands): the message bound
\* must leave room for one 3-replica broadcast on top of the leftovers of the
\* election and of the previous recovery phase.
RecoveryStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 12
    /\ \A i \in Server : Len(log[i]["sole"]) <= 3

\* Message bound: a recovery phase broadcasts to 3 replicas on top of the
\* election's and the fast path's leftovers; below ~10 the recovery never
\* completes (checked with the probes below).
SmallStateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 2
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 10
    /\ \A i \in Server : Len(log[i]["sole"]) <= 3
    /\ Len(original_execution_cmds) <= 2
    /\ Len(execution_cmds) <= 2

(****************************************************************************)
(* CI bounds (.github/workflows/formal.yml)                                 *)
(****************************************************************************)

\* jetpack_raft_ci.cfg: SmallStateConstraint with the term bound lowered to 1
\* and the log bound to 2 entries. Term 1 means no election, so no recovery
\* (the probes below exercise it); the second log entry is the leader's one
\* proposal of the command (N19-N20) or its original-path copy, not both.
CiStateConstraint ==
    /\ SmallStateConstraint
    /\ \A i \in Server : currentTerm[i] <= 1
    /\ \A i \in Server : Len(log[i]["sole"]) <= 2

\* jetpack_raft_probe_ci_NoFastCommittedInRecovered.cfg: a bound under which
\* TLC reaches in under a minute a recovery whose Recovered entry carries the
\* fast-committed command. Each conjunct prunes interleavings, not the
\* protocol; jetpack_raft_small.cfg covers what is pruned.
\*   TwoEntryLogs: after the initial config entry there is room for the old
\*     leader's proposal of the command or for the new leader's Recovered
\*     entry, so a recovery completes only by overwriting that proposal.
\*   AttemptBeforeElection: the client's attempt ends before the election.
\*   LockStep: at most three Jetpack messages addressed to servers in flight,
\*     so a broadcast is delivered before the next one is sent and a reply is
\*     consumed before the following phase (every such message is receivable
\*     in every state, so none is stranded).
\*   NoCmdEntryAtCandidate: a candidate or paused leader holds no command
\*     entry; under TwoEntryLogs its Recovered entry could not be appended,
\*     so these states only lead to recoveries that never complete.
TwoEntryLogs == \A i \in Server : Len(log[i]["sole"]) <= 2

AttemptBeforeElection ==
    \A c \in Client : client_pending[c] /= J!NilCmd => electionCtr = 0

JetpackMsgsToServers ==
    {m \in DOMAIN messages :
        /\ messages[m] >= 1
        /\ m.mdest \in Server
        /\ m.mtype \in {J!FastCmd, J!BeginRecovery, J!BeginRecoveryOK,
                        J!Prepare, J!PrepareOK, J!Accept, J!AcceptOK, J!Nack,
                        J!FinishRecovery, J!FinishRecoveryOK}}
LockStep == Cardinality(JetpackMsgsToServers) <= 3

NoCmdEntryAtCandidate ==
    \A i \in Server : ostate[i] \in {Candidate, ToBeLeader} =>
        \A k \in 1..Len(log[i]["sole"]) : log[i]["sole"][k].command /= B!AppendCommand

CiProbeConstraint ==
    /\ SmallStateConstraint
    /\ TwoEntryLogs
    /\ AttemptBeforeElection
    /\ LockStep
    /\ NoCmdEntryAtCandidate

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

\* Raft-protocol invariants ported from upstream raft.tla.
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

\* A config entry counts as committed once it is in the logs of a majority of
\* the members it names (Raft commits a config entry under its own config).
\* commitIndex is volatile (Restart resets it to 0), so a restarted leader's
\* commitIndex says nothing about the entries committed before its restart.
ConfigEntryCommitted(i, ind) ==
    LET entry   == log[i]["sole"][ind]
        members == entry.value.members
        have    == {s \in members : /\ ind \in DOMAIN log[s]["sole"]
                                     /\ log[s]["sole"][ind] = entry}
    IN Cardinality(have) * 2 > Cardinality(members)

MaxOneReconfigurationAtATime ==
    ~\E i \in Server :
        /\ ostate[i] \in {Leader, ToBeLeader}
        /\ \E ind1, ind2 \in DOMAIN log[i]["sole"] :
            /\ ind1 # ind2
            /\ B!IsConfigCommand(log[i]["sole"], ind1)
            /\ B!IsConfigCommand(log[i]["sole"], ind2)
            /\ ~ConfigEntryCommitted(i, ind1)
            /\ ~ConfigEntryCommitted(i, ind2)

\* At most one Leader (or paused leader) per term.
ElectionSafety ==
    \A i, j \in Server :
        (i # j /\ ostate[i] \in {Leader, ToBeLeader} /\ ostate[j] \in {Leader, ToBeLeader})
            => currentTerm[i] # currentTerm[j]

\* Principle 2 (the pseudocode T2) in Raft terms: before any client command of term t
\* (after the latest config entry) comes a Recovered entry of term t. The
\* InitClusterCommand entry (term 1) stands for the initial view's marker.
Principle2Raft ==
    \A i \in Server :
        LET lg == log[i]["sole"]
        IN \A n \in DOMAIN lg :
            lg[n].command = B!AppendCommand =>
                \E m \in 1..(n - 1) :
                    /\ lg[m].term = lg[n].term
                    /\ lg[m].command \in {J!RecoveredCommand, B!InitClusterCommand}
                    /\ \A p \in (m + 1)..(n - 1) : ~B!IsConfigCommand(lg, p)

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
       /\ Principle2Raft
       /\ EpochDeterminesMembership)

SpecSafety == Spec => Safety

(****************************************************************************)
(* Reachability probes: each of these is EXPECTED to be violated. Checking   *)
(* one as an INVARIANT makes TLC print a trace that reaches the behaviour,  *)
(* which shows the model exercises it (jetpack_raft_probe_*.cfg).           *)
(****************************************************************************)

Probe_NoFastCommit == fast_committed = {}
Probe_NoRecoveredCommitted ==
    \A i \in Server : \A k \in 1..commitIndex[i]["sole"] :
        log[i]["sole"][k].command /= J!RecoveredCommand
Probe_NoViewInstalled == \A i \in Server : rstate[i].lnv.epoch = EpochOf(1, 1)
Probe_NoSubmission == \A i \in Server : subm[i].epoch = 0
Probe_NoResume == \A i \in Server : subm[i].epoch = 0 \/ ~subm[i].done
Probe_NoFastCommitAfterRecovery ==
    \A fc \in fast_committed : fc.epoch = EpochOf(1, 1)
\* No Recovered entry carries a fast-committed command. Its violation
\* witnesses a Recovered(S) containing the fast-committed command submitted
\* (L47) by the new leader while the old leader's proposal of it is still
\* uncommitted; the commit of such an entry is what the recovery probes show.
Probe_NoFastCommittedInRecovered ==
    \A i \in Server : \A k \in 1..Len(log[i]["sole"]) :
        log[i]["sole"][k].command = J!RecoveredCommand =>
            \A fc \in fast_committed : fc.cmd \notin log[i]["sole"][k].value.set

=============================================================================
