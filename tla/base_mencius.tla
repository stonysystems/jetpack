--------------------------- MODULE base_mencius --------------------------------
\* Mencius consensus protocol adapted for Jetpack composition.
\*
\* This module contains the Mencius protocol state machine with the ToBeLeader
\* state (intercepted by Jetpack for recovery). It is designed to be
\* INSTANCE'd by a wrapper module that composes it with jetpack.tla.
\*
\* Key differences from standalone mencius.tla:
\*   - BecomeToBeLeader: Candidate -> ToBeLeader (not -> Leader)
\*   - Suggest uses v \in Commands (wrapper adds Jetpack's AvailableCommands filter)
\*   - No execution_cmds or ApplyCommitted (delegated to wrapper/Jetpack)
\*   - All servers start as Leader (multi-leader Paxos)
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex,
\*   slotState, slotValue, slotBallot, localIndex, acceptCount

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]
NoOp == [cmd_id |-> "NoOp", key |-> "NoOp"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Mencius slot states.
Empty    == "Empty"
Proposed == "Proposed"
Accepted == "Accepted"
Learned  == "Learned"
Skipped  == "Skipped"

\* Mencius message types.
SuggestRequest  == "SuggestRequest"
SuggestResponse == "SuggestResponse"
SkipMessage     == "SkipMessage"
RevokeRequest   == "RevokeRequest"
RevokeResponse  == "RevokeResponse"
LearnMessage    == "LearnMessage"

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
    slotState,
    slotValue,
    slotBallot,
    localIndex,
    acceptCount

serverVars       == <<currentTerm, ostate, votedFor>>
candidateVars    == <<votesResponded, votesGranted>>
leaderVars       == <<nextIndex, matchIndex>>
logVars          == <<log, commitIndex>>
menciusVars      == <<slotState, slotValue, slotBallot, localIndex, acceptCount>>
menciusExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      slotState, slotValue, slotBallot, localIndex, acceptCount>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

SlotValues == Commands \cup {NoOp}

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term

N == Cardinality(Server)

Symmetry == Permutations(Server)

\* Canonical server sequence for round-robin slot assignment.
ServerSeq == CHOOSE f \in [1..N -> Server] :
                \A i, j \in 1..N : i /= j => f[i] /= f[j]

ServerIdx(s) == CHOOSE idx \in 1..N : ServerSeq[idx] = s

CoordinatorOf(sl) == ServerSeq[((sl - 1) % N) + 1]

MaxSlot == N * 3

\* Extend log[i] through all consecutive Learned/Skipped slots from current length.
\* newSS: the post-transition slotState for server i (function 1..MaxSlot -> state)
\* newSV: the post-transition slotValue for server i (function 1..MaxSlot -> value)
ExtendLog(i, newSS, newSV) ==
    LET curLen == Len(log[i])
        maxExt == CHOOSE n \in curLen..MaxSlot :
                    /\ \A k \in (curLen+1)..n : newSS[k] \in {Learned, Skipped}
                    /\ (n = MaxSlot \/ newSS[n+1] \notin {Learned, Skipped})
        newEntries == [k \in 1..(maxExt - curLen) |->
                        [term |-> currentTerm[i], value |-> newSV[curLen + k]]]
    IN log[i] \o newEntries

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

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

InitBaseVars ==
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
    /\ localIndex = [i \in Server |-> ServerIdx(i)]
    /\ acceptCount = [i \in Server |-> [sl \in 1..MaxSlot |-> 0]]

(***************************************************************************)
(* Mencius transitions                                                     *)
(***************************************************************************)

\* Coordinator suggests a command for its next slot.
\* Note: v \in Commands is a type guard only. The wrapper adds the Jetpack-aware
\* AvailableCommands filter (which also excludes commands in execution_cmds).
Suggest(i, v) ==
    /\ v \in Commands
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
          /\ messages' = AddMessages(msgSet, messages)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars>>

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
                         slotBallot, acceptCount>>

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
                         localIndex, acceptCount>>

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
               /\ LET newSS == [slotState[i] EXCEPT ![sl] = Learned]
                      newLog == ExtendLog(i, newSS, slotValue[i])
                  IN /\ slotState' = [slotState EXCEPT ![i] = newSS]
                     /\ log' = [log EXCEPT ![i] = newLog]
                     /\ LET newCI == commitIndex[i] + 1
                        IN IF /\ newCI <= Len(newLog)
                              /\ newCI <= MaxSlot
                              /\ newSS[newCI] \in {Learned, Skipped}
                           THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                           ELSE UNCHANGED commitIndex
               /\ LET learnMsgs == { [mtype |-> LearnMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl,
                                       mvalue |-> slotValue[i][sl]] : s \in Server \ {i} }
                  IN messages' = AddMessages(learnMsgs, WithoutMessage(m, messages))
             ELSE
               /\ UNCHANGED <<slotState, log, commitIndex>>
               /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         slotValue, slotBallot, localIndex>>

HandleSkip(i, m) ==
    /\ m.mtype = SkipMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ slotState[i][sl] \in {Empty, Proposed}
          /\ LET newSS == [slotState[i] EXCEPT ![sl] = Skipped]
                 newSV == [slotValue[i] EXCEPT ![sl] = NoOp]
             IN /\ slotState' = [slotState EXCEPT ![i] = newSS]
                /\ slotValue' = [slotValue EXCEPT ![i] = newSV]
                /\ log' = [log EXCEPT ![i] = ExtendLog(i, newSS, newSV)]
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         slotBallot, localIndex, acceptCount>>

HandleLearn(i, m) ==
    /\ m.mtype = LearnMessage
    /\ i = m.mdest
    /\ LET sl == m.mslot
       IN /\ sl <= MaxSlot
          /\ LET newSS == [slotState[i] EXCEPT ![sl] = Learned]
                 newSV == [slotValue[i] EXCEPT ![sl] = m.mvalue]
                 newLog == ExtendLog(i, newSS, newSV)
             IN /\ slotState' = [slotState EXCEPT ![i] = newSS]
                /\ slotValue' = [slotValue EXCEPT ![i] = newSV]
                /\ log' = [log EXCEPT ![i] = newLog]
                /\ LET newCI == commitIndex[i] + 1
                   IN IF /\ newCI <= Len(newLog)
                         /\ newCI <= MaxSlot
                         /\ newSS[newCI] \in {Learned, Skipped}
                      THEN commitIndex' = [commitIndex EXCEPT ![i] = newCI]
                      ELSE UNCHANGED commitIndex
          /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                         slotBallot, localIndex, acceptCount>>

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
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, localIndex>>

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
                         localIndex, acceptCount>>

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
               /\ LET newSS == [slotState[i] EXCEPT ![sl] = Skipped]
                  IN /\ slotState' = [slotState EXCEPT ![i] = newSS]
                     /\ log' = [log EXCEPT ![i] = ExtendLog(i, newSS, slotValue[i])]
               /\ LET learnMsgs == { [mtype |-> SkipMessage,
                                       mterm |-> currentTerm[i],
                                       msource |-> i,
                                       mdest |-> s,
                                       mslot |-> sl] : s \in Server \ {i} }
                  IN messages' = AddMessages(learnMsgs, WithoutMessage(m, messages))
             ELSE
               /\ UNCHANGED <<slotState, log>>
               /\ Discard(m)
          /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                         slotValue, slotBallot, localIndex>>

\* Mencius AdvanceCommitIndex.
AdvanceCommitIndex(i) ==
    /\ LET newCI == commitIndex[i] + 1
       IN /\ newCI <= Len(log[i])
          /\ newCI <= MaxSlot
          /\ slotState[i][newCI] \in {Learned, Skipped}
          /\ commitIndex' = [commitIndex EXCEPT ![i] = newCI]
    /\ UNCHANGED <<messages, serverVars, candidateVars, leaderVars, log, menciusVars>>

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
    /\ UNCHANGED <<messages, currentTerm, votedFor, log, menciusVars>>

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
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars, menciusVars>>

(***************************************************************************)
(* Message plumbing                                                        *)
(***************************************************************************)

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, menciusVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, menciusVars>>

=============================================================================
