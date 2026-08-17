// DRAFT (route 2a, rev4) — replace src/deptran/etcd/server.h lines 55-82, i.e.
// the WHOLE `if (loc_id_ != 0) { Coroutine::CreateRun([this]{ ... }); }` block.
//
// Changes vs current:
//   (1) DROP the `if (loc_id_ != 0)` guard -> the poller runs on EVERY replica.
//       Nobody knows in advance which machine's etcd becomes leader; the etcd
//       viewchange signal notifies the co-located Jetpack replica. The signal
//       file is MACHINE-LOCAL, so only the replica co-located with the new etcd
//       leader ever sees a viewchange -> exactly one recovery coordinator.
//   (2) Parse "etcd:viewchange term=T nonce=N", baseline the startup election
//       (ack only), and on a real failover stamp the View with view_id=term and
//       run recovery. The per-boot NONCE is echoed back in every ack so a stale
//       ack from a prior run cannot release etcd's barrier.
//
// NOTE: with the guard gone, loc0's replica may run JetpackRecoveryEntry if
// loc0's etcd wins a failover election — verify that recovery path (coordinator
// == hardcoded deptran leader) against scheduler.cc before landing.
//
// AFTER (the surrounding #ifdef JETPACK_ETCD_RECOVERY and closing brace stay):

    Coroutine::CreateRun([this]() {
      std::string host;
      if (frame_ && frame_->site_info_) {
        auto* si = frame_->site_info_;
        if (!si->host.empty())           host = si->host;
        else if (!si->proc_name.empty()) host = si->proc_name;
        else if (!si->name.empty())      host = si->name;
      }
#ifdef AWS
      host = "0.0.0.0";
#endif
      Log_info("[ETCD-FAILOVER] watching JM_Jetpack_%s for etcd view-change (loc_id=%d)",
               host.c_str(), loc_id_);
      epoch_t last_handled_view = 0;
      bool baseline_set = false;
      while (true) {
        std::string v = jm_signal::read_latest_value("etcd", host, "viewchange");
        if (!v.empty()) {  // "viewchange term=6 nonce=1723... lead=9 member=9"
          uint64_t term = 0, nonce = 0, lead = 0;
          jm_signal::parse_uint_field(v, "term", term);
          jm_signal::parse_uint_field(v, "nonce", nonce);
          jm_signal::parse_uint_field(v, "lead", lead);
          if (term != 0 && (epoch_t)term != last_handled_view) {
            last_handled_view = (epoch_t)term;
            if (!baseline_set) {
              // Startup election on this machine: no failure, nothing to recover.
              // Ack (echoing etcd's nonce) so the barrier releases immediately.
              baseline_set = true;
              jm_signal::set_key("jetpack",
                  "leader_paused term=" + std::to_string(term) +
                  " nonce=" + std::to_string(nonce), host);
              Log_info("[ETCD-FAILOVER] baseline view term=%lu (startup) loc_id=%d, acked, no recovery",
                       (unsigned long)term, loc_id_);
            } else {
              // Real failover: my co-located etcd is the NEW leader.
              Log_info("[ETCD-FAILOVER] failover view term=%lu lead=%lu loc_id=%d",
                       (unsigned long)term, (unsigned long)lead, loc_id_);
              int n_rep = (int) Config::GetConfig()->GetReplicaHosts(partition_id_).size();
              old_view_ = new_view_;
              new_view_ = View(n_rep, std::vector<int>{}, (epoch_t)term); // leaders_ empty
              if ((epoch_t)term > oepoch_) oepoch_ = (epoch_t)term;       // monotonic seed
              // ack (term + nonce) emitted inside, after RECOVERY set.
              JetpackRecoveryEntry((epoch_t)term, nonce);
            }
            // no break: keep watching for subsequent failovers on this machine
          }
        }
        auto sp_e = Reactor::CreateSpEvent<TimeoutEvent>(1 * 1000); // 1ms
        sp_e->Wait();
      }
    });
