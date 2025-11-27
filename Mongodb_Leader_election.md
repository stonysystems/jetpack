Leader_election in MongoDb

# MongoDB Replication Failure Recovery and Leader Election

## Overview

MongoDB's replication system uses a leader election mechanism very similar to the Raft consensus algorithm. The system ensures high availability through automatic failover when the primary node becomes unavailable. This document provides a comprehensive analysis of how MongoDB detects failures and elects a new leader (primary).

## Protocol Version

The code uses **Protocol Version 1 (PV1)**, indicated by the `_v1` suffix in filenames like `replication_coordinator_impl_elect_v1.cpp`.

**Important:** PV1 is the **current and only supported** election protocol in modern MongoDB. Protocol Version 0 (PV0) existed in older versions but is **no longer supported** (as stated in `mongo/src/mongo/db/repl/repl_set_config.idl:188`).

## Architecture Components

### Core Components

| Component | File Location | Purpose |
|-----------|--------------|---------|
| **ReplicationCoordinatorImpl** | `mongo/src/mongo/db/repl/replication_coordinator_impl.{h,cpp}` | Main orchestrator managing the entire replication state machine |
| **TopologyCoordinator** | `mongo/src/mongo/db/repl/topology_coordinator.{h,cpp}` | Maintains cluster topology and manages election state transitions |
| **ElectionState** | `mongo/src/mongo/db/repl/replication_coordinator_impl.h:910-1019` | Inner class managing the voting process for a single election |
| **VoteRequester** | `mongo/src/mongo/db/repl/vote_requester.h` | Implements scatter-gather pattern for collecting votes from replica set members |

### Member States

MongoDB nodes transition through these states during elections:
- **FOLLOWER** (Secondary) - Normal state, replicating from primary
- **CANDIDATE** - Actively campaigning for election
- **PRIMARY** - Elected leader, accepts writes

## Failure Detection

### Heartbeat Mechanism

**Location:** `mongo/src/mongo/db/repl/topology_coordinator.cpp:1350-1367`

MongoDB uses periodic heartbeats to detect node failures:

1. **Heartbeat Interval:** Nodes send heartbeats to each other at regular intervals
2. **Timeout Detection:** `checkMemberTimeouts()` periodically checks if members haven't sent heartbeats within the election timeout
3. **Member Status:** Nodes that miss heartbeats are marked as DOWN
4. **Primary Step-Down:** If the primary loses visibility to a majority of nodes, it automatically steps down

**Heartbeat Processing:**
- Location: `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:234`
- Function: `_handleHeartbeatResponse()`
- Each heartbeat response updates the topology coordinator's view of the cluster

## Election Triggers

MongoDB initiates leader elections in several scenarios:

### 1. Election Timeout (Primary Trigger)

**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl.cpp:463-467`

**Function:** `_handleElectionTimeoutCallback()`

**When:** No heartbeat received from primary within the election timeout period

**Action:** Calls `_startElectSelfIfEligibleV1(StartElectionReasonEnum::kElectionTimeout)`

### 2. Priority Takeover

**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:519`

**When:** A higher-priority node detects a lower-priority primary

**Purpose:** Ensures the most preferred node (by priority) becomes primary

### 3. Catchup Takeover

**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:534`

**When:** A node that is more caught up detects the primary is in catchup mode

**Purpose:** Minimizes write unavailability during primary catchup

### 4. Manual Step-Up

**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_step_up_step_down.cpp:361-362`

**When:** Administrator issues `replSetStepUp` command

**Purpose:** Manual control over primary selection

## Initial Primary Selection (Replica Set Bootstrap)

While failover elections are unpredictable (based on random timeouts and network conditions), you **can influence** which node becomes the initial primary when first starting a replica set.

### Replica Set Initialization

**Command:** `replSetInitiate`

**Implementation Locations:**
- Command handler: `mongo/src/mongo/db/repl/repl_set_commands.cpp:323-405` - `CmdReplSetInitiate`
- Core logic: `mongo/src/mongo/db/repl/replication_coordinator_impl.cpp:4181-4342` - `processReplSetInitiate()`

**Initialization Process:**

1. **Parse Configuration** (line 4240)
   - Validates member configurations
   - Checks priority, votes, and other member settings

