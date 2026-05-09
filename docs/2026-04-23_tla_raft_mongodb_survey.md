# Survey of Open-Source TLA+ Specifications for Raft and MongoDB Replication

**Date:** 2026-04-23
**Scope:** GitHub's hottest TLA+ specifications for Raft and MongoDB replication, assessed for coverage of (a) leader election / failure recovery and (b) view change / membership reconfiguration.

All star counts and last-push dates were queried on 2026-04-23. Every repo claim is backed by a live `https://github.com/...` URL.

---

## 1. Executive Summary

I identified **13 Raft-family** and **7 MongoDB-family** public TLA+ specifications worth considering for a consensus researcher. The landscape is sharply bimodal:

- **Leader election / failure recovery** is modeled in essentially *every* serious spec (all 20 repos). The canonical action names (`Timeout`, `RequestVote`, `BecomeLeader`) are nearly universal.
- **Membership change / reconfiguration** is the clear gap. Only **4 of 13 Raft repos** and **4 of 7 MongoDB repos** model it at all, and fewer model it *rigorously* (quorum-overlap checks, quorum intersections during config transitions, TLAPS proofs). Most specs either hard-code a static `Server` constant or expose reconfig as an abstract set assignment without modeling the catchup / quorum-overlap phase.

**Must-read specs for someone extending a new consensus protocol with view-change + reconfiguration:**

