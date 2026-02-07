--------------------------- MODULE jetpack_mencius ---------------------------
\* Composition of Jetpack plugin with Mencius base protocol.
\* Follows the same monolithic pattern as jetpack_raft.tla.
\*
\* Mencius provides: multi-leader Paxos with round-robin slot assignment.
\* Jetpack provides: fast-path preaccept with recovery on leader change.
\*
\* Key differences from jetpack_raft.tla:
\*   - BecomeLeader replaced by BecomeToBeLeader (Jetpack recovery)
\*   - Mencius-specific variables (slotState, slotValue, etc.) added
\*   - Mencius message types routed alongside Jetpack message types
\*   - All servers are leaders in Mencius (multi-leader)

EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Basic universe sets.
CONSTANTS Server, Client, CmdId, Key

\* Reserved value used as a "nil" placeholder.
Nil == "Nil"
\* Typed nils for record values (avoid record vs. non-record equality).
NilCmd == [tag |-> "NilCmd"]
NilJPool == [tag |-> "NilJPool"]
NilPrepResp == [tag |-> "NilPrepResp"]
NoOp == [tag |-> "NoOp"]

\* Server states (Raft-compatible + Jetpack's ToBeLeader).
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Mencius slot states.
Empty     == "Empty"
Proposed  == "Proposed"
Accepted  == "Accepted"
Learned   == "Learned"
Skipped   == "Skipped"

\* Jetpack states.
Ready            == "Ready"
Recovery         == "Recovery"
AfterBeginRecovery == "AfterBeginRecovery"
AfterPrepare     == "AfterPrepare"
AfterAccept      == "AfterAccept"
AfterResubmit    == "AfterResubmit"

\* Mencius message types.
SuggestRequest   == "SuggestRequest"
SuggestResponse  == "SuggestResponse"
SkipMessage      == "SkipMessage"
RevokeRequest    == "RevokeRequest"
RevokeResponse   == "RevokeResponse"
LearnMessage     == "LearnMessage"

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

MenciusMessageTypes == {SuggestRequest, SuggestResponse,
                        SkipMessage, RevokeRequest,
                        RevokeResponse, LearnMessage}
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

SlotValues == Commands \cup {NoOp}

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

    \* Mencius-specific per-server variables.
    slotState,
    slotValue,
    slotBallot,
    localIndex,
    acceptCount,

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
menciusVars == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>
jetpackVars == <<jstate, jepoch, oepoch, old_view, new_view, jpool,
                 recovery_set, chosen_value, br_responses,
                 prep_responses, accept_responses>>
clientVars == <<client_view, client_pending, client_successes>>
executionVars == <<original_execution_cmds, execution_cmds>>

vars == <<messages, serverVars, candidateVars, leaderVars,
          logVars, menciusVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

N == Cardinality(Server)

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

\* Mencius helpers.
ServerSeq == CHOOSE f \in [1..N -> Server] :
                \A i, j \in 1..N : i /= j => f[i] /= f[j]

ServerIdx(s) == CHOOSE idx \in 1..N : ServerSeq[idx] = s

CoordinatorOf(sl) == ServerSeq[((sl - 1) % N) + 1]

MaxSlot == N * 3

MySlotsUpTo(i, limit) == {sl \in 1..limit : CoordinatorOf(sl) = i}

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

Init ==
    /\ messages = [m \in {} |-> 0]
    /\ currentTerm = [i \in Server |-> 1]
    /\ ostate = [i \in Server |-> Leader]    \* In Mencius, all servers are leaders
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> <<>>]
    /\ commitIndex = [i \in Server |-> 0]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    \* Mencius init.
    /\ slotState = [i \in Server |-> [sl \in 1..MaxSlot |-> Empty]]
    /\ slotValue = [i \in Server |-> [sl \in 1..MaxSlot |-> NilCmd]]
    /\ slotBallot = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
    /\ localIndex = [i \in Server |-> ServerIdx(i)]
    /\ acceptCount = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
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
(* Mencius transitions                                                     *)
(***************************************************************************)

\* Coordinator suggests a command for its next slot.
Suggest(i, v) ==
    /\ v \in AvailableCommands
    /\ localIndex[i] <= MaxSlot
    /\ CoordinatorOf(localIndex[i]) = i
    /\ slotState[i][localIndex[i]] = Empty
    /\ LET sl == localIndex[i]
           msgSet == { [mtype |-> SuggestRequest,
                        mterm |-> currentTerm[i],
                        msource |-> i,
                        mdest |-> s,
                        mslot |-> sl,
                        mvalue |-> v,
                        mballot |-> 1] : s \in Server \ {i} }
       IN /\ slotState' = [slotState EXCEPT ![i][sl] = Proposed]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = v]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = 1]
          /\ localIndex' = [localIndex EXCEPT ![i] = sl + N]
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]
          /\ log' = [log EXCEPT ![i] = Append(log[i],
                        [term |-> currentTerm[i], value |-> v])]
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         jetpackVars, clientVars, executionVars>>