2. **Validate Configuration** (line 4267)
   - Ensures configuration is valid
   - Checks for conflicts and invalid settings

3. **Quorum Check** (line 4282)
   - Special check only during initialization: `checkQuorumForInitiate()`
   - Verifies enough nodes are reachable before proceeding
   - Prevents initialization if majority unavailable

4. **Persist Configuration** (line 4290)
   - Writes replica set config to storage

5. **Install Configuration** (line 4326)
   - Calls `_finishReplSetInitiate()`
   - All nodes initially start as **SECONDARY**

6. **Trigger Election** (line 4353)
   - Calls `_performPostMemberStateUpdateAction()`
   - For single-node sets: automatic immediate election
   - For multi-node sets: wait for election timeout

### Single-Node Replica Sets

**Location:** `mongo/src/mongo/db/repl/topology_coordinator.cpp:2978-2983`

**Function:** `isElectableNodeInSingleNodeReplicaSet()`
```cpp
bool TopologyCoordinator::isElectableNodeInSingleNodeReplicaSet() const {
    auto isSingleNode = _rsConfig.getNumMembers() == 1 && _selfIndex == 0;
    invariant(!isSingleNode || _rsConfig.getMemberAt(_selfIndex).isElectable());
    return (getMemberState() == MemberState::RS_SECONDARY) && isSingleNode;
}
```

**Behavior:**
- Single-node sets are **automatically detected** during initialization
- Election is **immediately triggered** via `kActionStartSingleNodeElection`
- Node votes for itself and becomes PRIMARY instantly
- **No election timeout needed** - guaranteed to become primary

**Code Path:**
```
_finishReplSetInitiate() [line 4344]
  → _setCurrentRSConfig() [line 4688]
    → detects single-node set
    → returns PostMemberStateUpdateAction::kActionStartSingleNodeElection
  → _performPostMemberStateUpdateAction() [line 4516]
    → _startElectSelfIfEligibleV1(kElectionTimeout)
```

### Multi-Node Replica Sets

For multi-node sets, the initial primary selection follows these steps:

**1. All Nodes Start as SECONDARY**
- After `replSetInitiate`, no node is primary initially
- All nodes enter SECONDARY state

**2. Election Timeout Triggers First Election**
- Location: `mongo/src/mongo/db/repl/replication_coordinator_impl.cpp:463-467`
- Each node has a **randomized election timeout** (~10 seconds by default)
- First node whose timeout expires calls `_startElectSelfIfEligibleV1()`

**3. Priority Influences Election**
- Nodes check eligibility: `_getMyUnelectableReason()` at `topology_coordinator.cpp:2597-2637`
- **Line 2615: Priority Check**
  ```cpp
  if (_memberConfig.getPriority() == 0) {
      return UnelectableReasonEnum::NoPriority;
  }
  ```
- **Priority 0 nodes cannot become primary**
- Higher priority nodes are preferred (via priority takeover mechanism)

### Priority Configuration

**Location:** `mongo/src/mongo/db/repl/member_config.idl`

**Configuration Example:**
```javascript
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "node1:27017", priority: 2 },   // Highest - preferred primary
    { _id: 1, host: "node2:27017", priority: 1 },   // Normal priority
    { _id: 2, host: "node3:27017", priority: 0.5 }, // Lower priority
    { _id: 3, host: "node4:27017", priority: 0 }    // Cannot become primary
  ]
})
```

**Priority Rules:**

| Priority Value | Behavior |
|---------------|----------|
| `0` | **Cannot become primary** - Permanently ineligible for election |
| `0.1 - 0.9` | Lower priority - less preferred as primary |
| `1.0` (default) | Normal priority |
| `> 1.0` | Higher priority - preferred as primary (will trigger takeover) |

### Priority Takeover Elections

