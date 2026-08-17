// DRAFT (route 2a, rev2) — three edits so JetpackRecoveryEntry emits the
// term+nonce-matched ack that releases etcd's raft-loop barrier. Emitted at the
// SAME point as fastpath_stopped: AFTER jetpack_status_=RECOVERY (new commands
// already rejected) and BEFORE the multi-phase recovery/resubmit (so etcd
// resumes in ~ms, not after resubmits -> no deadlock).

// ---- Edit 1: src/deptran/scheduler.h:702 (declaration, add default args) ----
// BEFORE:  void JetpackRecoveryEntry();
// AFTER:   void JetpackRecoveryEntry(epoch_t etcd_view = 0, uint64_t etcd_nonce = 0);

// ---- Edit 2: src/deptran/scheduler.cc:1094 (definition signature) ----
// BEFORE:  void TxLogServer::JetpackRecoveryEntry() {
// AFTER:   void TxLogServer::JetpackRecoveryEntry(epoch_t etcd_view, uint64_t etcd_nonce) {

// ---- Edit 3: src/deptran/scheduler.cc, right after the existing
//              fastpath_stopped write (line 1123), still inside the host block ----
// BEFORE:
//     jm_signal::set_key("jetpack", "fastpath_stopped", host);
//     Log_info("[JETPACK-RECOVERY] Emitted jetpack:fastpath_stopped on JM_Jetpack_%s",
//              host.c_str());
// AFTER:
       jm_signal::set_key("jetpack", "fastpath_stopped", host);
       Log_info("[JETPACK-RECOVERY] Emitted jetpack:fastpath_stopped on JM_Jetpack_%s",
                host.c_str());
       // Route 2a: term+nonce-matched ack that releases the etcd new-leader
       // barrier (etcd's jetpackViewBarrier polls for exactly this line). The
       // nonce (echoed from etcd's viewchange) makes it robust to stale acks from
       // prior runs. etcd_view==0 for non-etcd callers (Raft/Mongo/ZK) -> no ack.
       if (etcd_view != 0) {
         jm_signal::set_key("jetpack",
             "leader_paused term=" + std::to_string(etcd_view) +
             " nonce=" + std::to_string(etcd_nonce), host);
         Log_info("[JETPACK-RECOVERY] Emitted jetpack:leader_paused term=%u nonce=%llu on JM_Jetpack_%s",
                  (unsigned)etcd_view, (unsigned long long)etcd_nonce, host.c_str());
       }

// Callers: only the etcd poller passes args; the rest use the defaults.
//   src/deptran/etcd/server.h:      JetpackRecoveryEntry((epoch_t)term, nonce);  // see poller draft
//   src/deptran/raft/server.cc:415  JetpackRecoveryEntry();                      // default 0,0 -> no ack
//   src/deptran/mongodb/server.h:135 JetpackRecoveryEntry();                     // default 0,0
//   src/deptran/zookeeper/server.h:86 JetpackRecoveryEntry();                    // default 0,0