\* Coordinator skips its slot with a no-op.
Skip(i) ==
    /\ localIndex[i] <= MaxSlot
    /\ CoordinatorOf(localIndex[i]) = i
    /\ slotState[i][localIndex[i]] = Empty
    /\ LET sl == localIndex[i]
           msgSet == { [mtype |-> SkipMessage,
                        mterm |-> currentTerm[i],
                        msource |-> i,
                        mdest |-> s,
                        mslot |-> sl] : s \in Server \ {i} }
       IN /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ localIndex' = [localIndex EXCEPT ![i] = sl + N]
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotBallot, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleSuggest(i, m) ==
    /\ m.mtype = SuggestRequest
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ m.mballot >= slotBallot[i][sl]
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Accepted]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = m.mvalue]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = m.mballot]
          /\ Reply([mtype |-> SuggestResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mslot |-> sl,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleSuggestResponse(i, m) ==
    /\ m.mtype = SuggestResponse
    /\ i = m.mdest
    /\ m.mok
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] = Proposed
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = acceptCount[i][sl] + 1]
          /\ IF acceptCount[i][sl] + 1 >= (N \div 2 + 1)
             THEN
               /\ slotState' = [slotState EXCEPT ![i][sl] = Learned]
               /\ LET learnMsgs == { [mtype |-> LearnMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl,
                                       mvalue |-> slotValue[i][sl]] : s \in Server \ {i} }
                  IN messages' = AddMessages(learnMsgs, WithoutMessage(m, messages))
               /\ LET newCI == commitIndex[i] + 1
                  IN IF /\ newCI <= Len(log[i])
                        /\ newCI <= MaxSlot
                        /\ slotState[i][newCI] \in {Learned, Skipped}
                     THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                     ELSE UNCHANGED commitIndex
             ELSE
               /\ UNCHANGED <<slotState, commitIndex>>
               /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                         slotValue, slotBallot, localIndex,
                         jetpackVars, clientVars, executionVars>>

HandleSkip(i, m) ==
    /\ m.mtype = SkipMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotBallot, localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleLearn(i, m) ==
    /\ m.mtype = LearnMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState' = [slotState EXCEPT ![i][sl] = Learned]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = m.mvalue]
          /\ log' = [log EXCEPT ![i] =
                        IF Len(log[i]) < sl
                        THEN Append(log[i], [term |-> m.mterm, value |-> m.mvalue])
                        ELSE log[i]]
          /\ LET newCI == commitIndex[i] + 1
             IN IF /\ newCI <= Len(log[i]) + 1
                   /\ newCI <= MaxSlot
                   /\ slotState'[i][newCI] \in {Learned, Skipped}
                THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                ELSE UNCHANGED commitIndex
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         slotBallot, localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

Revoke(i, sl) ==
    /\ sl <= MaxSlot
    /\ CoordinatorOf(sl) /= i
    /\ slotState[i][sl] = Empty
    /\ LET msgSet == { [mtype |-> RevokeRequest,
                         mterm |-> currentTerm[i],
                         msource |-> i,
                         mdest |-> s,
                         mslot |-> sl,
                         mballot |-> slotBallot[i][sl] + 1] : s \in Server \ {i} }
       IN /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = slotBallot[i][sl] + 1]
          /\ slotState' = [slotState EXCEPT ![i][sl] = Proposed]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex,
                         jetpackVars, clientVars, executionVars>>

HandleRevoke(i, m) ==
    /\ m.mtype = RevokeRequest
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ m.mballot > slotBallot[i][sl]
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ slotState' = [slotState EXCEPT ![i][sl] = Accepted]
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]
          /\ slotBallot' = [slotBallot EXCEPT ![i][sl] = m.mballot]
          /\ Reply([mtype |-> RevokeResponse,
                    mterm |-> currentTerm[i],
                    msource |-> i,
                    mdest |-> m.msource,
                    mslot |-> sl,
                    mok |-> TRUE],
                    m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex, acceptCount,
                         jetpackVars, clientVars, executionVars>>

HandleRevokeResponse(i, m) ==
    /\ m.mtype = RevokeResponse
    /\ i = m.mdest
    /\ m.mok
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] = Proposed
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = acceptCount[i][sl] + 1]
          /\ IF acceptCount[i][sl] + 1 >= (N \div 2 + 1)
             THEN
               /\ slotState' = [slotState EXCEPT ![i][sl] = Skipped]
               /\ LET learnMsgs == { [mtype |-> SkipMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl] : s \in Server \ {i} }
                  IN messages' = AddMessages(learnMsgs, WithoutMessage(m, messages))
             ELSE
               /\ UNCHANGED slotState
               /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         slotValue, slotBallot, localIndex,
                         jetpackVars, clientVars, executionVars>>