**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:519`

Even if a lower-priority node wins the initial election, MongoDB automatically corrects this:

**Mechanism:**
1. Higher-priority nodes detect a lower-priority primary via heartbeats
2. Higher-priority node triggers a **priority takeover election**
3. Calls: `_startElectSelfIfEligibleV1(StartElectionReasonEnum::kPriorityTakeover)`
4. This happens automatically within ~5 seconds of replica set startup

**Why This Matters:**
- Ensures the **preferred node** (highest priority) becomes primary
- Happens automatically even if a different node won the initial election
- No manual intervention needed

### Practical Strategies to Control Initial Primary

#### Strategy 1: Use High Priority on Desired Node

**Most Common Approach:**

```javascript
// Initiate from any node
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "node1:27017", priority: 10 },  // Will become primary
    { _id: 1, host: "node2:27017", priority: 1 },
    { _id: 2, host: "node3:27017", priority: 1 }
  ]
})
```

**Result:**
- Even if node2 or node3 wins initial election first
- Node1 will trigger priority takeover within seconds
- Node1 becomes primary (guaranteed via priority takeover)

#### Strategy 2: Set Others to Priority 0 Initially

**Most Controlled Approach:**

```javascript
// Step 1: Initialize with only one eligible node
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "node1:27017", priority: 1 },   // Only eligible node
    { _id: 1, host: "node2:27017", priority: 0 },   // Cannot become primary
    { _id: 2, host: "node3:27017", priority: 0 }    // Cannot become primary
  ]
})

// Step 2: After node1 is primary, reconfigure to allow others
var conf = rs.conf()
conf.members[1].priority = 1
conf.members[2].priority = 1
conf.version++
rs.reconfig(conf)
```

**Result:**
- Node1 is the **only eligible candidate** initially
- Node1 guaranteed to become first primary
- Later reconfiguration allows failover to other nodes

#### Strategy 3: Single-Node Initialization

**Guaranteed Approach:**

```javascript
// Step 1: Initialize as single-node replica set
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "node1:27017" }
  ]
})

// Wait for node1 to become PRIMARY (happens immediately)

// Step 2: Add additional members
rs.add({ host: "node2:27017", priority: 1 })
rs.add({ host: "node3:27017", priority: 1 })
```

**Result:**
- Node1 **guaranteed** to become first primary (single-node auto-election)
- Other nodes added after node1 is already primary
- Most deterministic approach

#### Strategy 4: Initiate from Desired Primary

**Simple Approach:**

```bash
# Connect to the specific node you want as primary
mongosh --host node1:27017

# Run initiate from THIS node
rs.initiate({
  _id: "myReplicaSet",
  members: [
    { _id: 0, host: "node1:27017", priority: 2 },
    { _id: 1, host: "node2:27017", priority: 1 },
    { _id: 2, host: "node3:27017", priority: 1 }
  ]
})
```

**Result:**
- Node where `replSetInitiate` is called has slight advantage
- Combined with higher priority, very likely to become first primary
- Not 100% guaranteed but highly probable

### Initial Election vs Failover Election

| Aspect | Initial Election | Failover Election |
|--------|-----------------|-------------------|
| **Trigger** | Replica set initialization | Primary failure/timeout |
| **Node State** | All nodes are SECONDARY | One PRIMARY (failed), others SECONDARY |
| **Predictability** | **Can be controlled** via priority | **Unpredictable** - depends on timeouts |
| **Priority Role** | Determines eligibility + triggers takeover | Triggers priority takeover only |
| **Special Handling** | Single-node sets auto-elect immediately | Standard election protocol |
| **Quorum Check** | `checkQuorumForInitiate()` during setup | Standard majority quorum |

### Code Locations for Initialization

| Function | Location | Purpose |
|----------|----------|---------|
| `CmdReplSetInitiate::run()` | `repl_set_commands.cpp:323-405` | Command handler |
| `processReplSetInitiate()` | `replication_coordinator_impl.cpp:4181-4342` | Main initialization logic |
| `checkQuorumForInitiate()` | `replication_coordinator_impl.cpp:4280` | Verify nodes reachable |
| `_finishReplSetInitiate()` | `replication_coordinator_impl.cpp:4344-4354` | Complete initialization |
| `isElectableNodeInSingleNodeReplicaSet()` | `topology_coordinator.cpp:2978-2983` | Detect single-node set |
| `_getMyUnelectableReason()` | `topology_coordinator.cpp:2597-2637` | Check election eligibility |
| Priority takeover trigger | `replication_coordinator_impl_heartbeat.cpp:519` | Takeover election start |

### Best Practices for Initial Primary Selection

1. **Use Priority Settings**
   - Set priority ≥ 2 on desired primary
   - Ensures priority takeover even if another node wins first

2. **Use Priority 0 for Backups**
   - Nodes that should never be primary: `priority: 0`
   - Common for disaster recovery nodes in remote datacenters

3. **Single-Node Bootstrap for Critical Deployments**
   - Initialize as single node
   - Add members after first primary is established
   - Most deterministic approach

4. **Avoid Equal Priorities for Preferred Primary**
   - If all nodes have priority 1.0, initial primary is random
   - Set preferred node to higher priority for predictability

5. **Consider Geographic Priority**
   - Higher priority for nodes in primary datacenter
   - Lower priority for nodes in secondary datacenter
   - Ensures primary is in preferred location

## Election Process Flow

### Phase 1: Election Initiation

**Function:** `_startElectSelfIfEligibleV1()`
**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:1291-1379`

