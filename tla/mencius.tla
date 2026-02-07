------------------------------ MODULE mencius ------------------------------
\* Mencius consensus protocol — a multi-leader Paxos variant with
\* round-robin slot assignment.  Based on the OSDI 2008 paper.
\*
\* This module runs standalone AND provides the same interface as raft.tla
\* so that jetpack.tla can compose with it as a base protocol.
\*
\* Key design: consensus instances are partitioned round-robin among servers.
\* Instance (c * N + p) is coordinated by server p.
\* Coordinators propose commands in their own slots without needing Phase 1.
\* Idle coordinators send Skip (no-op) for their slots.
\* Other servers can Revoke a slow/failed coordinator's slot.

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]
NoOp == [tag |-> "NoOp"]

\* Server states — same interface as raft.tla.
Follower   == "Follower"
Candidate  == "Candidate"
Leader     == "Leader"

\* Slot states.
Empty     == "Empty"
Proposed  == "Proposed"
Accepted  == "Accepted"
Learned   == "Learned"
Skipped   == "Skipped"

\* Message types.
SuggestRequest   == "SuggestRequest"
SuggestResponse  == "SuggestResponse"
SkipMessage      == "SkipMessage"
RevokeRequest    == "RevokeRequest"
RevokeResponse   == "RevokeResponse"
LearnMessage     == "LearnMessage"

(***************************************************************************)
(* Shared data types                                                       *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

LogEntry == { [term |-> t, value |-> v] : t \in Nat, v \in Commands }

\* All possible slot values.
SlotValues == Commands \cup {NoOp}

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,

    \* Per-server Raft-compatible variables.
    currentTerm,
    ostate,          \* Follower / Candidate / Leader (all start as Leader in Mencius)
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,

    \* Mencius-specific per-server variables.
    slotState,       \* [Server -> [Nat -> {Empty, Proposed, Accepted, Learned, Skipped}]]
    slotValue,       \* [Server -> [Nat -> SlotValues \cup {NilCmd}]]
    slotBallot,      \* [Server -> [Nat -> Nat]]
    localIndex,      \* Next slot this server will coordinate
    acceptCount,     \* [Server -> [Nat -> Nat]] count of accepts received

    \* Execution tracking.
    execution_cmds

serverVars == <<currentTerm, ostate, votedFor>>
logVars == <<log, commitIndex>>
candidateVars == <<votesResponded, votesGranted>>
leaderVars == <<nextIndex, matchIndex>>
menciusVars == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>

vars == <<messages, serverVars, candidateVars, leaderVars, logVars,
          menciusVars, execution_cmds>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

N == Cardinality(Server)

Symmetry == Permutations(Server)

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

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

LogCmdIds ==
    UNION { {log[i][k].value.cmd_id : k \in 1..Len(log[i])} : i \in Server }

ExecCmdIds ==
    {cmd.cmd_id : cmd \in SeqToSet(execution_cmds)}

UsedCmdIds == LogCmdIds \cup ExecCmdIds

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin UsedCmdIds}

LogEntryAt(i, k) == IF k <= Len(log[i]) THEN log[i][k] ELSE Nil
LogCmdAt(i, k) == IF k <= Len(log[i]) THEN log[i][k].value ELSE NilCmd

MaxLogLen == Max({Len(log[i]) : i \in Server} \cup {0})

ExecAt(k) == IF k <= Len(execution_cmds) THEN execution_cmds[k] ELSE NilCmd

CommittedCmds(i) ==
    IF commitIndex[i] = 0 THEN <<>>
    ELSE [k \in 1..commitIndex[i] |-> log[i][k].value]

\* Map server to a unique index 1..N for round-robin assignment.
ServerSeq == CHOOSE f \in [1..N -> Server] :
                \A i, j \in 1..N : i /= j => f[i] /= f[j]

ServerIdx(s) == CHOOSE idx \in 1..N : ServerSeq[idx] = s

\* Coordinator of slot number sl (1-indexed).
CoordinatorOf(sl) == ServerSeq[((sl - 1) % N) + 1]

\* Maximum slot number we model (bounded for model checking).
MaxSlot == N * 3

\* Slot range for a server: all slots this server coordinates.
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
    /\ slotState = [i \in Server |-> [sl \in 1..MaxSlot |-> Empty]]
    /\ slotValue = [i \in Server |-> [sl \in 1..MaxSlot |-> NilCmd]]
    /\ slotBallot = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
    /\ localIndex = [i \in Server |-> ServerIdx(i)]  \* First slot for each server
    /\ acceptCount = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]
    /\ execution_cmds = <<>>

(***************************************************************************)
(* Mencius transitions                                                     *)
(***************************************************************************)

\* Coordinator suggests a command for its next slot (Phase 2 directly).
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
          /\ localIndex' = [localIndex EXCEPT ![i] = sl + N]  \* Next slot for this server
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]  \* Count self
          /\ log' = [log EXCEPT ![i] = Append(log[i],
                        [term |-> currentTerm[i], value |-> v])]
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         execution_cmds>>

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
                         slotBallot, acceptCount, execution_cmds>>

\* Acceptor handles Suggest request.
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
                         localIndex, acceptCount, execution_cmds>>

