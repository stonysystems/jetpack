------------------------------ MODULE jetpack ------------------------------
\* Jetpack (OSDI '26): the fast-path shim and its recovery protocol, written
\* line by line from docs/pseudocode.md (the authoritative
\* pseudocode). Line tags in comments (N12, L11, T2, ...) refer to the pseudocode.
\*
\* This module is INSTANCE'd by a wrapper that composes it with a base
\* protocol (base_raft, base_copilot, ...). The wrapper declares all
\* variables, maps them, wraps every action with UNCHANGED for the base's
\* private variables, and provides the base-specific pieces: the view a new
\* proposer starts (ViewOf), ApplyCommitted (execution order across
\* sequences), and the pause/resume of proposing (ostate = ToBeLeader).
\*
\* ---- Views (the pseudocode §0) ----
\* A view is a record [epoch, replica_ids, proposing_replica_ids] supplied by
\* the base protocol; views are compared by epoch only, and the epoch
\* determines the record (EpochDeterminesMembership in the wrapper). NilView
\* (epoch 0) is the pseudocode's ⊥. Every replica stores two whole records:
\*   rstate[i].lnv   last normal view (v_n): the fast-path view i acks in;
\*                   advances only when a view's Recovered(·) is committed
\*   rstate[i].nv    new view (v): the latest view whose recovery i joined
\* with the invariants lnv.epoch <= nv.epoch and
\* mode = Recovery <=> nv.epoch > lnv.epoch.
\*
\* ---- Pools, ballots, accepted values ----
\* the pseudocode indexes pool / max_seen_ballot / accepted by a fast-path view w. Only
\* pool[lnv] is ever read (a replica with lnv < v_n never acked in v_n, so its
\* pool[v_n] is empty, and v_n < lnv is Nack'd), so rstate[i].pool is the pool
\* of lnv and is reset to {} whenever lnv advances. max_seen_ballot and
\* accepted are kept per v_n as sets of records (msb, acc).
\*
\* ---- Coordinators ----
\* Every proposer of a new view runs a coordinator (T1); several coordinators
\* of one view are safe (ballots). cstate[i] is i's coordinator: phase, the
\* view it recovers for, v_n, ballot k, the recovery set and the replies.
\*
\* ---- Modeling choices (not protocol changes) ----
\*   - No return values (SpecExec) and no dedup table are modeled; dedup is
\*     "a command is executed once" (N25) in ApplyCommitted.
\*   - A conflict alone gets no reply in the pseudocode (N18 comment); the model sends a
\*     FastNack with mconflict = TRUE so the client's "timeout" is explicit.
\*     This only affects liveness.
\*   - Client resends (N10) are not modeled; every command id is used once.
\*   - Random backoff (L46) is not modeled: TLC explores all interleavings.
\*   - FinishRecovery carries v_n as metadata (mvn) so RecoveredAgreement can
\*     be stated per v_n; the protocol does not need it.
\*   - "Executed on R" is approximated by the global execution trace
\*     (original_execution_cmds): Pending(i) = commands in i's log that are
\*     not in that trace.

EXTENDS Integers, Naturals, FiniteSets, Sequences, TLC

CONSTANTS Server, Client, CmdId, Key, NoOpCmd,
          InitialMembers,     \* initial replica set (subset of Server)
          InitialProposers,   \* proposers of the initial view (Raft: the initial leader)
          InitialEpoch,       \* epoch of the initial view (base-specific numbering)
          Proposer,           \* set of log-sequence ids (protocol-specific)
          ProposerOf(_)       \* Server -> Proposer

Nil == "Nil"
NilCmd == [tag |-> "NilCmd"]

\* Replica modes (the pseudocode R.mode).
Normal   == "Normal"
Recovery == "Recovery"

\* Coordinator phases.
Idle      == "Idle"       \* not coordinating
Begun     == "Begun"      \* L3 sent, collecting BeginRecoveryOK
Prepared  == "Prepared"   \* L10 sent, collecting PrepareOK
Accepted  == "Accepted"   \* L30 sent, collecting AcceptOK
Submitted == "Submitted"  \* L47 done, waiting for own Recovered(S) to commit
Finishing == "Finishing"  \* L48 sent, retransmitting (L49) until all FinishRecoveryOK

\* Base protocol roles (re-declared for guards). ToBeLeader = a proposer
\* paused by T1; it becomes Leader when its own Recovered(S) commits (T2).
Follower   == "Follower"
Candidate  == "Candidate"
ToBeLeader == "ToBeLeader"
Leader     == "Leader"

\* Log entry kinds this module reads or writes.
AppendCommand    == "AppendCommand"
RecoveredCommand == "Recovered"

\* Message types (the pseudocode names).
FastCmd          == "FastCmd"
FastAck          == "FastAck"
FastNack         == "FastNack"
BeginRecovery    == "BeginRecovery"
BeginRecoveryOK  == "BeginRecoveryOK"
Prepare          == "Prepare"
PrepareOK        == "PrepareOK"
Accept           == "Accept"
AcceptOK         == "AcceptOK"
Nack             == "Nack"
FinishRecovery   == "FinishRecovery"
FinishRecoveryOK == "FinishRecoveryOK"

(***************************************************************************)
(* Data types                                                              *)
(***************************************************************************)

Commands == { [cmd_id |-> id, key |-> k] : id \in CmdId, k \in Key }

View == [epoch: Nat, replica_ids: SUBSET Server, proposing_replica_ids: SUBSET Server]

NilView == [epoch |-> 0, replica_ids |-> {}, proposing_replica_ids |-> {}]

DefaultView == [epoch |-> InitialEpoch,
                replica_ids |-> InitialMembers,
                proposing_replica_ids |-> InitialProposers]

\* the pseudocode §0 replica state. msb: {[vn, k]} (max_seen_ballot per v_n epoch, at
\* most one record per vn); acc: {[vn, view, k, value]} (accepted per v_n).
ReplicaOf(v) == [lnv |-> v, nv |-> v, mode |-> Normal, pool |-> {}, msb |-> {}, acc |-> {}]
InitReplica  == ReplicaOf(DefaultView)
NewReplica   == ReplicaOf(NilView)      \* a replica added by a reconfiguration

\* Sentinels (TLC only compares values of one type, so "none" is a record of
\* the right shape): NoReply = no BeginRecoveryOK yet (epoch -1 < ⊥ = 0);
\* NoAcc = accepted[v_n] = ⊥; NoPrep = no PrepareOK yet; NoBallot = ⊥ in a Nack.
NoReply  == [epoch |-> -1, replica_ids |-> {}, proposing_replica_ids |-> {}]
NoAcc    == [present |-> FALSE, view |-> 0, k |-> 0, value |-> {}]
NoPrep   == [got |-> FALSE, acc |-> NoAcc, pool |-> {}]
NoBallot == -1

IdleCoord == [phase |-> Idle, view |-> NilView, vn |-> NilView, k |-> 0, rset |-> {},
              br   |-> [s \in Server |-> NoReply],  \* BeginRecoveryOK: reported lnv
              prep |-> [s \in Server |-> NoPrep],   \* PrepareOK: [got, acc, pool]
              acc  |-> [s \in Server |-> FALSE],    \* AcceptOK received
              fin  |-> [s \in Server |-> FALSE]]    \* FinishRecoveryOK received

\* The Recovered(S) a proposer submitted in view epoch (0 = none), and
\* whether it has already resumed proposing after it committed (T2).
NoSubmission == [epoch |-> 0, set |-> {}, done |-> TRUE]

(***************************************************************************)
(* Variables                                                               *)
(***************************************************************************)

VARIABLES
    messages,

    \* Base protocol variables (Jetpack reads/writes these).
    \* log[i][j] = sequence of entries for proposer j on server i
    \* commitIndex[i][j] = commit progress for proposer j on server i
    currentTerm,
    ostate,
    log,
    commitIndex,

    \* Jetpack per-server variables.
    rstate,       \* replica state (the pseudocode R.*)
    cstate,       \* coordinator state (the pseudocode C.*)
    subm,         \* the Recovered(S) submitted by this proposer (T2, L47, L53)

    \* Client-side variables.
    client_view,
    client_pending,
    client_successes,
    client_heard_from,
    client_issued,

    \* Execution tracking.
    original_execution_cmds,  \* commands applied from committed logs, each once
    execution_cmds,           \* fast commits (at commit time) + applied commands
    applied,                  \* applied[j] = committed entries of sequence j applied so far
    fast_committed            \* {[cmd, epoch]}: fast commits and the view they were made in

baseVars      == <<currentTerm, ostate, log, commitIndex>>
jetpackVars   == <<rstate, cstate, subm>>
clientVars    == <<client_view, client_pending, client_successes, client_heard_from, client_issued>>
executionVars == <<original_execution_cmds, execution_cmds, applied, fast_committed>>

(***************************************************************************)
(* Quorums (the pseudocode §0, for any n)                                             *)
(***************************************************************************)

MajSize(S)   == Cardinality(S) \div 2 + 1          \* maj(v)
Threshold(S) == MajSize(S) \div 2 + 1              \* t(v)
SuperSize(S) == Cardinality(S) - MajSize(S) + Threshold(S)   \* sq(v)

Maj(S) == {q \in SUBSET S : Cardinality(q) >= MajSize(S)}

\* A fast commit needs sq(v) replicas of v including every proposer of v (N3).
FastpathQuorum(v) ==
    {q \in SUBSET v.replica_ids :
        /\ v.proposing_replica_ids \subseteq q
        /\ Cardinality(q) >= SuperSize(v.replica_ids)}

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

SeqToSet(s) == {s[i] : i \in 1..Len(s)}

RECURSIVE SetToSeq(_)
SetToSeq(S) ==
    IF S = {} THEN <<>>
    ELSE LET x == CHOOSE x \in S : TRUE
         IN <<x>> \o SetToSeq(S \ {x})

RECURSIVE Flatten(_)
Flatten(ss) == IF ss = <<>> THEN <<>> ELSE Head(ss) \o Flatten(Tail(ss))

\* Message bag.
WithMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN [msgs EXCEPT ![m] = msgs[m] + 1]
    ELSE msgs @@ (m :> 1)

WithoutMessage(m, msgs) ==
    IF m \in DOMAIN msgs THEN
        IF msgs[m] <= 1 THEN [i \in DOMAIN msgs \ {m} |-> msgs[i]]
        ELSE [msgs EXCEPT ![m] = msgs[m] - 1]
    ELSE msgs

Send(m) == messages' = WithMessage(m, messages)
Discard(m) == messages' = WithoutMessage(m, messages)
Reply(response, request) ==
    messages' = WithoutMessage(request, WithMessage(response, messages))

RECURSIVE AddMessages(_,_)
AddMessages(ms, msgs) ==
    IF ms = {} THEN msgs
    ELSE LET m == CHOOSE x \in ms : TRUE
         IN AddMessages(ms \ {m}, WithMessage(m, msgs))

\* Reply to one request and broadcast a set of messages in the same step.
ReplyAndSend(response, request, ms) ==
    messages' = AddMessages(ms, WithoutMessage(request, WithMessage(response, messages)))

DiscardAndSend(request, ms) ==
    messages' = AddMessages(ms, WithoutMessage(request, messages))

RECURSIVE RemoveCmd(_,_)
RemoveCmd(seq, cmd) ==
    IF seq = <<>> THEN <<>>
    ELSE LET head == seq[1]
             tail == SubSeq(seq, 2, Len(seq))
         IN IF head = cmd THEN RemoveCmd(tail, cmd)
            ELSE <<head>> \o RemoveCmd(tail, cmd)

RECURSIVE Dedup(_)
Dedup(seq) ==
    IF seq = <<>> THEN <<>>
    ELSE LET head == seq[1]
             tail == SubSeq(seq, 2, Len(seq))
         IN <<head>> \o Dedup(RemoveCmd(tail, head))

FilterNoOps(seq) == SelectSeq(seq, LAMBDA x : x # NoOpCmd)

\* Two commands conflict if they access the same key (reads are not
\* distinguished from writes in the model).
CmdConflicts(a, b) == a.key = b.key /\ a # b

RECURSIVE IndexOf(_, _)
IndexOf(s, e) ==
    IF s = <<>> THEN 0
    ELSE IF Head(s) = e THEN 1
    ELSE LET rest == IndexOf(Tail(s), e)
         IN IF rest = 0 THEN 0 ELSE rest + 1

ConflictOrderPreserved(s1, s2) ==
    \A k1 \in 1..Len(s1) : \A k2 \in 1..Len(s1) :
        (/\ k1 < k2
         /\ CmdConflicts(s1[k1], s1[k2])
         /\ IndexOf(s2, s1[k1]) > 0
         /\ IndexOf(s2, s1[k2]) > 0)
        => IndexOf(s2, s1[k1]) < IndexOf(s2, s1[k2])

\* ---- Log entries ----
\* AppendCommand entries carry one command in .value; Recovered entries carry
\* .value = [set, vepoch, vn, by] (L47, L53); other entries (config) carry
\* no command.
EntryCmds(e) ==
    IF e.command = RecoveredCommand THEN e.value.set
    ELSE IF e.command = AppendCommand THEN {e.value}
    ELSE {}

\* The fixed execution order of an entry's commands (L50).
EntrySeq(e) == SetToSeq(EntryCmds(e))

RecoveredEntry(i, v, vn, S) ==
    [command |-> RecoveredCommand,
     term    |-> currentTerm[i],
     value   |-> [cmd_id |-> Nil, key |-> Nil,
                  set |-> S, vepoch |-> v.epoch, vn |-> vn.epoch, by |-> i]]

LogCmds(i) ==
    UNION { UNION {EntryCmds(log[i][j][k]) : k \in 1..Len(log[i][j])} : j \in Proposer }

CommittedCmds(i) ==
    UNION { UNION {EntryCmds(log[i][j][k]) : k \in 1..commitIndex[i][j]} : j \in Proposer }

CommittedCmdSeq(i, j) ==
    Flatten([k \in 1..commitIndex[i][j] |-> EntrySeq(log[i][j][k])])

Executed == SeqToSet(original_execution_cmds)

\* Pending(R.olog) (N13): commands in i's log that are not executed yet.
Pending(i) == LogCmds(i) \ Executed

\* i's own Recovered(S) for view epoch e is committed (T2).
OwnRecoveredCommitted(i, e) ==
    \E j \in Proposer : \E k \in 1..commitIndex[i][j] :
        /\ log[i][j][k].command = RecoveredCommand
        /\ log[i][j][k].value.by = i
        /\ log[i][j][k].value.vepoch = e

\* ---- Replica state helpers (the pseudocode §0) ----

\* max_seen_ballot[vn], 0 when none (the pseudocode's ⊥; ballots start at 1).
MSB(r, vn) ==
    LET es == {e \in r.msb : e.vn = vn}
    IN IF es = {} THEN 0 ELSE (CHOOSE e \in es : TRUE).k

SetMSB(r, vn, k) ==
    [r EXCEPT !.msb = {e \in r.msb : e.vn # vn} \cup {[vn |-> vn, k |-> k]}]

\* accepted[vn]: [present, view, k, value]; NoAcc when none (⊥).
Acc(r, vn) ==
    LET es == {e \in r.acc : e.vn = vn}
    IN IF es = {} THEN NoAcc
       ELSE LET e == CHOOSE e \in es : TRUE
            IN [present |-> TRUE, view |-> e.view, k |-> e.k, value |-> e.value]

SetAcc(r, vn, view, k, value) ==
    [r EXCEPT !.acc = {e \in r.acc : e.vn # vn}
                      \cup {[vn |-> vn, view |-> view, k |-> k, value |-> value]}]

\* join(v): R joins the recovery round of v (v > R.new_view). Ballots of
\* older views are void; accepted values are kept.
Join(r, v) ==
    IF v.epoch > r.nv.epoch
    THEN [r EXCEPT !.nv = v, !.mode = Recovery, !.msb = {}]
    ELSE r

\* learn(u): R learns that view u is (or was) normal somewhere. Runs before
\* the handler of every message carrying a last normal view. Advancing lnv
\* resets the pool: R never acked in u, so pool[u] = {}.
Learn(r, u) ==
    IF u.epoch > r.lnv.epoch
    THEN IF u.epoch >= r.nv.epoch
         THEN [r EXCEPT !.lnv = u, !.nv = u, !.mode = Normal, !.pool = {}]
         ELSE [r EXCEPT !.lnv = u, !.pool = {}]
    ELSE r

\* Lexicographic order on (view, k) of accepted records (L24).
AccLeq(a, b) == \/ a.view < b.view
                \/ a.view = b.view /\ a.k <= b.k

(***************************************************************************)
(* Initialization                                                          *)
(***************************************************************************)

InitJetpackVars ==
    /\ rstate = [i \in Server |-> IF i \in InitialMembers THEN InitReplica ELSE NewReplica]
    /\ cstate = [i \in Server |-> IdleCoord]
    /\ subm   = [i \in Server |-> NoSubmission]

InitClientVars ==
    /\ client_view       = [c \in Client |-> DefaultView]
    /\ client_pending    = [c \in Client |-> NilCmd]
    /\ client_successes  = [c \in Client |-> {}]
    /\ client_heard_from = [c \in Client |-> {}]
    /\ client_issued     = {}

InitExecutionVars ==
    /\ original_execution_cmds = <<>>
    /\ execution_cmds = <<>>
    /\ applied = [j \in Proposer |-> 0]
    /\ fast_committed = {}

(***************************************************************************)
(* §1 Normal path                                                          *)
(***************************************************************************)

AvailableCommands == {cmd \in Commands : cmd.cmd_id \notin {x.cmd_id : x \in client_issued}}

\* N1: the client sends FastCmd(K.view, c) to replicas(K.view).
ClientSendFastCmd(c) ==
    /\ client_pending[c] = NilCmd
    /\ \E cmd \in AvailableCommands :
          LET view == client_view[c]
              msgSet == { [mtype |-> FastCmd, msource |-> c, mdest |-> s,
                           mview |-> view, mcmd |-> cmd] : s \in view.replica_ids }
          IN /\ messages' = AddMessages(msgSet, messages)
             /\ client_pending'   = [client_pending EXCEPT ![c] = cmd]
             /\ client_successes' = [client_successes EXCEPT ![c] = {}]
             /\ client_heard_from' = [client_heard_from EXCEPT ![c] = {}]
             /\ client_issued' = client_issued \cup {cmd}
             /\ UNCHANGED <<baseVars, jetpackVars, client_view, executionVars>>

\* N12–N20: a replica handles FastCmd(v, c).
HandleFastCmd(i, m) ==
    /\ m.mtype = FastCmd
    /\ i = m.mdest
    /\ LET v    == m.mview
           cmd  == m.mcmd
           r    == rstate[i]
           viewOk   == v.epoch = r.lnv.epoch /\ r.mode = Normal          \* N12
           conflict == \E d \in r.pool \cup Pending(i) : CmdConflicts(d, cmd)   \* N13
           ack  == viewOk /\ ~conflict
           reply == IF ack
                    THEN [mtype |-> FastAck, msource |-> i, mdest |-> m.msource,
                          mview |-> v, mcmd |-> cmd]                       \* N16
                    ELSE [mtype |-> FastNack, msource |-> i, mdest |-> m.msource,
                          mlnv |-> r.lnv, mmode |-> r.mode, mcmd |-> cmd,
                          mconflict |-> viewOk]                            \* N18 (conflict: modeled timeout)
           j    == ProposerOf(i)
           \* N19–N20: a Normal proposer proposes c regardless of conflicts or v.
           propose == r.mode = Normal /\ ostate[i] = Leader /\ cmd \notin LogCmds(i)
           newLog == Append(log[i][j], [command |-> AppendCommand,
                                        term    |-> currentTerm[i],
                                        value   |-> cmd])
       IN /\ rstate' = IF ack THEN [rstate EXCEPT ![i].pool = r.pool \cup {cmd}] ELSE rstate   \* N14
          /\ log' = IF propose THEN [log EXCEPT ![i][j] = newLog] ELSE log
          /\ Reply(reply, m)
          /\ UNCHANGED <<currentTerm, ostate, commitIndex, cstate, subm,
                         clientVars, executionVars>>

\* N2–N5: the client counts FastAcks of its current attempt's view.
HandleFastAck(c, m) ==
    /\ m.mtype = FastAck
    /\ m.mdest = c
    /\ client_pending[c] = m.mcmd
    /\ LET view == client_view[c]
           newHeard == client_heard_from[c] \cup {m.msource}
           newSuccesses == IF m.mview.epoch = view.epoch
                           THEN client_successes[c] \cup {m.msource}
                           ELSE client_successes[c]
           fastOk == newSuccesses \in FastpathQuorum(view)
       IN /\ client_successes'  = [client_successes EXCEPT ![c] = IF fastOk THEN {} ELSE newSuccesses]
          /\ client_heard_from' = [client_heard_from EXCEPT ![c] = IF fastOk THEN {} ELSE newHeard]
          /\ client_pending'    = IF fastOk THEN [client_pending EXCEPT ![c] = NilCmd] ELSE client_pending
          /\ execution_cmds'    = IF fastOk THEN Append(execution_cmds, m.mcmd) ELSE execution_cmds
          /\ fast_committed'    = IF fastOk THEN fast_committed \cup {[cmd |-> m.mcmd, epoch |-> view.epoch]}
                                  ELSE fast_committed
          /\ Discard(m)
          /\ UNCHANGED <<baseVars, jetpackVars, client_view, client_issued,
                         original_execution_cmds, applied>>

\* N6–N9: a FastNack. A newer last normal view ends the attempt and moves
\* K.view forward (N8–N9); otherwise the attempt is abandoned once no
\* fast-path quorum can still form (the model's "timeout", N7).
HandleFastNack(c, m) ==
    /\ m.mtype = FastNack
    /\ m.mdest = c
    /\ client_pending[c] = m.mcmd
    /\ LET view == client_view[c]
           newerView == m.mlnv.epoch > view.epoch
           newHeard == client_heard_from[c] \cup {m.msource}
           remaining == view.replica_ids \ newHeard
           canStillSucceed ==
               \E q \in FastpathQuorum(view) : q \subseteq (client_successes[c] \cup remaining)
           abandon == newerView \/ ~canStillSucceed
       IN /\ client_view' = IF newerView THEN [client_view EXCEPT ![c] = m.mlnv] ELSE client_view
          /\ client_successes'  = IF abandon THEN [client_successes EXCEPT ![c] = {}] ELSE client_successes
          /\ client_heard_from' = [client_heard_from EXCEPT ![c] = IF abandon THEN {} ELSE newHeard]
          /\ client_pending'    = IF abandon THEN [client_pending EXCEPT ![c] = NilCmd] ELSE client_pending
          /\ Discard(m)
          /\ UNCHANGED <<baseVars, jetpackVars, client_issued, executionVars>>

\* N21, N24: GC of an executed command, only while Normal (frozen in Recovery).
\* Evict notices (N23) are not modeled separately: any Normal replica may
\* drop an executed command from its pool.
GC(i, cmd) ==
    /\ rstate[i].mode = Normal
    /\ cmd \in rstate[i].pool
    /\ cmd \in Executed
    /\ rstate' = [rstate EXCEPT ![i].pool = rstate[i].pool \ {cmd}]
    /\ UNCHANGED <<messages, baseVars, cstate, subm, clientVars, executionVars>>

\* N25 / L50: apply the next committed entry of sequence j, executing each of
\* its commands once (dedup by command) in the fixed order EntrySeq. Any
\* server whose committed prefix contains the entry may apply it; committed
\* prefixes agree (CommittedLogAgreement), so the entry is the same.
\* Protocol-specific wrappers (Copilot, Mencius) define their own order.
ApplyCommitted(i, j) ==
    /\ applied[j] < commitIndex[i][j]
    /\ LET e == log[i][j][applied[j] + 1]
           newCmds == SelectSeq(EntrySeq(e), LAMBDA x : x \notin Executed)
       IN /\ original_execution_cmds' = original_execution_cmds \o newCmds
          /\ execution_cmds' = execution_cmds \o newCmds
          /\ applied' = [applied EXCEPT ![j] = applied[j] + 1]
    /\ UNCHANGED <<messages, baseVars, jetpackVars, clientVars, fast_committed>>

(***************************************************************************)
(* §2 Recovery: trigger and Phase 1                                        *)
(***************************************************************************)

\* T1 / L1–L3: proposer i of the new view v starts a coordinator for v. The
\* wrapper supplies v (ViewOf) and the guard that i is paused (ToBeLeader).
StartRecovery(i, v) ==
    /\ i \in v.proposing_replica_ids
    /\ v.epoch > cstate[i].view.epoch        \* one coordinator run per view
    /\ v.epoch > rstate[i].lnv.epoch
    /\ LET msgSet == { [mtype |-> BeginRecovery, msource |-> i, mdest |-> s,
                        mview |-> v] : s \in v.replica_ids }
       IN /\ messages' = AddMessages(msgSet, messages)
          /\ cstate' = [cstate EXCEPT ![i] = [IdleCoord EXCEPT !.phase = Begun,
                                                                !.view = v,
                                                                !.k = 1]]
          /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L4–L8.
HandleBeginRecovery(i, m) ==
    /\ m.mtype = BeginRecovery
    /\ i = m.mdest
    /\ LET v == m.mview
           r == rstate[i]
       IN IF v.epoch >= r.nv.epoch /\ v.epoch > r.lnv.epoch        \* L4 gate
          THEN /\ rstate' = [rstate EXCEPT ![i] = Join(r, v)]         \* L5
               /\ Reply([mtype |-> BeginRecoveryOK, msource |-> i, mdest |-> m.msource,
                         mview |-> v, mlnv |-> r.lnv], m)              \* L6
          ELSE /\ rstate' = rstate
               /\ Reply([mtype |-> Nack, msource |-> i, mdest |-> m.msource,
                         mnv |-> r.nv, mlnv |-> r.lnv, mk |-> NoBallot], m)   \* L8
    /\ UNCHANGED <<baseVars, cstate, subm, clientVars, executionVars>>

\* The coordinator records a BeginRecoveryOK of its current run (and learns
\* the reported last normal view).
HandleBeginRecoveryOK(i, m) ==
    /\ m.mtype = BeginRecoveryOK
    /\ i = m.mdest
    /\ LET cs == cstate[i]
       IN /\ rstate' = [rstate EXCEPT ![i] = Learn(rstate[i], m.mlnv)]
          /\ cstate' = IF cs.phase = Begun /\ m.mview.epoch = cs.view.epoch
                       THEN [cstate EXCEPT ![i].br[m.msource] = m.mlnv]
                       ELSE cstate
    /\ Discard(m)
    /\ UNCHANGED <<baseVars, subm, clientVars, executionVars>>

(***************************************************************************)
(* Phase 2: a Paxos round for v_n                                          *)
(***************************************************************************)

PrepareMsgs(i, cs) ==
    { [mtype |-> Prepare, msource |-> i, mdest |-> s,
       mview |-> cs.view, mvn |-> cs.vn, mk |-> cs.k] : s \in cs.vn.replica_ids }

\* L9–L10: v_n is the largest last normal view reported by maj(v) replicas.
CompleteBeginRecovery(i) ==
    /\ cstate[i].phase = Begun
    /\ \E qs \in Maj(cstate[i].view.replica_ids) :
         /\ \A s \in qs : cstate[i].br[s].epoch >= 0
         /\ LET reps == {cstate[i].br[s] : s \in qs}
                vn == CHOOSE r \in reps : \A r2 \in reps : r.epoch >= r2.epoch
                cs == [cstate[i] EXCEPT !.phase = Prepared, !.vn = vn,
                                        !.prep = [s \in Server |-> NoPrep]]
            IN /\ vn.epoch > 0
               /\ messages' = AddMessages(PrepareMsgs(i, cs), messages)
               /\ cstate' = [cstate EXCEPT ![i] = cs]
    /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L11–L22. learn(v_n) runs first; then step 1 aligns views, step 2 compares
\* ballots (strict). After learn, lnv.epoch >= vn.epoch, so in the ELSE
\* branch lnv = vn and r1.pool is pool[v_n].
HandlePrepare(i, m) ==
    /\ m.mtype = Prepare
    /\ i = m.mdest
    /\ LET v  == m.mview
           vn == m.mvn
           k  == m.mk
           r1 == Learn(rstate[i], vn)
       IN IF v.epoch < r1.nv.epoch \/ r1.lnv.epoch > vn.epoch                 \* L11
          THEN /\ rstate' = [rstate EXCEPT ![i] = r1]
               /\ Reply([mtype |-> Nack, msource |-> i, mdest |-> m.msource,
                         mnv |-> r1.nv, mlnv |-> r1.lnv, mk |-> NoBallot], m)   \* L12
          ELSE LET r2 == Join(r1, v)                                          \* L14
               IN IF k > MSB(r2, vn.epoch)                                    \* L15
                  THEN /\ rstate' = [rstate EXCEPT ![i] = SetMSB(r2, vn.epoch, k)]   \* L16
                       /\ Reply([mtype |-> PrepareOK, msource |-> i, mdest |-> m.msource,
                                 mview |-> v, mvn |-> vn, mk |-> k,
                                 macc |-> Acc(r2, vn.epoch),                   \* L17–L18
                                 mpool |-> r2.pool], m)                        \* L19–L20
                  ELSE /\ rstate' = [rstate EXCEPT ![i] = r2]
                       /\ Reply([mtype |-> Nack, msource |-> i, mdest |-> m.msource,
                                 mnv |-> r2.nv, mlnv |-> r2.lnv,
                                 mk |-> MSB(r2, vn.epoch)], m)                 \* L22
    /\ UNCHANGED <<baseVars, cstate, subm, clientVars, executionVars>>

HandlePrepareOK(i, m) ==
    /\ m.mtype = PrepareOK
    /\ i = m.mdest
    /\ LET cs == cstate[i]
       IN cstate' = IF /\ cs.phase = Prepared
                       /\ m.mview.epoch = cs.view.epoch
                       /\ m.mvn.epoch = cs.vn.epoch
                       /\ m.mk = cs.k
                    THEN [cstate EXCEPT ![i].prep[m.msource] =
                              [got |-> TRUE, acc |-> m.macc, pool |-> m.mpool]]
                    ELSE cstate
    /\ Discard(m)
    /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L23–L30: choose the recovery set from maj(v_n) replies.
CompletePrepare(i) ==
    /\ cstate[i].phase = Prepared
    /\ \E qs \in Maj(cstate[i].vn.replica_ids) :
         /\ \A s \in qs : cstate[i].prep[s].got
         /\ LET cs    == cstate[i]
                accs  == {a \in {cs.prep[s].acc : s \in qs} : a.present}
                pools == UNION {cs.prep[s].pool : s \in qs}
                rset  == IF accs /= {}
                         THEN (CHOOSE a \in accs : \A b \in accs : AccLeq(b, a)).value   \* L24
                         ELSE {c \in pools :                                            \* L26–L29
                                 Cardinality({s \in qs : c \in cs.prep[s].pool})
                                     >= Threshold(cs.vn.replica_ids)}
                msgSet == { [mtype |-> Accept, msource |-> i, mdest |-> s,
                             mview |-> cs.view, mvn |-> cs.vn, mk |-> cs.k,
                             mvalue |-> rset] : s \in cs.vn.replica_ids }
            IN /\ messages' = AddMessages(msgSet, messages)                             \* L30
               /\ cstate' = [cstate EXCEPT ![i] = [cs EXCEPT !.phase = Accepted,
                                                            !.rset = rset,
                                                            !.acc = [s \in Server |-> FALSE]]]
    /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L31–L40.
HandleAccept(i, m) ==
    /\ m.mtype = Accept
    /\ i = m.mdest
    /\ LET v  == m.mview
           vn == m.mvn
           k  == m.mk
           r1 == Learn(rstate[i], vn)
       IN IF v.epoch < r1.nv.epoch \/ r1.lnv.epoch > vn.epoch                 \* L31
          THEN /\ rstate' = [rstate EXCEPT ![i] = r1]
               /\ Reply([mtype |-> Nack, msource |-> i, mdest |-> m.msource,
                         mnv |-> r1.nv, mlnv |-> r1.lnv, mk |-> NoBallot], m)   \* L32
          ELSE LET r2 == Join(r1, v)                                          \* L34
               IN IF k >= MSB(r2, vn.epoch)                                   \* L35
                  THEN /\ rstate' = [rstate EXCEPT ![i] =
                              SetAcc(SetMSB(r2, vn.epoch, k), vn.epoch, v.epoch, k, m.mvalue)]  \* L36–L37
                       /\ Reply([mtype |-> AcceptOK, msource |-> i, mdest |-> m.msource,
                                 mview |-> v, mvn |-> vn, mk |-> k], m)        \* L38
                  ELSE /\ rstate' = [rstate EXCEPT ![i] = r2]
                       /\ Reply([mtype |-> Nack, msource |-> i, mdest |-> m.msource,
                                 mnv |-> r2.nv, mlnv |-> r2.lnv,
                                 mk |-> MSB(r2, vn.epoch)], m)                 \* L40
    /\ UNCHANGED <<baseVars, cstate, subm, clientVars, executionVars>>

HandleAcceptOK(i, m) ==
    /\ m.mtype = AcceptOK
    /\ i = m.mdest
    /\ LET cs == cstate[i]
       IN cstate' = IF /\ cs.phase = Accepted
                       /\ m.mview.epoch = cs.view.epoch
                       /\ m.mvn.epoch = cs.vn.epoch
                       /\ m.mk = cs.k
                    THEN [cstate EXCEPT ![i].acc[m.msource] = TRUE]
                    ELSE cstate
    /\ Discard(m)
    /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L41–L46: the coordinator handles a Nack (learn(last_normal_view') first).
HandleNack(i, m) ==
    /\ m.mtype = Nack
    /\ i = m.mdest
    /\ LET cs == cstate[i]
           collecting == cs.phase \in {Begun, Prepared, Accepted}
           inRound == cs.phase \in {Prepared, Accepted}
       IN /\ rstate' = [rstate EXCEPT ![i] = Learn(rstate[i], m.mlnv)]
          /\ IF ~collecting
             THEN /\ cstate' = cstate
                  /\ Discard(m)
             ELSE IF m.mnv.epoch > cs.view.epoch \/ m.mlnv.epoch >= cs.view.epoch    \* L41
             THEN /\ cstate' = [cstate EXCEPT ![i] = IdleCoord]                        \* L42
                  /\ Discard(m)
             ELSE IF inRound /\ m.mlnv.epoch > cs.vn.epoch                             \* L43
             THEN LET cs2 == [cs EXCEPT !.phase = Prepared, !.vn = m.mlnv,
                                        !.prep = [s \in Server |-> NoPrep]]
                  IN /\ cstate' = [cstate EXCEPT ![i] = cs2]                           \* L44
                     /\ DiscardAndSend(m, PrepareMsgs(i, cs2))
             ELSE IF inRound /\ m.mk /= NoBallot /\ m.mk >= cs.k                       \* L45
             THEN LET cs2 == [cs EXCEPT !.phase = Prepared, !.k = m.mk + 1,
                                        !.prep = [s \in Server |-> NoPrep]]
                  IN /\ cstate' = [cstate EXCEPT ![i] = cs2]                           \* L46
                     /\ DiscardAndSend(m, PrepareMsgs(i, cs2))
             ELSE /\ cstate' = cstate
                  /\ Discard(m)
    /\ UNCHANGED <<baseVars, subm, clientVars, executionVars>>

(***************************************************************************)
(* Phase 3: resubmit and resume                                            *)
(***************************************************************************)

\* L47: on maj(v_n) AcceptOKs, submit Recovered(C.rset) to C's own proposer
\* as one log entry. If this proposer already submitted a copy for this view
\* (L53 arrived first), no second entry is appended. A coordinator whose
\* proposer was deposed meanwhile (ostate no longer Leader/ToBeLeader) cannot
\* submit: its entry would never commit, and in Raft a follower must not
\* create entries; it just moves on and waits for the newer view (L42).
CompleteAccept(i) ==
    /\ cstate[i].phase = Accepted
    /\ \E qs \in Maj(cstate[i].vn.replica_ids) : \A s \in qs : cstate[i].acc[s]
    /\ LET cs == cstate[i]
           j  == ProposerOf(i)
           fresh == /\ subm[i].epoch < cs.view.epoch
                    /\ ostate[i] \in {Leader, ToBeLeader}
       IN /\ log'  = IF fresh
                     THEN [log EXCEPT ![i][j] = Append(log[i][j], RecoveredEntry(i, cs.view, cs.vn, cs.rset))]
                     ELSE log
          /\ subm' = IF fresh
                     THEN [subm EXCEPT ![i] = [epoch |-> cs.view.epoch, set |-> cs.rset, done |-> FALSE]]
                     ELSE subm
          /\ cstate' = [cstate EXCEPT ![i].phase = Submitted]
    /\ UNCHANGED <<messages, currentTerm, ostate, commitIndex, rstate, clientVars, executionVars>>

\* T2 / L48: the proposer's own Recovered(S) is committed: it resumes
\* proposing (ToBeLeader -> Leader). If it is the coordinator of that view,
\* it also sends FinishRecovery(v, S) to replicas(v) and starts retransmitting.
ResumeAfterRecovered(i) ==
    /\ ~subm[i].done
    /\ OwnRecoveredCommitted(i, subm[i].epoch)
    /\ LET cs == cstate[i]
           coord == cs.phase = Submitted /\ cs.view.epoch = subm[i].epoch
           msgSet == { [mtype |-> FinishRecovery, msource |-> i, mdest |-> s,
                        mview |-> cs.view, mvn |-> cs.vn, mvalue |-> cs.rset] : s \in cs.view.replica_ids }
       IN /\ subm' = [subm EXCEPT ![i].done = TRUE]
          /\ ostate' = [ostate EXCEPT ![i] = IF ostate[i] = ToBeLeader THEN Leader ELSE ostate[i]]
          /\ IF coord
             THEN /\ messages' = AddMessages(msgSet, messages)
                  /\ cstate' = [cstate EXCEPT ![i].phase = Finishing,
                                              ![i].fin = [s \in Server |-> FALSE]]
             ELSE /\ messages' = messages
                  /\ cstate' = cstate
    /\ UNCHANGED <<currentTerm, log, commitIndex, rstate, clientVars, executionVars>>

\* L49: retransmit FinishRecovery to replicas that have not acknowledged.
RetransmitFinishRecovery(i) ==
    /\ cstate[i].phase = Finishing
    /\ LET cs == cstate[i]
           pending == {s \in cs.view.replica_ids : ~cs.fin[s]}
           msgSet == { [mtype |-> FinishRecovery, msource |-> i, mdest |-> s,
                        mview |-> cs.view, mvn |-> cs.vn, mvalue |-> cs.rset] : s \in pending }
       IN /\ pending /= {}
          /\ messages' = AddMessages(msgSet, messages)
    /\ UNCHANGED <<baseVars, jetpackVars, clientVars, executionVars>>

\* L51–L54: learn(v); a proposer of v that has not yet submitted a Recovered
\* in v submits this S as its own copy; reply FinishRecoveryOK.
HandleFinishRecovery(i, m) ==
    /\ m.mtype = FinishRecovery
    /\ i = m.mdest
    /\ LET v  == m.mview
           r1 == Learn(rstate[i], v)                                      \* L51
           j  == ProposerOf(i)
           copy == /\ r1.nv.epoch = v.epoch                               \* L52
                   /\ i \in v.proposing_replica_ids
                   /\ ostate[i] \in {Leader, ToBeLeader}                   \*   still a live proposer
                   /\ subm[i].epoch < v.epoch
       IN /\ rstate' = [rstate EXCEPT ![i] = r1]
          /\ log'  = IF copy
                     THEN [log EXCEPT ![i][j] = Append(log[i][j], RecoveredEntry(i, v, m.mvn, m.mvalue))]   \* L53
                     ELSE log
          /\ subm' = IF copy
                     THEN [subm EXCEPT ![i] = [epoch |-> v.epoch, set |-> m.mvalue, done |-> FALSE]]
                     ELSE subm
          /\ Reply([mtype |-> FinishRecoveryOK, msource |-> i, mdest |-> m.msource,
                    mview |-> v], m)                                      \* L54
    /\ UNCHANGED <<currentTerm, ostate, commitIndex, cstate, clientVars, executionVars>>

HandleFinishRecoveryOK(i, m) ==
    /\ m.mtype = FinishRecoveryOK
    /\ i = m.mdest
    /\ LET cs == cstate[i]
           hit == cs.phase = Finishing /\ m.mview.epoch = cs.view.epoch
           fin2 == [cs.fin EXCEPT ![m.msource] = TRUE]
           allIn == \A s \in cs.view.replica_ids : fin2[s]
       IN cstate' = IF ~hit THEN cstate
                    ELSE IF allIn THEN [cstate EXCEPT ![i] = IdleCoord]
                    ELSE [cstate EXCEPT ![i].fin = fin2]
    /\ Discard(m)
    /\ UNCHANGED <<baseVars, rstate, subm, clientVars, executionVars>>

\* L42 / L49: a coordinator stops when its own replica has learned that a
\* newer view exists, or (while still collecting replies) that its view is
\* already normal: S then arrives by FinishRecovery(v, S).
StopCoordinating(i) ==
    /\ cstate[i].phase /= Idle
    /\ LET cs == cstate[i]
           r  == rstate[i]
       IN \/ r.nv.epoch > cs.view.epoch
          \/ cs.phase \in {Begun, Prepared, Accepted} /\ r.lnv.epoch >= cs.view.epoch
    /\ cstate' = [cstate EXCEPT ![i] = IdleCoord]
    /\ UNCHANGED <<messages, baseVars, rstate, subm, clientVars, executionVars>>

(***************************************************************************)
(* Jetpack-only Next (the wrapper composes it with the base protocol and   *)
(* supplies StartRecovery's view and guard)                                *)
(***************************************************************************)

JetpackLocalNext ==
    \/ \E c \in Client : ClientSendFastCmd(c)
    \/ \E i \in Server, cmd \in Commands : GC(i, cmd)
    \/ \E i \in Server, j \in Proposer : ApplyCommitted(i, j)
    \/ \E i \in Server : CompleteBeginRecovery(i)
    \/ \E i \in Server : CompletePrepare(i)
    \/ \E i \in Server : CompleteAccept(i)
    \/ \E i \in Server : ResumeAfterRecovered(i)
    \/ \E i \in Server : RetransmitFinishRecovery(i)
    \/ \E i \in Server : StopCoordinating(i)

ServerReceive(i, m) ==
    \/ HandleFastCmd(i, m)
    \/ HandleBeginRecovery(i, m)
    \/ HandleBeginRecoveryOK(i, m)
    \/ HandlePrepare(i, m)
    \/ HandlePrepareOK(i, m)
    \/ HandleAccept(i, m)
    \/ HandleAcceptOK(i, m)
    \/ HandleNack(i, m)
    \/ HandleFinishRecovery(i, m)
    \/ HandleFinishRecoveryOK(i, m)

ClientReceive(c, m) ==
    \/ HandleFastAck(c, m)
    \/ HandleFastNack(c, m)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

\* Per-sequence committed log entries agree across servers.
CommittedLogAgreement ==
    \A i, i2 \in Server :
        \A p \in Proposer :
            LET limit == Min({commitIndex[i][p], commitIndex[i2][p]})
            IN \A k \in 1..limit : log[i][p][k] = log[i2][p][k]

\* Committed log order (entries expanded to commands) matches the execution
\* trace for conflicting commands. A command can recur in a committed sequence
\* (proposed at ack time and again inside a Recovered entry, or by two
\* proposers); only its first occurrence executes (N25), so the sequence is
\* deduplicated first.
LogOrderMatchesExecution ==
    \A i \in Server : \A p \in Proposer :
        ConflictOrderPreserved(Dedup(FilterNoOps(CommittedCmdSeq(i, p))), FilterNoOps(execution_cmds))

ExecutionDedupMatches ==
    LET origDedup == Dedup(FilterNoOps(original_execution_cmds))
        execDedup == Dedup(FilterNoOps(execution_cmds))
    IN /\ ConflictOrderPreserved(origDedup, execDedup)
       /\ ConflictOrderPreserved(execDedup, origDedup)

\* the pseudocode §0 invariants on every replica.
ReplicaInvariants ==
    \A i \in Server :
        /\ rstate[i].lnv.epoch <= rstate[i].nv.epoch
        /\ (rstate[i].mode = Recovery) <=> (rstate[i].nv.epoch > rstate[i].lnv.epoch)

\* Paxos agreement per v_n: all Recovered entries produced for the same v_n
\* carry the same set (even uncommitted ones, in any log).
RecoveredEntries ==
    UNION { { log[i][j][k] : k \in {k \in 1..Len(log[i][j]) : log[i][j][k].command = RecoveredCommand} }
            : i \in Server, j \in Proposer }

RecoveredAgreement ==
    \A e1, e2 \in RecoveredEntries :
        e1.value.vn = e2.value.vn => e1.value.set = e2.value.set

\* C1 (durability): once any replica's last normal view is past the view a
\* command was fast-committed in, that command is committed on the original
\* path somewhere.
FastCommitDurability ==
    \A fc \in fast_committed :
        (\E i \in Server : rstate[i].lnv.epoch > fc.epoch)
            => \E i \in Server : fc.cmd \in CommittedCmds(i)

\* Pools are pairwise conflict-free (N13–N14).
PoolsConflictFree ==
    \A i \in Server : \A a, b \in rstate[i].pool : ~CmdConflicts(a, b)

=============================================================================