**Steps:**

1. **Eligibility Check** (line 1313)
   - Calls: `_topCoord->becomeCandidateIfElectable()`
   - Location: `mongo/src/mongo/db/repl/topology_coordinator.cpp:3703-3724`

   **Verifies:**
   - Node is not already primary or candidate
   - Node is not an arbiter
   - Node has non-zero priority
   - Node can see a majority of the replica set
   - Other unelectable conditions don't apply

2. **State Transition**
   - Changes role from `FOLLOWER` → `CANDIDATE`
   - Increments election attempt counter

3. **Election State Creation**
   - Creates `ElectionState` object to manage this election
   - Tracks voting progress and responses

### Phase 2: Dry Run Election (Optional)

**Function:** `ElectionState::start()`
**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:177-252`

**Purpose:** Test if an election would succeed without actually updating the term

**Process:**

1. **Start Vote Requester** (lines 235-240)
   - Creates `VoteRequester` with `dryRun = true`
   - Sends vote requests to all replica set members
   - Does NOT increment term number

2. **Dry Run Completion** (lines 254-290)
   - **Success:** Proceeds to real election via `_startRealElection()`
   - **Failure:** Aborts election (lines 270-282), stays as follower

**Why Dry Run?**
- Reduces unnecessary term increments
- Prevents election storms
- Only candidates likely to win proceed to real elections

### Phase 3: Real Election

**Function:** `_startRealElection()`
**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:294-350`

**Critical Steps:**

1. **Term Increment** (line 329)
   ```cpp
   long long newTerm = originalTerm + 1;
   ```
   - Monotonically increasing term prevents split-brain scenarios
   - Similar to Raft's term concept

2. **Self-Vote** (line 336)
   ```cpp
   _topCoord->voteForMyselfV1()
   ```
   - Records vote for self in topology coordinator
   - Increments vote count to 1

3. **Persist Vote** (lines 338-349)
   - Schedules asynchronous write of `LastVote` to storage
   - Ensures vote survives crashes (durability)
   - Only after vote is persisted does vote collection begin

4. **Vote Request Phase** (line 404)
   - Calls `_requestVotesForRealElection()` after vote persistence completes

### Phase 4: Vote Collection

**Function:** `_requestVotesForRealElection()`
**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:410-432`

**Process:**

1. **Create Vote Requester** (lines 415-416)
   ```cpp
   _voteRequester.reset(new VoteRequester);
   _voteRequester->start(...);
   ```
   - Provides current term
   - Provides last written OpTime (log position)
   - Provides last applied OpTime

2. **Scatter-Gather Pattern**
   - `VoteRequester` sends parallel `replSetRequestVotes` RPC to all members
   - Collects responses asynchronously
   - Tracks votes and responses

3. **Completion Callback**
   - When sufficient responses received, calls `_onVoteRequestComplete()`

### Phase 5: Vote Decision Logic

**Function:** `processReplSetRequestVotes()`
**Location:** `mongo/src/mongo/db/repl/topology_coordinator.cpp:3603-3688`

**A node grants its vote if ALL conditions are satisfied:**

#### Condition 1: Config Version Match (line 3631)
```cpp
if (args.getConfigVersion() != _rsConfig.getConfigVersion())
    return {ErrorCodes::ConfigVersionMismatch, ...};
