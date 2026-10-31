--------------------------- MODULE base_copilot --------------------------------
\* CoPilot consensus protocol adapted for Jetpack composition (pseudocode-the pseudocode).
\*
\* This module contains the CoPilot protocol state machine with the ToBeLeader
\* state (intercepted by Jetpack for recovery). It is INSTANCE'd by
\* jetpack_copilot_composition.tla, which composes it with jetpack.tla.
\*
\* Two pilots hold the two pilot slots (slot 0 = role Pilot, slot 1 = role
\* Copilot); every other server is an Acceptor. Each slot has a ballot
\* (pilotBallot[slot]); a slot's ballot rises when its holder re-elects itself
\* (EmptyViewChange) or when another server takes the slot over
\* (FastTakeover). The Jetpack view id is the pair (ballot of pilot 0,
\* ballot of pilot 1), lexicographic (the pseudocode §0, Q16), encoded as the number
\* EpochOf(b0, b1); every server's currentTerm is that number, so log entries
\* carry the view they were appended in (used by the wrapper's Principle 2).
\*
\* 3-D Log: log[i][j][k] = k-th entry of pilot j's sequence as known to
\* server i; commitIndex[i][j] = committed prefix of that sequence on i. A
\* sequence belongs to one server for ever: a server that takes over a slot
\* continues in its own sequence, so a pilot's own entries execute in the
\* order it proposed them (the pseudocode A7).
\*
\* Changes relative to the earlier base_copilot (each tagged with the pseudocode line
\* it implements; see the wrapper's header for the list):
\*   - [the pseudocode §0 Copilot view id] per-slot ballots pilotBallot, view epoch
\*     EpochOf(b0, b1); currentTerm[i] = the view epoch on every server.
\*   - [the pseudocode T1] EmptyViewChange / FastTakeover pause BOTH pilots of the new
\*     view (ostate ToBeLeader): the unchanged pilot learns the new view from
\*     the other pilot's election. Jetpack moves ToBeLeader -> Leader when the
\*     pilot's own Recovered(S) commits (T2).
\*   - [the pseudocode T1-T2, §4(4), base_raft AppendEntries] Replicate(i): entries that
\*     Jetpack appended to log[i][i] (Recovered(S) by L47/L53, fast-path
\*     commands by N20) are replicated by the pilot even while paused
\*     (ostate \in {Leader, ToBeLeader}); only proposing new client commands
\*     (ClientRequest) waits for Leader.
\*   - [the pseudocode §4(4), N25] log entries are [command, term, value] like base_raft
\*     (jetpack.tla reads e.command; Recovered(S) entries carry a set), and
\*     replication messages carry the whole entry so copies are identical.
\*   - [the pseudocode A5] FastTakeover copies the replaced pilot's own sequence to the
\*     new holder (stands in for CoPilot's takeover/Prepare of the slot's log),
\*     so every committed command is in some proposer's log.
\*   - [the pseudocode §0 Persistence, Q15] Restart keeps role, log, cpLog, commitIndex.
\*   - cpLog[i][j] is kept per sequence (parallel to log[i][j]) and deps are
\*     (sequence, position) pairs: the earlier single interleaved cpLog gave
\*     both pilots the same indices, so one pilot's entry overwrote the
\*     other's on acceptors.
\*   - PreAccept/Commit are applied in sequence order (mseqnum <= Len + 1):
\*     an out-of-order Commit used to append an entry at the wrong position.
\*   - Counters pilotChangeCtr / restartCtr with bounds MaxPilotChanges /
\*     MaxRestarts (as base_raft's electionCtr / restartCtr).
\*
\* Kept from the earlier model, not wired by the composition (a Raft-style
\* election skeleton without vote messages): Timeout, BecomeToBeLeader,
\* votedFor, votesResponded, votesGranted, nextIndex, matchIndex.
\*
\* Variables declared here (the "base protocol interface"):
\*   messages, currentTerm, ostate, votedFor, log, commitIndex,
\*   votesResponded, votesGranted, nextIndex, matchIndex,
\*   role, cpLog, cpBallot, pilotBallot, pilotChangeCtr, restartCtr

EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, CmdId, Key,
          MaxPilotChanges,   \* bound on EmptyViewChange + FastTakeover steps
          MaxRestarts        \* bound on Restart steps

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

\* Server states.
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* CoPilot roles: Pilot holds slot 0, Copilot holds slot 1.
Pilot    == "Pilot"
Copilot  == "Copilot"
Acceptor == "Acceptor"

Slots == {0, 1}
SlotOf(r) == IF r = Pilot THEN 0 ELSE 1
RoleOfSlot(s) == IF s = 0 THEN Pilot ELSE Copilot

\* CoPilot-specific entry states.
PreAccepted == "PreAccepted"
Accepted    == "Accepted"
Committed   == "Committed"

\* Log entry kinds (same strings as jetpack.tla).
AppendCommand    == "AppendCommand"
RecoveredCommand == "Recovered"

\* CoPilot message types.
CoPilotPreAcceptRequest   == "CoPilotPreAcceptRequest"
CoPilotPreAcceptResponse  == "CoPilotPreAcceptResponse"
CoPilotCommitRequest      == "CoPilotCommitRequest"

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,
    currentTerm,      \* the view epoch EpochOf(b0, b1) (the pseudocode §0 Copilot view id)
    ostate,
    votedFor,
    log,
    commitIndex,
    votesResponded,
    votesGranted,
    nextIndex,
    matchIndex,
    role,             \* Pilot (slot 0) / Copilot (slot 1) / Acceptor
    cpLog,            \* cpLog[i][j] = [entry, deps, status] per position of sequence j
    cpBallot,         \* cpBallot[i][slot] = highest ballot i accepted for that slot
    pilotBallot,      \* pilotBallot[slot] = current ballot of the slot's holder
    pilotChangeCtr,
    restartCtr

serverVars       == <<currentTerm, ostate, votedFor>>
candidateVars    == <<votesResponded, votesGranted>>
leaderVars       == <<nextIndex, matchIndex>>
logVars          == <<log, commitIndex>>
copilotVars      == <<role, cpLog, cpBallot, pilotBallot>>
auxVars          == <<pilotChangeCtr, restartCtr>>
copilotExtraVars == <<votedFor, votesResponded, votesGranted, nextIndex, matchIndex,
                      role, cpLog, cpBallot, pilotBallot, pilotChangeCtr, restartCtr>>

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

Quorum == {q \in SUBSET(Server) : Cardinality(q) * 2 > Cardinality(Server)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

Symmetry == Permutations(Server)

\* Canonical server sequence for role assignment and tie-breaking.
ServerSeq == CHOOSE f \in [1..Cardinality(Server) -> Server] :
                \A i, j \in 1..Cardinality(Server) : i /= j => f[i] /= f[j]

Rank(s) == CHOOSE n \in 1..Cardinality(Server) : ServerSeq[n] = s

PilotOf(term) == ServerSeq[((term - 1) % Cardinality(Server)) + 1]
CopilotOf(term) == ServerSeq[(term % Cardinality(Server)) + 1]

IsPilotOrCopilot(i) == role[i] \in {Pilot, Copilot}
Pilots == {s \in Server : IsPilotOrCopilot(s)}
HolderOf(slot) == CHOOSE s \in Server : role[s] = RoleOfSlot(slot)

\* the pseudocode §0 (Copilot): view id = (ballot of pilot 0, ballot of pilot 1),
\* lexicographic. EpochStride exceeds any reachable ballot
\* (ballots <= 1 + MaxPilotChanges), so the encoding is order-preserving.
EpochStride == 16
EpochOf(b0, b1) == b0 * EpochStride + b1
ViewEpoch == EpochOf(pilotBallot[0], pilotBallot[1])

\* Commands an entry carries: one for a client command, the set S for a
\* Recovered(S) entry (the pseudocode L47); keys are those of its commands.
EntryCmds(e) ==
    IF e.command = RecoveredCommand THEN e.value.set
    ELSE IF e.command = AppendCommand THEN {e.value}
    ELSE {}

EntryKeys(e) == {c.key : c \in EntryCmds(e)}

EntriesConflict(e1, e2) == e1 /= e2 /\ EntryKeys(e1) \cap EntryKeys(e2) /= {}

\* Dependencies of entry e as seen on server i: every conflicting entry in
\* any sequence i knows, as (sequence, position) pairs.
DepsFor(i, e) ==
    UNION { { [p |-> p, k |-> k] :
              k \in {k \in 1..Len(cpLog[i][p]) : EntriesConflict(cpLog[i][p][k].entry, e)} }
            : p \in Server }

\* v is in one of the logs i holds (as a client entry or inside a Recovered
\* set), the same test as N20's "cmd \notin LogCmds(i)" in jetpack.tla.
InLog(i, v) == \E j \in Server : \E k \in 1..Len(log[i][j]) : v \in EntryCmds(log[i][j][k])

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

\* The initial view (1, 1): pilots PilotOf(1) and CopilotOf(1), both Leader
\* (the initial view needs no Recovered marker, the pseudocode §0 "Initially").
InitBaseVars ==
    /\ messages = [m \in {} |-> 0]
    /\ pilotBallot = [s \in Slots |-> 1]
    /\ currentTerm = [i \in Server |-> EpochOf(1, 1)]
    /\ ostate = [i \in Server |-> IF i \in {PilotOf(1), CopilotOf(1)} THEN Leader ELSE Follower]
    /\ votedFor = [i \in Server |-> Nil]
    /\ log = [i \in Server |-> [j \in Server |-> <<>>]]
    /\ commitIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ votesResponded = [i \in Server |-> {}]
    /\ votesGranted = [i \in Server |-> {}]
    /\ nextIndex = [i \in Server |-> [j \in Server |-> 1]]
    /\ matchIndex = [i \in Server |-> [j \in Server |-> 0]]
    /\ role = [i \in Server |-> IF i = PilotOf(1) THEN Pilot
                                 ELSE IF i = CopilotOf(1) THEN Copilot
                                 ELSE Acceptor]
    /\ cpLog = [i \in Server |-> [j \in Server |-> <<>>]]
    /\ cpBallot = [i \in Server |-> [s \in Slots |-> 0]]
    /\ pilotChangeCtr = 0
    /\ restartCtr = 0

(***************************************************************************)
(* Replication (CoPilot PreAccept / Commit)                                *)
(***************************************************************************)

\* Pilot i replicates entry e at position seqnum of its own sequence: record
\* it in cpLog[i][i] with its dependencies and send PreAccept to the others.
ReplicateEntry(i, e, seqnum) ==
    LET slot == SlotOf(role[i])
        deps == DepsFor(i, e)
        cpEntry == [entry |-> e, deps |-> deps, status |-> PreAccepted]
        msgSet == { [mtype |-> CoPilotPreAcceptRequest,
                     mterm |-> currentTerm[i],
                     msource |-> i,
                     mdest |-> s,
                     mentry |-> e,
                     mdeps |-> deps,
                     mballot |-> pilotBallot[slot],
                     mslot |-> slot,
                     mseqnum |-> seqnum] : s \in Server \ {i} }
    IN /\ cpLog' = [cpLog EXCEPT ![i][i] = Append(cpLog[i][i], cpEntry)]
       /\ messages' = AddMessages(msgSet, messages)

\* A pilot proposes a client command: append it to its own sequence and
\* replicate it. Earlier entries of the sequence are replicated first
\* (Replicate), so cpLog[i][i] stays parallel to log[i][i].
Propose(i, v) ==
    /\ IsPilotOrCopilot(i)
    /\ v \in Commands
    /\ Len(cpLog[i][i]) = Len(log[i][i])
    /\ LET e == [command |-> AppendCommand, term |-> currentTerm[i], value |-> v]
       IN /\ log' = [log EXCEPT ![i][i] = Append(log[i][i], e)]
          /\ ReplicateEntry(i, e, Len(log[i][i]) + 1)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, commitIndex,
                   role, cpBallot, pilotBallot, auxVars>>

\* the pseudocode T1-T2, §4(4) (as base_raft's AppendEntries): replication keeps running
\* while the pilot is paused by Jetpack (ToBeLeader). Entries that Jetpack
\* appended to log[i][i] (its Recovered(S), L47/L53; fast-path commands, N20)
\* are replicated here in sequence order.
Replicate(i) ==
    /\ IsPilotOrCopilot(i)
    /\ ostate[i] \in {Leader, ToBeLeader}
    /\ Len(cpLog[i][i]) < Len(log[i][i])
    /\ LET n == Len(cpLog[i][i]) + 1
       IN ReplicateEntry(i, log[i][i][n], n)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars,
                   role, cpBallot, pilotBallot, auxVars>>

\* An acceptor pre-accepts position mseqnum of the sender's sequence, in
\* order. A PreAccept with a ballot below the highest it has seen for that
\* slot (a replaced pilot's) is dropped.
HandleCoPilotPreAccept(i, m) ==
    /\ m.mtype = CoPilotPreAcceptRequest
    /\ i = m.mdest
    /\ m.mseqnum <= Len(log[i][m.msource]) + 1
    /\ IF m.mballot < cpBallot[i][m.mslot]
       THEN /\ Discard(m)
            /\ UNCHANGED <<logVars, cpLog, cpBallot>>
       ELSE LET src == m.msource
                e == m.mentry
                isNew == m.mseqnum = Len(log[i][src]) + 1
                unionDeps == m.mdeps \cup DepsFor(i, e)
                cpEntry == [entry |-> e, deps |-> unionDeps, status |-> PreAccepted]
            IN /\ log' = IF isNew THEN [log EXCEPT ![i][src] = Append(log[i][src], e)] ELSE log
               /\ cpLog' = IF isNew THEN [cpLog EXCEPT ![i][src] = Append(cpLog[i][src], cpEntry)]
                           ELSE cpLog
               /\ cpBallot' = [cpBallot EXCEPT ![i][m.mslot] = m.mballot]
               /\ Reply([mtype |-> CoPilotPreAcceptResponse,
                         mterm |-> currentTerm[i],
                         msource |-> i,
                         mdest |-> src,
                         mdeps |-> unionDeps,
                         mseqnum |-> m.mseqnum,
                         mok |-> TRUE],
                        m)
               /\ UNCHANGED commitIndex
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, role, pilotBallot, auxVars>>

\* The proposer commits position mseqnum on the first PreAcceptResponse
\* (the model's commit rule, unchanged from the earlier base) and sends
\* Commit with the final dependencies. Later responses are discarded.
HandleCoPilotPreAcceptResponse(i, m) ==
    /\ m.mtype = CoPilotPreAcceptResponse
    /\ i = m.mdest
    /\ m.mok
    /\ m.mseqnum <= Len(cpLog[i][i])
    /\ IF cpLog[i][i][m.mseqnum].status /= PreAccepted
       THEN /\ Discard(m)
            /\ UNCHANGED <<cpLog, commitIndex>>
       ELSE LET entry == cpLog[i][i][m.mseqnum]
                finalDeps == entry.deps \cup m.mdeps
                newEntry == [entry EXCEPT !.deps = finalDeps, !.status = Committed]
                commitMsgs == { [mtype |-> CoPilotCommitRequest,
                                 mterm |-> currentTerm[i],
                                 msource |-> i,
                                 mdest |-> s,
                                 mentry |-> entry.entry,
                                 mdeps |-> finalDeps,
                                 mseqnum |-> m.mseqnum] : s \in Server \ {i} }
            IN /\ cpLog' = [cpLog EXCEPT ![i][i][m.mseqnum] = newEntry]
               /\ commitIndex' = [commitIndex EXCEPT ![i][i] =
                                     Max({commitIndex[i][i], m.mseqnum})]
               /\ messages' = AddMessages(commitMsgs, WithoutMessage(m, messages))
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, log,
                   role, cpBallot, pilotBallot, auxVars>>

\* An acceptor learns that position mseqnum of the sender's sequence is
\* committed (in order; the entry is appended if not yet known).
HandleCoPilotCommit(i, m) ==
    /\ m.mtype = CoPilotCommitRequest
    /\ i = m.mdest
    /\ m.mseqnum <= Len(log[i][m.msource]) + 1
    /\ LET src == m.msource
           e == m.mentry
           isNew == m.mseqnum = Len(log[i][src]) + 1
           cpEntry == [entry |-> e, deps |-> m.mdeps, status |-> Committed]
       IN /\ log' = IF isNew THEN [log EXCEPT ![i][src] = Append(log[i][src], e)] ELSE log
          /\ cpLog' = [cpLog EXCEPT ![i][src] =
                          IF isNew THEN Append(cpLog[i][src], cpEntry)
                          ELSE [cpLog[i][src] EXCEPT ![m.mseqnum] = cpEntry]]
          /\ commitIndex' = [commitIndex EXCEPT ![i][src] =
                               Max({commitIndex[i][src], m.mseqnum})]
          /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars,
                   role, cpBallot, pilotBallot, auxVars>>

(***************************************************************************)
(* View changes (the pseudocode §0 Copilot view id, T1)                               *)
(***************************************************************************)

\* the pseudocode T1 hook: a view change pauses BOTH pilots of the new view. The pilot
\* whose slot did not change learns the new view from the other pilot's
\* election (the pseudocode §0 "the unchanged pilot learns it from the other pilot's
\* election"); the model collapses that into the election step.
PauseBothPilots(newPilots, demoted) ==
    ostate' = [s \in Server |-> IF s \in newPilots THEN ToBeLeader
                                ELSE IF s \in demoted THEN Follower
                                ELSE ostate[s]]

\* Fast takeover: server i (not a pilot) takes over pilot p's slot with a
\* higher ballot: a new view (the pseudocode §0 "replacing either pilot starts a new
\* view"). The new holder learns the slot's sequence from p (the pseudocode A5: every
\* committed command is in some proposer's log; stands in for CoPilot's
\* takeover of the slot's log). p is demoted; both pilots of the new view
\* are paused (T1).
FastTakeover(i, p) ==
    /\ pilotChangeCtr < MaxPilotChanges
    /\ role[i] = Acceptor
    /\ IsPilotOrCopilot(p)
    /\ LET slot == SlotOf(role[p])
           nb == [pilotBallot EXCEPT ![slot] = pilotBallot[slot] + 1]
       IN /\ role' = [role EXCEPT ![i] = role[p], ![p] = Acceptor]
          /\ pilotBallot' = nb
          /\ currentTerm' = [s \in Server |-> EpochOf(nb[0], nb[1])]
          /\ PauseBothPilots((Pilots \ {p}) \cup {i}, {p})
          /\ log' = [log EXCEPT ![i][p] = log[p][p]]
          /\ cpLog' = [cpLog EXCEPT ![i][p] = cpLog[p][p]]
          /\ commitIndex' = [commitIndex EXCEPT ![i][p] =
                                Max({commitIndex[i][p], commitIndex[p][p]})]
          /\ pilotChangeCtr' = pilotChangeCtr + 1
    /\ UNCHANGED <<messages, votedFor, candidateVars, leaderVars, cpBallot, restartCtr>>

\* Empty view change: pilot i re-elects itself with a higher ballot for its
\* slot. The proposer set is unchanged but the view id (b0, b1) is new, so
\* Jetpack recovery runs (the pseudocode §0: a view is identified by its ballots).
\* No-op at the base level except the ballot and the pause of both pilots
\* (T1). Restricted to current pilots, so the two-proposer invariant holds.
EmptyViewChange(i) ==
    /\ pilotChangeCtr < MaxPilotChanges
    /\ IsPilotOrCopilot(i)
    /\ ostate[i] /= ToBeLeader
    /\ LET slot == SlotOf(role[i])
           nb == [pilotBallot EXCEPT ![slot] = pilotBallot[slot] + 1]
       IN /\ pilotBallot' = nb
          /\ currentTerm' = [s \in Server |-> EpochOf(nb[0], nb[1])]
          /\ PauseBothPilots(Pilots, {})
          /\ pilotChangeCtr' = pilotChangeCtr + 1
    /\ UNCHANGED <<messages, votedFor, candidateVars, leaderVars, logVars,
                   role, cpLog, cpBallot, restartCtr>>

(***************************************************************************)
(* Other transitions                                                       *)
(***************************************************************************)

\* Restart: the server's state is persistent (the pseudocode §0 Persistence, Q15):
\* role, log, cpLog, commitIndex (CoPilot's commit status is in its log) and
\* the slot ballots are kept. A restarted pilot comes back as Follower and
\* proposes again only after re-electing itself (EmptyViewChange).
Restart(i) ==
    /\ restartCtr < MaxRestarts
    /\ ostate' = [ostate EXCEPT ![i] = Follower]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {}]
    /\ nextIndex' = [nextIndex EXCEPT ![i] = [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] = [j \in Server |-> 0]]
    /\ restartCtr' = restartCtr + 1
    /\ UNCHANGED <<messages, currentTerm, votedFor, logVars,
                   role, cpLog, cpBallot, pilotBallot, pilotChangeCtr>>

\* Election timeout (Raft-style skeleton; not wired by the composition: there
\* are no vote messages, so BecomeToBeLeader can never fire with >= 2 servers).
Timeout(i) ==
    /\ ostate[i] \in {Follower, Candidate}
    /\ ostate' = [ostate EXCEPT ![i] = Candidate]
    /\ currentTerm' = [currentTerm EXCEPT ![i] = currentTerm[i] + 1]
    /\ votedFor' = [votedFor EXCEPT ![i] = i]
    /\ votesResponded' = [votesResponded EXCEPT ![i] = {i}]
    /\ votesGranted' = [votesGranted EXCEPT ![i] = {i}]
    /\ UNCHANGED <<messages, leaderVars, logVars, copilotVars, auxVars>>

\* Candidate transitions to ToBeLeader (not wired by the composition).
BecomeToBeLeader(i) ==
    /\ ostate[i] = Candidate
    /\ votesGranted[i] \in Quorum
    /\ ostate' = [ostate EXCEPT ![i] = ToBeLeader]
    /\ role' = [j \in Server |-> IF j = i THEN Pilot
                                  ELSE IF role[j] = Pilot THEN Copilot
                                  ELSE role[j]]
    /\ nextIndex' = [nextIndex EXCEPT ![i] =
                        [j \in Server |-> 1]]
    /\ matchIndex' = [matchIndex EXCEPT ![i] =
                        [j \in Server |-> 0]]
    /\ UNCHANGED <<messages, currentTerm, votedFor, candidateVars, logVars,
                   cpLog, cpBallot, pilotBallot, auxVars>>

\* CoPilot ClientRequest: an original-path client command (the pseudocode N11) proposed
\* by a pilot that is not paused (T2). A command already in the pilot's logs
\* is not proposed again (state-space reduction).
ClientRequest(i, v) ==
    /\ ostate[i] = Leader
    /\ ~InLog(i, v)
    /\ Propose(i, v)

(***************************************************************************)
(* Message plumbing                                                        *)
(***************************************************************************)

DuplicateMessage(m) ==
    /\ Send(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, copilotVars, auxVars>>

DropMessage(m) ==
    /\ Discard(m)
    /\ UNCHANGED <<serverVars, candidateVars, leaderVars, logVars, copilotVars, auxVars>>

=============================================================================