\* Mencius AdvanceCommitIndex.
AdvanceCommitIndex(i) ==
    /\ LET newCI == commitIndex[i] + 1
       IN /\ newCI <= Len(log[i])
          /\ newCI <= MaxSlot
          /\ slotState[i][newCI] \in {Learned, Skipped}
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* Mencius ClientRequest: suggest via Mencius protocol.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ Suggest(i, v)

\* Mencius Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* BecomeToBeLeader (Jetpack recovery before becoming Leader).
\* In Mencius, all servers start as Leader, so this mainly handles
\* recovery after a Restart (which sets ostate to Follower).
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   menciusVars, jetpackVars, clientVars, executionVars>>

\* Leader applies committed entries.
ApplyCommitted(i) ==
    /\ ostate[i] = Leader
    /\ commitIndex[i] > Len(original_execution_cmds)
    /\ LET nextExecIndex == Len(original_execution_cmds) + 1
           nextCmd == log[i][nextExecIndex].value
       IN /\ original_execution_cmds' =
              Append(original_execution_cmds, nextCmd)
          /\ execution_cmds' = Append(execution_cmds, nextCmd)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, jetpackVars, clientVars>>

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
                            menciusVars, jetpackVars, client_view, executionVars>>

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
                         menciusVars,
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
                         logVars, menciusVars, jetpackVars>>

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
                         menciusVars,
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
                   menciusVars,
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
                   menciusVars,
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
                   menciusVars,
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
                         menciusVars,
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
                         menciusVars,
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
                   menciusVars,
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
                   menciusVars,
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
                         menciusVars,
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
                         menciusVars,
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
                   menciusVars,
                   jstate, old_view, new_view, recovery_set, chosen_value,
                   br_responses, prep_responses, clientVars, executionVars>>

CompleteAccept(i) ==
    /\ jstate[i] = AfterPrepare
    /\ \E qs \in JQuorum(new_view[i]) :
         /\ \A s \in qs : accept_responses[i][s] = TRUE
         /\ jstate' = [jstate EXCEPT ![i] = AfterAccept]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   menciusVars,
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
                         menciusVars,
                         jstate, jepoch, oepoch, old_view, new_view, jpool,
                         recovery_set, chosen_value, br_responses,
                         prep_responses, accept_responses, clientVars, executionVars>>

CompleteResubmit(i) ==
    /\ jstate[i] = AfterAccept
    /\ ChosenExecutedInView(i)
    /\ jstate' = [jstate EXCEPT ![i] = AfterResubmit]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   menciusVars,
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
                   logVars, menciusVars, clientVars, executionVars>>

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
                   logVars, menciusVars, br_responses, prep_responses,
                   accept_responses, clientVars, executionVars>>

(***************************************************************************)
(* Message receive plumbing                                                *)
(***************************************************************************)

ServerReceive(m) ==
    /\ m.mdest \in Server
    /\ \/ /\ m.mtype = SuggestRequest
          /\ HandleSuggest(m.mdest, m)
       \/ /\ m.mtype = SuggestResponse
          /\ HandleSuggestResponse(m.mdest, m)
       \/ /\ m.mtype = SkipMessage
          /\ HandleSkip(m.mdest, m)
       \/ /\ m.mtype = LearnMessage
          /\ HandleLearn(m.mdest, m)
       \/ /\ m.mtype = RevokeRequest
          /\ HandleRevoke(m.mdest, m)
       \/ /\ m.mtype = RevokeResponse
          /\ HandleRevokeResponse(m.mdest, m)
       \/ /\ m.mtype = PreacceptRequest
          /\ HandlePreacceptRequest(m.mdest, m)
       \/ /\ m.mtype = PreacceptResponse
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         menciusVars, jetpackVars, clientVars, executionVars>>
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
                   menciusVars, jetpackVars, clientVars, executionVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, jetpackVars, clientVars, executionVars>>

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    /\ \/ \E i \in Server : Restart(i)
       \/ \E i \in Server : BecomeToBeLeader(i)
       \/ \E i \in Server : ApplyCommitted(i)
       \/ \E i \in Server : AdvanceCommitIndex(i)
       \/ \E i \in Server, v \in Commands : ClientRequest(i, v)
       \/ \E i \in Server : Skip(i)
       \/ \E i \in Server, sl \in 1..MaxSlot : Revoke(i, sl)

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
    /\ \A i \in Server : Len(log[i]) <= 3
    /\ Len(original_execution_cmds) <= 3
    /\ Len(execution_cmds) <= 3

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* All servers that have learned the same slot agree on its value.
SlotAgreement ==
    \A i, j \in Server :
        \A sl \in 1..MaxSlot :
            (/\ slotState[i][sl] \in {Learned, Skipped}
             /\ slotState[j][sl] \in {Learned, Skipped})
            => slotValue[i][sl] = slotValue[j][sl]

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

Safety == [](SlotAgreement /\ LogOrderMatchesExecution /\ ExecutionDedupMatches)

SpecSafety == Spec => Safety

=============================================================================