```
- Ensures candidate and voter have same replica set configuration

#### Condition 2: Term Check (line 3636)
```cpp
if (args.getTerm() < _term)
    return {ErrorCodes::StaleTerm, ...};
```
- Candidate's term must be ≥ voter's current term
- Prevents voting for stale candidates

#### Condition 3: Set Name Match (line 3640)
```cpp
if (args.getSetName() != _rsConfig.getReplSetName())
    return {ErrorCodes::InconsistentReplicaSetNames, ...};
```
- Safety check ensuring same replica set

#### Condition 4: Data Freshness Check (line 3645)
```cpp
if (args.getLastWrittenOpTime() < lastWrittenOpTime ||
    args.getLastAppliedOpTime() < lastAppliedOpTime)
    return {ErrorCodes::NotSecondary, "candidate's data is stale"};
```
- **Critical for consistency:** Ensures candidate has at least as much data as voter
- Similar to Raft's log completeness check
- Prevents data loss by ensuring new primary has all committed operations

#### Condition 5: Vote Uniqueness (line 3652)
```cpp
if (_lastVote.getTerm() == args.getTerm() &&
    _lastVote.getCandidateIndex() != candidateIndex)
    return {ErrorCodes::AlreadyVoted, ...};
```
- Ensures each node votes at most once per term
- Prevents multiple primaries in same term

#### Condition 6: Primary Visibility Check (lines 3660-3671)
```cpp
if (iAmArbiter && _currentPrimaryIndex != -1) {
    // Arbiter sees a primary, reject vote
    return {ErrorCodes::NodeIsNotSecondary, ...};
}
```
- Arbiters reject votes if they can still see the current primary
- Prevents unnecessary elections

**Vote Response:**
```cpp
return LastVote{args.getTerm(), candidateIndex};
```

### Phase 6: Election Completion

**Function:** `_onVoteRequestComplete()`
**Location:** `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:434-494`

**Possible Outcomes:**

#### Success Path (lines 461-464)
```cpp
case VoteRequester::Result::kSuccessfullyElected:
```

**Actions:**
1. **Mark Responders Alive** (line 477)
   - Updates topology view with responding nodes

2. **Transition to Primary**
   - Calls `_postWonElectionUpdateMemberState()`
   - Updates member state from CANDIDATE → PRIMARY
   - Begins accepting write operations

3. **Cleanup**
   - Clears election state
   - Cancels election timeout

#### Failure Path (lines 452-460)

**Reasons:**
- `kInsufficientVotes` - Did not receive majority
- `kStaleTerm` - Another node had higher term
- `kCancelled` - Election cancelled by external event

**Actions:**
1. **Process Loss** (line 453)
   ```cpp
   _topCoord->processLoseElection()
   ```
   - Reverts to FOLLOWER state
   - Updates term if learned about higher term

2. **Cleanup**
   - Clears election state
   - Schedules new election timeout

## Comparison with Raft

### Similarities

| Feature | MongoDB | Raft |
|---------|---------|------|
| **Terms** | Monotonically increasing term numbers | Same |
| **Voting** | Majority voting requirement | Same |
| **Log Completeness** | Candidate's OpTime ≥ voter's OpTime | Candidate's log ≥ voter's log |
| **Vote Uniqueness** | One vote per term | Same |
| **Heartbeats** | Regular heartbeats from primary | Same |
| **Leader Step-Down** | Primary steps down if can't reach majority | Same |
| **Election Timeout** | Randomized timeout triggers elections | Same |

### MongoDB-Specific Features

1. **Dry Run Elections**
   - Tests election viability before incrementing term
   - Reduces term inflation and election storms
   - Not present in standard Raft

2. **Priority-Based Elections**
   - Nodes have configurable priorities
   - Higher priority nodes can trigger takeover elections
   - Enables preferred primary selection

3. **Arbiter Nodes**
   - Non-data-bearing voting members
   - Participate in elections but don't hold data
   - Useful for tie-breaking in even-numbered replica sets

4. **Catchup Mode**
   - New primary catches up to latest write before accepting new writes
   - Prevents unnecessary rollbacks
   - Can be interrupted by catchup takeover

## Election Safety Guarantees

MongoDB's election protocol provides several critical safety guarantees:

### 1. Election Safety
**Guarantee:** At most one primary can be elected in a given term

**Mechanism:**
- Each node votes at most once per term
- Primary requires majority votes
- Majority overlap prevents split primaries

### 2. Leader Completeness
**Guarantee:** New primary has all committed operations

**Mechanism:**
- Vote granted only if candidate's OpTime ≥ voter's OpTime
- Candidate must get votes from majority
- At least one majority member has all committed ops
- Therefore, candidate must have all committed ops

### 3. Log Matching
**Guarantee:** If two nodes have the same OpTime, they have identical histories up to that point

**Mechanism:**
- OpTime includes term number and timestamp
- Operations are totally ordered by OpTime
- Identical OpTimes guarantee identical histories

## Key Code Locations Reference

### Election Initiation
- `mongo/src/mongo/db/repl/replication_coordinator_impl.cpp:463-467` - Election timeout handler
- `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:1291-1379` - Start election if eligible

### Election Execution
- `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:177-252` - Dry run election
- `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:294-350` - Real election start
- `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:410-432` - Vote request
- `mongo/src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp:434-494` - Election completion

### Election Decision
- `mongo/src/mongo/db/repl/topology_coordinator.cpp:3703-3724` - Become candidate if electable
- `mongo/src/mongo/db/repl/topology_coordinator.cpp:3603-3688` - Process vote request

### Failure Detection
- `mongo/src/mongo/db/repl/topology_coordinator.cpp:1350-1367` - Check member timeouts
- `mongo/src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp:234` - Handle heartbeat response

### Supporting Components
- `mongo/src/mongo/db/repl/vote_requester.h` - Vote collection scatter-gather
- `mongo/src/mongo/db/repl/heartbeat_response_action.h` - Heartbeat action decisions

## Typical Election Scenarios

### Scenario 1: Initial Replica Set Bootstrap

```
Time 0: Replica Set Initialization
  Admin connects to node1
  Runs: rs.initiate({
    _id: "rs0",
    members: [
      { _id: 0, host: "node1:27017", priority: 2 },
      { _id: 1, host: "node2:27017", priority: 1 },
      { _id: 2, host: "node3:27017", priority: 1 }
    ]
  })