\* Coordinator collects Suggest responses and learns.
HandleSuggestResponse(i, m) ==
    /\ m.mtype = SuggestResponse
    /\ i = m.mdest
    /\ m.mok
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] = Proposed
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = acceptCount[i][sl] + 1]
          \* Check if we have a quorum.
          /\ IF acceptCount[i][sl] + 1 >= (N \div 2 + 1)
             THEN
               /\ slotState' = [slotState EXCEPT ![i][sl] = Learned]
               \* Send Learn to all.
               /\ LET learnMsgs == { [mtype |-> LearnMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl,
                                       mvalue |-> slotValue[i][sl]] : s \in Server \ {i} }
                  IN messages' = AddMessages(learnMsgs, WithoutMessage(m, messages))
               \* Try to advance commitIndex.
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
                         slotValue, slotBallot, localIndex, execution_cmds>>

\* Acceptor handles Skip message (learns no-op instantly).
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
                         slotBallot, localIndex, acceptCount, execution_cmds>>

\* Acceptor handles Learn message.
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
          \* Try to advance commitIndex.
          /\ LET newCI == commitIndex[i] + 1
             IN IF /\ newCI <= Len(log[i]) + 1  \* +1 because we may have just appended
                   /\ newCI <= MaxSlot
                   /\ slotState'[i][newCI] \in {Learned, Skipped}
                THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                ELSE UNCHANGED commitIndex
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         slotBallot, localIndex, acceptCount, execution_cmds>>

\* A server revokes a slow coordinator's slot.
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
          /\ slotValue' = [slotValue EXCEPT ![i][sl] = NoOp]  \* Can only propose no-op
          /\ acceptCount' = [acceptCount EXCEPT ![i][sl] = 1]  \* Count self
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                         localIndex, execution_cmds>>

\* Handle Revoke request (same as Suggest but for revocation).
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
                         localIndex, acceptCount, execution_cmds>>

\* Handle Revoke response (similar to SuggestResponse).
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
                         slotValue, slotBallot, localIndex, execution_cmds>>

\* Leader applies committed entries to execution_cmds.
ApplyCommitted(i) ==
    /\ commitIndex[i] > Len(execution_cmds)
    /\ LET nextExecIndex == Len(execution_cmds) + 1
           nextCmd == log[i][nextExecIndex].value
       IN execution_cmds' = Append(execution_cmds, nextCmd)
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, logVars,
                   menciusVars>>

\* AdvanceCommitIndex: try to advance commitIndex based on slot states.
AdvanceCommitIndex(i) ==
    /\ LET newCI == commitIndex[i] + 1
       IN /\ newCI <= Len(log[i])
          /\ newCI <= MaxSlot
          /\ slotState[i][newCI] \in {Learned, Skipped}
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log,
                   menciusVars, execution_cmds>>

\* Raft-compatible ClientRequest.
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ Suggest(i, v)

\* Raft-compatible BecomeLeader (no-op in Mencius, all are leaders).
BecomeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = Leader]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> Len(log[i]) + 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   menciusVars, execution_cmds>>

\* Restart.
Restart(i) ==
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ commitIndex' = [commitIndex EXCEPT ![i] = 0]
    /\ UNCHANGED <<messages, currentTerm, votedFor, log,
                   menciusVars, execution_cmds>>

\* Network actions.
DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, execution_cmds>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   menciusVars, execution_cmds>>

(***************************************************************************)
(* Next-state relation                                                     *)
(***************************************************************************)

Next ==
    \/ \E i \in Server : Restart(i)
    \/ \E i \in Server : BecomeLeader(i)
    \/ \E i \in Server, v \in Commands : ClientRequest(i, v)
    \/ \E i \in Server : Skip(i)
    \/ \E i \in Server : ApplyCommitted(i)
    \/ \E i \in Server : AdvanceCommitIndex(i)
    \/ \E i \in Server, sl \in 1..MaxSlot : Revoke(i, sl)
    \/ \E m \in DOMAIN messages : HandleSuggest(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleSuggestResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleSkip(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleLearn(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleRevoke(m.mdest, m)
    \/ \E m \in DOMAIN messages : HandleRevokeResponse(m.mdest, m)
    \/ \E m \in DOMAIN messages : DuplicateMessage(m)
    \/ \E m \in DOMAIN messages : DropMessage(m)

Spec == Init /\ [][Next]_vars

StateConstraint ==
    /\ \A i \in Server : currentTerm[i] <= 3
    /\ \A m \in DOMAIN messages : messages[m] <= 1
    /\ Cardinality(DOMAIN messages) <= 5
    /\ \A i \in Server : Len(log[i]) <= 3
    /\ Len(execution_cmds) <= 3

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

\* All servers that have learned the same slot agree on its value.
SlotAgreement ==
    \A i, j \in Server :
        \A sl \in 1..MaxSlot :
            (/\ slotState[i][sl] \in {Learned, Skipped}
             /\ slotState[j][sl] \in {Learned, Skipped})
            => slotValue[i][sl] = slotValue[j][sl]

\* Committed entries at the same index agree.
CommittedLogAgreement ==
    \A i, j \in Server :
        LET ci == commitIndex[i]
            cj == commitIndex[j]
            limit == Min({ci, cj} \cup {0})
        IN \A k \in 1..limit :
            log[i][k] = log[j][k]

Safety == [](SlotAgreement)

SpecSafety == Spec => Safety

=============================================================================