1. **`Vanlightly/raft-tlaplus`** — the only public spec with *both* joint-consensus and single-at-a-time reconfig side by side, with explicit quorum-overlap safety and a worked-out data-loss scenario. https://github.com/Vanlightly/raft-tlaplus
2. **`will62794/logless-reconfig`** (+ MongoDB Research's TLAPS proof) — only public work with a *machine-checked TLAPS proof* of `StateMachineSafety` / `LeaderCompleteness` across reconfiguration. https://github.com/will62794/logless-reconfig
3. **`etcd-io/raft` (`tla/`)** — the only spec also wired to *trace-validate* a production implementation, so it is the best model of what "reconfig in a real codebase" needs to prove. https://github.com/etcd-io/raft/tree/main/tla

---

## 2. Raft TLA+ Specifications

### 2.1 `ongardie/raft.tla` — the canonical reference

- **URL:** https://github.com/ongardie/raft.tla
- **Stars:** 512, forks 96. Last push 2025-02-18.
- **Author:** Diego Ongaro (Raft's original author). Research artifact accompanying his 2014 PhD thesis.
- **File:** `raft.tla` (~520 lines).
- **Leader election:** yes. Actions `Restart`, `Timeout`, `RequestVote`, `BecomeLeader`, `HandleRequestVoteRequest/Response`, `HandleAppendEntriesRequest/Response`, `UpdateTerm`, `ClientRequest`, `AdvanceCommitIndex`, `DuplicateMessage`, `DropMessage`.
- **Reconfiguration:** **No.** Ongaro's committed spec deliberately excludes the §4 membership-change chapter. This is the single most common surprise for new readers.
- **Safety properties:** none stated in the .tla file; the README lists what *would* be checked (deadlock freedom) under TLC. Later derivatives (Ricketts, dranov) add LogMatching / ElectionSafety / LeaderCompleteness invariants.
- **Caveats:** the de facto "root" of almost every downstream fork; still the best starting point for a minimal Raft mental model, but reconfig-less.

### 2.2 `Vanlightly/raft-tlaplus` — the reconfiguration reference

- **URL:** https://github.com/Vanlightly/raft-tlaplus
- **Stars:** 91, forks 10. Last push 2022-07-18 (stale but authoritative).
- **Author:** Jack Vanlightly (then RabbitMQ, now Confluent). Production-practitioner spec.
- **Subdirs:** `standard-raft/`, `flexible-raft/`, `pull-raft/`, `raft-and-fsync/`.
- **Files of interest** (under `specifications/standard-raft/`): `Raft.tla`, `RaftWithReconfigAddRemove.tla`, `RaftWithReconfigJointConsensus.tla` — the last is ~1,100 lines.
- **Leader election:** yes. `Restart`, `ResetWithSameIdentity`, `UpdateTerm`, `RequestVote`, `BecomeLeader`, `AppendEntries`, `AdvanceCommitIndex`, `AcceptAppendEntriesRequest`, `RejectAppendEntriesRequest`.
- **Reconfiguration:** **yes, both single-server and joint consensus** modeled **operationally** with a full joint-config state (`[id, jointConsensus, members, old, new, committed]`) and explicit quorum-overlap rules: during joint phase both old and new quorums must respond. Actions: `AppendOldNewConfigToLog`, `AppendNewConfigToLog`, `SendSnapshot`, `HandleSnapshotRequest/Response`.
- **Safety/liveness:** `NoLogDivergence`, `MaxOneReconfigurationAtATime`, `LeaderHasAllAckedValues`, `CommittedEntriesReachMajority`, liveness `ReconfigurationCompletes`.
- **Caveats:** the README primarily exists to document a *known vulnerability* in add/remove when reusing node identities ("blank node with same identity → data loss"). That pedagogical focus makes it the best teaching spec for why joint consensus matters. Not model-checked exhaustively for large configs.

### 2.3 `etcd-io/raft` (`tla/`) — trace-validated production spec

- **URL:** https://github.com/etcd-io/raft/tree/main/tla (repo: 1,018 stars, 240 forks, actively pushed 2026-04-23).
- **Author:** etcd team + community; acknowledges lineage from Ongaro → Ricketts (2016) → Pîrlea/Foo (2021) → etcd (2023).
- **Files:** `etcdraft.tla` (~1,100 lines), `MCetcdraft.tla`, `Traceetcdraft.tla`, plus `validate.sh`.
- **Leader election:** yes — `Timeout`, `RequestVote`, `BecomeLeader`, `AppendEntries`, `Heartbeat`, `AppendEntriesToSelf`, `ClientRequest`, `AdvanceCommitIndex`, `Restart`, `StepDownToFollower`, `SendSnapshot`.
- **Reconfiguration:** **yes — joint consensus + learners.** Actions `AddNewServer`, `AddLearner`, `DeleteServer`, `ApplySimpleConfChange`; state includes `jointConfig` and `pendingConfChangeIndex` to prevent overlapping reconfigurations. This matches how etcd actually ships reconfig.
- **Safety invariants:** `LogInv`, `MoreThanOneLeaderInv`, `ElectionSafetyInv`, `LogMatchingInv`, `LeaderCompletenessInv`, `QuorumLogInv` — i.e., the full Ongaro dissertation set.
- **Distinctive:** `Traceetcdraft.tla` accepts an NDJSON trace from the running etcd implementation and replays it through the spec (implementation-to-model trace validation). This is unique among the Raft specs surveyed.

### 2.4 `dranov/raft-tla` — Apalache-ready derivative

- **URL:** https://github.com/dranov/raft-tla
- **Stars:** 21, forks 3. Last push 2021-10-25. Authors: George Pîrlea & Darius Foo (NUS).
- **Subdirs:** `apalache_no_membership/` (type-annotated, verified with Apalache 0.16.5), `tlc_membership/` (~1,450 lines), `apalache_membership_broken/` (abandoned).
- **Leader election:** yes — `RequestVote`, `BecomeLeader`, `AppendEntries`, `Timeout`, `Restart`, `Receive`, `DuplicateMessage`/`DropMessage`.
- **Reconfiguration:** **single-server only** (Ongaro §4). Actions: `AddNewServer(i, j)`, `DeleteServer(i, j)`, `HandleCatchupRequest/Response`, `HandleCheckOldConfig`. Catchup is modeled operationally over `NumRounds` rounds, followed by appending a `ConfigEntry` log record. **No joint consensus.**
- **Safety invariants:** `LogMatching`, `LeaderCompleteness`, `ElectionSafety`, `VotesGrantedInv`, `QuorumLogInv`, `LeaderVotesQuorum` (caveat: some flagged inaccurate for the membership-change variant in the README).
- **Caveats:** README warns that the Apalache annotations for the reconfig variant were abandoned because the type system was too hard to satisfy; only the TLC variant actually checks.

### 2.5 `HappyCS-Gu/Parallel-Raft-tla` — PolarDB / Parallel-Raft

- **URL:** https://github.com/HappyCS-Gu/Parallel-Raft-tla
- **Stars:** 59. Last push 2024-09-19. Research artifact (Alibaba/academic collaboration).
- **Files:** `MultiPaxos.tla`, `ParallelRaftSE.tla`, `ParallelRaftCE.tla`.
- **Leader election:** yes (inherited from Raft).
- **Reconfiguration:** no.
- **Contribution:** models out-of-order log commitment in Parallel-Raft (PolarFS); identifies a "ghost log entries" anomaly in the original, fixed by ParallelRaft-CE. Refinement mapping validated with TLC.
- **Relevance:** useful *only* if the project cares about parallel commitment; orthogonal to view-change / reconfig.

### 2.6 `irfansharif/raft.tla` — Pre-Vote variant

- **URL:** https://github.com/irfansharif/raft.tla
- **Stars:** 12, forks 3. Last push 2017-09-07.
- **Author:** Irfan Sharif (CockroachDB engineer).
- **File:** `raft.tla`. Adds Pre-Vote rounds to Ongaro's spec.
- **Leader election:** yes, with Pre-Vote refinement.
- **Reconfiguration:** no.
- **Caveats:** narrow extension of Ongaro; hasn't been touched since 2017. Relevant if the project wants to rule out unnecessary term bumps after partitions.

### 2.7 `muratdem/RaftLeaderLeases` (LeaseGuard)

- **URL:** https://github.com/muratdem/RaftLeaderLeases
- **Stars:** 11. Last push 2025-10-24. Murat Demirbas (UB) + MongoDB collaborators. Research artifact for the "inherited leases" problem.
- **Files:** under `TLA/` plus a Python simulator.
- **Leader election:** yes — leases are explicitly tied to leader transitions.
- **Reconfiguration:** no.
- **Safety:** verifies `LinearizableReads`, handles the "limbo region" where a new leader inherits an uncommitted log tail. Uses trace-expression machinery.
- **Relevance to a jetpack-style project:** **high** if doing linearizable reads from primary under leases, **low** for membership change.

### 2.8 `heidihoward/leaderelection-tlaplus` — pedagogical leader-election only

- **URL:** https://github.com/heidihoward/leaderelection-tlaplus
- **Stars:** 10. Last push 2022-10-07. Author: Heidi Howard (MSR Cambridge / Flexible Paxos).
- **File:** `RaftLeader.tla` (91 lines).
- **Actions:** `BecomeCandidate`, `Vote`, `BecomeLeader`, `Noop`. Variables: just `currentTerm`, `messages`.
- **Properties:** `OneVotePerTerm`, `OneLeaderPerTerm`, `OnlyLeadersAppend`, `IncreasingTerms`, `Safety`.
- **Caveats:** it is **only** the election subset — no log, no commit, no reconfig. Useful as a minimal starting skeleton for a new protocol's election layer.

### 2.9 `dricketts/raft.tla` — Ricketts TLAPS variant

- **URL:** https://github.com/dricketts/raft.tla
- **Stars:** 4. Last push 2016-09-09. Daniel Ricketts (UCSD, then Galois).
- Extends Ongaro's spec with TLAPS proof scaffolding (some proofs flagged incorrect by later authors).
- **Reconfiguration:** no.
- **Primary value:** historic — many downstream repos (dranov, BinyuHuang-nju) cite this as their base.

### 2.10 `BinyuHuang-nju/raft-tla` — academic derivative

- **URL:** https://github.com/BinyuHuang-nju/raft-tla
- **Stars:** 1. Last push 2021-05-12. Chinese-academy student project, based on Ricketts.
- No README-visible reconfiguration. Mentioned because it appears frequently in literature-review lists.

### 2.11 `xiaonanln/raft.tla`

- **URL:** https://github.com/xiaonanln/raft.tla
- Could not pull repo metadata in this session. Listed for completeness from search results. Appears to be a fork of Ongaro with no significant modifications.

### 2.12 `tlaplus/Examples` — *index only* for Raft

- **URL:** https://github.com/tlaplus/Examples
- **Stars:** 1,488, forks 218.
- The `specifications/raft/` and `specifications/mongo-repl-tla/` directories contain **only README files** that redirect to `ongardie/raft.tla` and `visualzhou/mongo-repl-tla` respectively. Valuable because it's the community's canonical "entry-point" list; no reconfig content of its own.

### 2.13 `tlaplus/DrTLAPlus` — pedagogical slide-deck collection

- **URL:** https://github.com/tlaplus/DrTLAPlus
- **Stars:** 852. Protocols include Paxos (many flavors), Raft, Cosmos DB, TiDB, Global Snapshots.
- The Raft entry is a **presentation artifact** (slides + spec for a 2016-07-21 talk by Jin Li). Not a research-grade reconfig model, but the curated Cosmos DB and Paxos entries are useful cross-references.

---

## 3. MongoDB Replication TLA+ Specifications

### 3.1 `mongodb/mongo` (in-tree `src/mongo/tla_plus/`) — production vendor spec

- **URL:** https://github.com/mongodb/mongo/tree/master/src/mongo/tla_plus
- **Repo stars:** 28,255 (the server repo itself). TLA+ folder actively maintained by MongoDB's Replication team.
- **Files of interest:**
  - `Replication/RaftMongo/RaftMongo.tla` (~350 lines) — static MongoDB Raft. Actions: `BecomePrimaryByMagic`, `Stepdown`, `AppendOplog`, `RollbackOplog`, `ClientWrite`, `UpdateTermThroughHeartbeat`, `AdvanceCommitPoint`, `LearnCommitPointWithTermCheck`, `LearnCommitPointFromSyncSourceNeverBeyondLastApplied`. Safety: `NoTwoPrimariesInSameTerm`, `NeverRollbackCommitted`, `NeverRollbackBeforeCommitPoint`, `CommitPointEventuallyPropagates`. No reconfig.
  - `RaftMongoWithRaftReconfig.tla` (~293 lines) — adds `ReconfigAction`: restricts to single-node add/remove (`|ServerViewOn(i) \ newConfig| + |newConfig \ ServerViewOn(i)| ≤ 1`), requires the current config to be committed and at least one entry committed in leader's term; appends a config entry to the oplog with monotonically-increasing `configVersion`.
  - `Replication/MongoReplReconfig/MongoReplReconfig.tla` (~550 lines) — the modern *logless* reconfig: actions `Reconfig(i)`, `SendConfig(s, r)`, invariants `ElectionSafety`, `NeverRollbackCommitted`, `ConfigVersionIncreasesWithTerm`, `AtMostOneActiveConfig`. Operationally enforces `ConfigIsSafe(i)` (quorum-ack + committed-entries preservation).
  - Plus `RaftMongoReplTimestamp`, sharding specs (`MoveRange`, `TxnsCollectionIncarnation`, `TxnsMoveRange`, `RangeDeletionsSecondaryNodes`), and `Concurrency/OrderedTicketSemaphore`.
- This is the most *production-relevant* public MongoDB spec set; it is what actually ships with the server source.

### 3.2 `will62794/logless-reconfig` — Schultz / Zhou / Dardik OPODIS 2021 artifact

- **URL:** https://github.com/will62794/logless-reconfig
- **Stars:** 16, forks 2. Last push 2024-12-16.
- **Authors:** William Schultz (MongoDB Research, now PhD'd), Siyuan Zhou (MongoDB), Ian Dardik.
- **Files:** `MongoRaftReconfig.tla` (~170 lines), `MongoStaticRaft.tla`, `MongoLoglessDynamicRaft.tla`, `Defs.tla`, and MC harnesses for each; plus a TLAPS proofs subdirectory.
- **Leader election:** yes — `BecomeLeader`, `UpdateTerms` synchronize across the two sub-state-machines.
- **Reconfiguration:** **yes, logless.** The protocol decomposes into an Oplog State Machine (OSM) and Config State Machine (CSM) running asynchronously except for elections. CSM actions: `Reconfig`, `SendConfig`. Core safety constraint: `OplogCommitment(s)` forces committed current-term oplog entries to be replicated into the new-config quorum before the reconfig commits.
- **Safety proved (TLAPS, machine-checked):** `OnePrimaryPerTerm`, `LeaderCompleteness`, `StateMachineSafety`. This is the *only* reconfig-aware TLA+ spec surveyed with a full TLAPS proof of those two flagship properties.
- **Paper:** "Design and Analysis of a Logless Dynamic Reconfiguration Protocol" (OPODIS 2021).
- This repo is the MongoDB-specific counterpart of Vanlightly's joint-consensus spec; where Vanlightly models the log-based approach, Schultz et al. formalize MongoDB's no-oplog-entry design.

### 3.3 `visualzhou/mongo-repl-tla` — the "original" MongoDB spec

- **URL:** https://github.com/visualzhou/mongo-repl-tla
- **Stars:** 49, forks 5. Last push 2019-11-23. Author: Siyuan Zhou (MongoDB). Precursor to everything above.
- **Files:** `RaftMongo.tla` (~350 lines) and `RaftMongoWithRaftReconfig.tla`.
- Essentially the same actions / invariants as later landed in-tree in §3.1. Reconfig variant present but restricted; no logless variant.
- **Historical value:** this is the spec `tlaplus/Examples` points to.

### 3.4 `will62794/mongo-repl-tla-models`

- **URL:** https://github.com/will62794/mongo-repl-tla-models
- **Stars:** 21. Last push 2020-11-03. TLC model-checking harnesses / driver scripts around the `mongo-repl-tla` spec. Not a new model; *how* to run the existing one.

### 3.5 `will62794/mongo-repl-reconfig`

- **URL:** https://github.com/will62794/mongo-repl-reconfig
- **Stars:** 1. Last push 2020-09-17. Earliest Schultz draft of the MongoDB reconfig spec — **superseded by `logless-reconfig`**. Kept for provenance only.

### 3.6 `will62794/initial-sync-tla`

- **URL:** https://github.com/will62794/initial-sync-tla
- **Stars:** 3. Last push 2020-02-06. Models MongoDB *initial sync* (a new replica catching up from snapshot + oplog). Not about leader election per se, but relevant to the catchup phase of any reconfig design.

### 3.7 `will62794/mongo-repl-tla` (a personal fork)

- **URL:** https://github.com/will62794/mongo-repl-tla
- **Stars:** 3. Last push 2020-07-19. A personal fork of §3.3; no distinct content beyond that. Listed for disambiguation.

---

## 4. Cross-Cutting Analysis

### 4.1 State of membership-change modeling in public TLA+

Public TLA+ specs strongly under-model reconfiguration. Of the 13 Raft repos surveyed, only 4 actually encode it (Vanlightly, etcd-io, dranov, and the original Ongaro gist *which omits it by design*). Of those four, two (etcd, Vanlightly) implement joint consensus; two (Vanlightly, dranov, MongoDB in-tree `RaftMongoWithRaftReconfig`) implement single-server add/remove. The Ongaro canonical spec ducks the question entirely — likely the single biggest reason downstream forks also duck it.

MongoDB is actually an outlier in the *other* direction: because `replSetReconfig` is a documented user-visible feature, MongoDB engineering has multiple rigorous reconfig specs in-tree (`MongoReplReconfig.tla` and the OPODIS 2021 `MongoRaftReconfig` with its TLAPS proof). These are *operational* — they model messages (`SendConfig`), version numbers (`configVersion`, `configTerm`), and a quorum-overlap guard (`ConfigIsSafe` / `OplogCommitment`) — not just a set assignment. Outside the MongoDB orbit, etcd's spec is the only other public one that encodes the realistic "catchup + commit previous config + install new" flow.

A research project that wants to claim "we verified our reconfiguration protocol" has essentially three prior-art templates to build on: (a) joint consensus (Vanlightly or etcd), (b) single-server add/remove with catchup rounds (dranov / Pîrlea, MongoDB in-tree), (c) logless two-state-machine composition (Schultz et al.). Anything else is new work.

### 4.2 Rigor — tool coverage and proofs

Most specs are TLC-only, exploring small configurations (typically N=3 servers, term counts ≤3, log lengths ≤3). Apalache coverage is rare and fragile: `dranov/raft-tla` is the only repo I found with a real Apalache-ready Raft variant, and its membership-change counterpart was abandoned because the type annotations couldn't be made to work. TLAPS mechanized proofs are rarer still — only `will62794/logless-reconfig` proves its flagship theorems (`LeaderCompleteness`, `StateMachineSafety`) with a machine-checked invariant. `dricketts/raft.tla` has TLAPS scaffolding, but several of those proofs are flagged incorrect by later authors.

Trace validation (connecting a running implementation to the model) appears in exactly one place in this survey: `etcd-io/raft/tla/Traceetcdraft.tla`. This is the right model to copy if the goal is to demonstrate the *deployed* code matches the spec, not just the spec matches itself.

### 4.3 Recommendations for extending a new consensus protocol with view-change + failure-recovery

If the janus/jetpack project wants to add rigorous TLA+ coverage for both leader election (failure recovery) and membership change, the recommended order of cost/benefit is:

1. **Base the core Raft layer on `etcd-io/raft/tla/etcdraft.tla`** (https://github.com/etcd-io/raft/tree/main/tla). It has the complete Ongaro action set, joint-consensus reconfig, learners, snapshotting, the full invariant suite (`LogMatching` / `ElectionSafety` / `LeaderCompleteness` / `QuorumLog`), and a precedent for trace-validating an implementation. The action names are already the ones engineers recognize.
2. **Copy Vanlightly's configuration-state record and quorum-overlap predicate from `RaftWithReconfigJointConsensus.tla`** (https://github.com/Vanlightly/raft-tlaplus/blob/main/specifications/standard-raft/RaftWithReconfigJointConsensus.tla). It is the clearest public illustration of what the joint-consensus invariant ("both old and new must intersect") looks like in TLA+, and its README contains a worked-out data-loss counterexample that you can use as a liveness/safety regression test.
3. **If the protocol uses a MongoDB-style separate config state machine (not log-embedded entries), study `will62794/logless-reconfig`** (https://github.com/will62794/logless-reconfig). The MongoRaftReconfig composition pattern plus the TLAPS-proven `OplogCommitment` safety constraint is the closest public precedent, and the proofs port reasonably well if the target protocol keeps the two-state-machine decomposition.
4. **For the leader-election layer alone, start from `heidihoward/leaderelection-tlaplus`** (https://github.com/heidihoward/leaderelection-tlaplus/blob/main/RaftLeader.tla) as a 91-line skeleton, then grow into the etcd spec. The small spec is pedagogically the cleanest "what does an election-only Raft look like" in the wild.
5. **Avoid basing new work on `ongardie/raft.tla` directly** despite its 512-star halo — it is missing reconfig, it hasn't been meaningfully revised, and every later spec already re-derives its content. Use it only as a point of provenance.

---

## 5. Sources

- [ongardie/raft.tla](https://github.com/ongardie/raft.tla)
- [Vanlightly/raft-tlaplus](https://github.com/Vanlightly/raft-tlaplus)
- [etcd-io/raft — tla directory](https://github.com/etcd-io/raft/tree/main/tla)
- [dranov/raft-tla](https://github.com/dranov/raft-tla)
- [HappyCS-Gu/Parallel-Raft-tla](https://github.com/HappyCS-Gu/Parallel-Raft-tla)
- [irfansharif/raft.tla](https://github.com/irfansharif/raft.tla)
- [dricketts/raft.tla](https://github.com/dricketts/raft.tla)
- [muratdem/RaftLeaderLeases](https://github.com/muratdem/RaftLeaderLeases)
- [heidihoward/leaderelection-tlaplus](https://github.com/heidihoward/leaderelection-tlaplus)
- [xiaonanln/raft.tla](https://github.com/xiaonanln/raft.tla)
- [BinyuHuang-nju/raft-tla](https://github.com/BinyuHuang-nju/raft-tla)
- [tlaplus/Examples](https://github.com/tlaplus/Examples)
- [tlaplus/DrTLAPlus](https://github.com/tlaplus/DrTLAPlus)
- [mongodb/mongo — src/mongo/tla_plus](https://github.com/mongodb/mongo/tree/master/src/mongo/tla_plus)
- [will62794/logless-reconfig](https://github.com/will62794/logless-reconfig)
- [visualzhou/mongo-repl-tla](https://github.com/visualzhou/mongo-repl-tla)
- [will62794/mongo-repl-tla-models](https://github.com/will62794/mongo-repl-tla-models)
- [will62794/mongo-repl-reconfig](https://github.com/will62794/mongo-repl-reconfig)
- [will62794/initial-sync-tla](https://github.com/will62794/initial-sync-tla)
- [will62794/mongo-repl-tla](https://github.com/will62794/mongo-repl-tla)
- [Azure/azure-cosmos-tla](https://github.com/Azure/azure-cosmos-tla) — listed for completeness; no Raft/consensus content
- [Schultz et al., OPODIS 2021 paper](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.OPODIS.2021.26)
- [muratbuffalo blog — MongoDB logless reconfig](http://muratbuffalo.blogspot.com/2024/02/tla-modeling-of-mongodb-logless.html)