Time 1: Configuration Validation
  ReplicationCoordinator parses config
  Validates member settings
  Runs checkQuorumForInitiate() - verifies nodes reachable
  All nodes: STARTUP → STARTUP2 → SECONDARY

Time 2: Election Timeout Period
  All nodes are SECONDARY (no primary yet)
  Each node has randomized election timeout (8-12 seconds)
  Node2's timeout expires first (random chance)

Time 3: Node2 Starts Election
  Node2 calls: _handleElectionTimeoutCallback()
  Node2 checks: becomeCandidateIfElectable()
  Node2 transitions: SECONDARY → CANDIDATE (term 1)

Time 4: Node2 Dry Run Election
  Node2 sends replSetRequestVotes (dryRun=true, term=1)
  Node1 responds: VOTE GRANTED
  Node3 responds: VOTE GRANTED
  Dry run succeeds (3/3 votes)

Time 5: Node2 Real Election
  Node2 increments term to 1
  Node2 votes for self
  Node2 persists LastVote{term:1, candidate:node2}
  Node2 sends replSetRequestVotes (term=1)
  Receives majority votes
  Node2 becomes: CANDIDATE → PRIMARY (term 1)

Time 6: Priority Takeover Triggered
  Node1 receives heartbeat from node2 (primary)
  Node1 detects: self.priority (2) > primary.priority (1)
  Node1 waits ~5 seconds for primary catchup
  Node1 calls: _startElectSelfIfEligibleV1(kPriorityTakeover)

Time 7: Node1 Priority Takeover Election
  Node1 transitions: SECONDARY → CANDIDATE (term 2)
  Node1 runs dry run election - succeeds
  Node1 runs real election with term=2
  Node2 steps down (higher term detected)
  Node1 receives majority votes
  Node1 becomes: CANDIDATE → PRIMARY (term 2)

Time 8: Steady State (Final)
  Primary: Node1 (term 2, priority 2) ✓ Preferred primary
  Secondary: Node2 (term 2, priority 1)
  Secondary: Node3 (term 2, priority 1)
  Cluster stable, accepting writes
```

**Key Points:**
- Node2 won initial election (random timeout)
- Node1 automatically triggered priority takeover (higher priority)
- Final result: Highest priority node is primary
- Entire process takes ~15-20 seconds

### Scenario 2: Primary Node Fails

```
Time 0: Normal Operation
  Primary: Node A (term 5)
  Secondaries: Node B, Node C
  All nodes healthy, heartbeats flowing

Time 1: Primary Failure
  Node A crashes
  Nodes B and C stop receiving heartbeats from A

Time 2: Election Timeout
  Node B's election timeout expires first (randomized)
  Node B calls: _handleElectionTimeoutCallback()
  Node B checks eligibility: becomeCandidateIfElectable()
  Node B transitions: FOLLOWER → CANDIDATE

Time 3: Dry Run Election
  Node B starts dry run with term=5 (no increment)
  Node B sends replSetRequestVotes (dryRun=true) to all
  Node C responds: VOTE GRANTED (B's data is fresh)
  Node A: NO RESPONSE (down)
  Dry run succeeds (B got majority: 2/3)

Time 4: Real Election Begins
  Node B increments term: 5 → 6
  Node B votes for self
  Node B persists LastVote{term:6, candidate:B} to disk

Time 5: Vote Collection
  Node B sends replSetRequestVotes (term=6) to all
  Node C processes request:
    ✓ Config version matches
    ✓ Term 6 ≥ current term 5
    ✓ Set name matches
    ✓ B's OpTime ≥ C's OpTime
    ✓ Haven't voted this term yet
    ✓ Don't see current primary
  Node C grants vote, persists LastVote{term:6, candidate:B}
  Node C updates own term to 6
  Node C responds: VOTE GRANTED

Time 6: Election Success
  Node B receives majority votes (2/3)
  Node B calls: _onVoteRequestComplete(kSuccessfullyElected)
  Node B transitions: CANDIDATE → PRIMARY
  Node B begins catchup mode
  Node B starts sending heartbeats as primary

Time 7: Steady State
  Primary: Node B (term 6)
  Secondary: Node C (term 6)
  Down: Node A
  Cluster operational, accepting writes
```

## Configuration Parameters

Key parameters affecting election behavior:

| Parameter | Location | Default | Purpose |
|-----------|----------|---------|---------|
| `electionTimeoutMillis` | Replica set config | 10000 ms | Time before election triggered |
| `heartbeatIntervalMillis` | Server parameter | 2000 ms | Heartbeat frequency |
| `priority` | Member config | 1.0 | Node priority for elections (0 = never primary) |
| `votes` | Member config | 1 | Number of votes (0 or 1) |

## Summary

MongoDB's leader election mechanism provides robust failure recovery and controlled initialization through:

### Core Capabilities

1. **Heartbeat-based failure detection** - Quickly identifies unavailable nodes
2. **Raft-inspired voting protocol** - Ensures safety and consistency
3. **Dry run optimization** - Reduces unnecessary elections and term inflation
4. **Data freshness guarantees** - Prevents data loss during failover
5. **Configurable priorities** - Allows preferred primary selection
6. **Controlled initial primary selection** - Priority-based control over which node becomes first primary

### Initial vs Failover Elections

| Aspect | Initial Bootstrap | Failover |
|--------|------------------|----------|
| **Control** | ✓ Can be controlled via priority settings | ✗ Unpredictable timing |
| **Mechanism** | Priority + election timeout | Election timeout only |
| **Automatic Correction** | Priority takeover ensures preferred primary | N/A |
| **Single-Node Special Case** | Immediate auto-election | Standard election |

### Key Mechanisms

- **Election Safety:** At most one primary per term (majority voting)
- **Leader Completeness:** New primary always has all committed data (OpTime checks)
- **Priority Takeover:** Automatically corrects when lower-priority node is primary
- **Single-Node Optimization:** Immediate election for single-node replica sets

### Protocol Version

The `_v1` suffix indicates Protocol Version 1, which is the **current and only supported** election protocol in modern MongoDB. Protocol Version 0 (PV0) is deprecated and no longer supported (as of MongoDB 4.0+).

The implementation closely follows Raft's safety guarantees while adding practical optimizations for production deployments, including dry-run elections, priority-based takeovers, and arbiter support.
