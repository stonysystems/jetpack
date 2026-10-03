#pragma once

// Backend term sources for the Jetpack recovery triggers of the etcd, MongoDB
// and ZooKeeper servers.
//
// Free of rrr/deptran types so the rules can be unit-tested without linking
// deptran: logging uses the rrr Log_info/Log_warn macros, which a unit test
// may define itself before including this header. Uses no name that
// constants.h #defines (key_t, epoch_t, ...), so it can be included before or
// after it.
//
//  - JpTermTrigger: the MongoDB / ZooKeeper trigger rules (term-bearing signal
//    lines plus self-detection, startup baselines, strictly-greater terms).
//  - JpEtcdViewchangeAction: the etcd one-coordinator-per-term filter.
//  - JetpackLeaderProbe: runs a blocking backend query (MongoDB hello,
//    ZooKeeper srvr) on its own thread and publishes the newest answer, so the
//    reactor-side poller never blocks.
//  - JpZkFourLetter / JpZkParseSrvr / JpTermFromElectionId: the queries'
//    transport and parsing.
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>

#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#ifndef Log_warn
#include "base/logging.hpp"  // rrr (also needed by jm_file_signal.h)
#endif
#include "../../jm_file_signal.h"

namespace janus {

// Poll interval of the MongoDB / ZooKeeper pollers (signal file and
// self-detection probe): 10 ms, or env JETPACK_LEADER_POLL_MS (1 .. 10000).
inline int JpLeaderPollMs() {
  static const int ms = []() {
    const char* e = std::getenv("JETPACK_LEADER_POLL_MS");
    if (e != nullptr && *e != '\0') {
      char* end = nullptr;
      const long v = std::strtol(e, &end, 10);
      if (end != e && *end == '\0' && v >= 1 && v <= 10000) return (int) v;
    }
    return 10;
  }();
  return ms;
}

// True the first time in this process a poller of `role` meets a legacy
// term-less line, so each role warns once per process, not once per replica.
inline bool JpFirstLegacyWarning(const std::string& role) {
  static std::mutex mu;
  static std::set<std::string> warned;
  std::lock_guard<std::mutex> g(mu);
  return warned.insert(role).second;
}

// The newest "<role>:<prefix>[ ...]" signal line.
struct JpTermLine {
  bool present = false;   // there is such a line
  bool has_term = false;  // it carries term= (a legacy line does not)
  uint64_t term = 0;
  bool has_loc = false;   // loc=: the only replica locale that may act on it
  uint64_t loc = 0;
};

inline JpTermLine JpReadTermLine(const std::string& role, const std::string& host,
                                 const std::string& prefix) {
  JpTermLine l;
  std::string value;
  uint64_t term = 0;
  l.has_term = jm_signal::read_latest_term(role, host, prefix, &term, nullptr, &value);
  l.present = !value.empty();
  if (l.has_term) {
    l.term = term;
    l.has_loc = jm_signal::parse_uint_field(value, "loc", l.loc);
  }
  return l;
}

// The newest answer of the co-located backend node (JetpackLeaderProbe).
struct JpTermProbe {
  uint64_t seq = 0;     // completed probes; 0 = none yet
  bool ok = false;      // the node answered
  bool leader = false;  // ... and is the writable primary / ZAB leader
  uint64_t term = 0;    // its replica-set term / ZAB epoch (0 = unknown)
  // The node's CURRENT term / epoch when known exactly, else 0. T_rejoin
  // must be at least every term that existed before the restart; a MongoDB
  // secondary's last-write term or a ZooKeeper follower's last-zxid epoch can
  // be older than the current one, so they never fill this field.
  uint64_t current_term = 0;
};

// On MongoDB a takeover replica can lead view v only if its co-located
// node (the mongod its pool writes to, directConnection) answers as the
// primary of term v; else *why says what is missing.
inline bool JpProbeLeadsTerm(const JpTermProbe& p, uint64_t v, std::string* why) {
  if (p.seq == 0) {
    *why = "the co-located node has not answered yet";
  } else if (!p.ok) {
    *why = "the co-located node does not answer";
  } else if (!p.leader) {
    *why = "the co-located node is not the primary";
  } else if (p.term != v) {
    *why = "the co-located node is the primary of term " + std::to_string(p.term);
  } else {
    return true;
  }
  return false;
}

// Trigger rules of the MongoDB / ZooKeeper pollers, one instance per
// poller. A term T starts a recovery (once) if it is above every term this
// poller handled and above the startup baselines, and
//  - the newest signal line carries term=T and either no loc= (a per-host
//    signal file) or loc= this replica's locale, or
//  - the co-located node reports that it leads term T (self-detection).
// Baselines: term-bearing lines already on disk at startup are history (any
// loc), and so is the first probe answer with a nonzero term (assumption: the
// backend primary/leader at startup is co-located with locale 0, whose static
// view is the initial Jetpack view). A failover that completes before the
// first probe answer is therefore taken as the baseline. A line naming another
// locale is skipped without being consumed, so this replica still acts if its
// own node turns out to lead that term. Self-detection is not held back by a
// (possibly stale) on-disk line baseline; a line is held back by both. Terms
// at or above max_term are no usable view id (the ballot encoding needs
// v < 2^31): reported once, otherwise ignored, so they never raise a baseline
// or the handled term (one bogus line must not block every later term).
class JpTermTrigger {
 public:
  struct Step {
    uint64_t trigger = 0;            // term to recover for; 0 = none
    bool from_line = false;          // the signal line asked for `trigger`
    bool from_self = false;          // the co-located node leads `trigger`
    bool legacy_line = false;        // the newest line carries no term
    bool self_baseline = false;      // this step took the self-detection baseline
    bool self_baseline_leader = false;
    uint64_t self_baseline_term = 0;
    bool line_other_loc = false;     // a new line names another locale (once per term)
    uint64_t line_term = 0;
    uint64_t line_loc = 0;
    uint64_t unusable_term = 0;      // a term >= max_term was seen (once per value)
  };

  explicit JpTermTrigger(uint64_t my_loc, uint64_t max_term = UINT64_MAX)
      : my_loc_(my_loc), max_term_(max_term) {}

  void BaselineFromDisk(const JpTermLine& l) {
    if (l.has_term && l.term < max_term_) line_base_ = std::max(line_base_, l.term);
  }

  Step Next(const JpTermLine& l, const JpTermProbe& p) {
    Step s;
    uint64_t by_line = 0, by_self = 0;
    // The line first: a failover line already present when the first probe
    // answer arrives must not be swallowed by the self baseline.
    if (l.present && !l.has_term) {
      s.legacy_line = true;
    }
    if (l.has_term && Usable(l.term, &s) &&
        l.term > std::max(std::max(line_base_, self_base_), handled_)) {
      if (!l.has_loc || l.loc == my_loc_) {
        by_line = l.term;
      } else if (l.term > other_logged_) {
        other_logged_ = l.term;
        s.line_other_loc = true;
        s.line_term = l.term;
        s.line_loc = l.loc;
      }
    }
    if (p.seq > 0 && p.ok && Usable(p.term, &s)) {
      if (!self_based_) {
        // A node that has seen no term yet (still starting) carries no
        // information; the baseline is its first real term.
        if (p.term > 0) {
          self_based_ = true;
          self_base_ = p.term;
          s.self_baseline = true;
          s.self_baseline_leader = p.leader;
          s.self_baseline_term = p.term;
        }
      } else if (p.leader && p.term > std::max(self_base_, handled_)) {
        by_self = p.term;
      }
    }
    s.trigger = std::max(by_line, by_self);
    if (s.trigger != 0) {
      s.from_line = by_line == s.trigger;
      s.from_self = by_self == s.trigger;
      handled_ = s.trigger;
    }
    return s;
  }

  uint64_t handled() const { return handled_; }
  uint64_t line_baseline() const { return line_base_; }
  bool self_baselined() const { return self_based_; }
  uint64_t self_baseline() const { return self_base_; }

 private:
  bool Usable(uint64_t t, Step* s) {
    if (t < max_term_) return true;
    if (t != unusable_logged_) {
      unusable_logged_ = t;
      s->unusable_term = t;
    }
    return false;
  }

  uint64_t my_loc_;
  uint64_t max_term_;
  uint64_t line_base_ = 0;
  bool self_based_ = false;
  uint64_t self_base_ = 0;
  uint64_t handled_ = 0;
  uint64_t other_logged_ = 0;
  uint64_t unusable_logged_ = 0;
};

// What the etcd poller does with a viewchange line whose term is above the
// last handled one. With the filter on (Jetpack recovery enabled), only the
// replica co-located with the etcd member named by member= coordinates (and
// acks), and a loc= line (written by the JETPACK_ETCD_SIMULATION writer) only
// at that locale. member_state: kJpMemberLearning while the co-located member
// id is being learned (the line waits, at most until wait_expired),
// kJpMemberKnown (my_member valid) or kJpMemberUnknown (could not be learned:
// no member filter). A line without member= names no member.
enum JpEtcdMemberState { kJpMemberLearning = 0, kJpMemberKnown = 1, kJpMemberUnknown = 2 };
enum class JpEtcdAction { kCoordinate, kNotOurs, kWait };

inline JpEtcdAction JpEtcdViewchangeAction(bool filter, int member_state, uint64_t my_member,
                                           const std::string& value, uint64_t my_loc,
                                           bool wait_expired) {
  if (!filter) return JpEtcdAction::kCoordinate;
  uint64_t loc = 0;
  if (jm_signal::parse_uint_field(value, "loc", loc) && loc != my_loc) {
    return JpEtcdAction::kNotOurs;
  }
  uint64_t member = 0;
  if (!jm_signal::parse_uint_field(value, "member", member)) return JpEtcdAction::kCoordinate;
  if (member_state == kJpMemberLearning && !wait_expired) return JpEtcdAction::kWait;
  if (member_state == kJpMemberKnown && member != my_member) return JpEtcdAction::kNotOurs;
  return JpEtcdAction::kCoordinate;
}

// MongoDB protocol-version-1 electionId = OID::fromTerm(term): 0x7fffffff
// followed by the big-endian int64 term. Returns false for any other OID.
inline bool JpTermFromElectionId(const unsigned char* b, size_t n, uint64_t* term) {
  if (n != 12 || b[0] != 0x7f || b[1] != 0xff || b[2] != 0xff || b[3] != 0xff) return false;
  uint64_t t = 0;
  for (size_t i = 4; i < 12; i++) t = (t << 8) | b[i];
  *term = t;
  return true;
}

// "host:port" (port 1..65535) -> host, port; false if malformed.
inline bool JpParseHostPort(const std::string& s, std::string* host, int* port) {
  const auto colon = s.rfind(':');
  if (colon == std::string::npos || colon == 0 || colon + 1 >= s.size()) return false;
  char* end = nullptr;
  const long p = std::strtol(s.c_str() + colon + 1, &end, 10);
  if (*end != '\0' || p < 1 || p > 65535) return false;
  *host = s.substr(0, colon);
  *port = (int) p;
  return true;
}

// Sends a ZooKeeper four-letter word (e.g. "srvr") to host:port and reads the
// reply until the server closes the connection. Blocking, so never on the
// reactor thread; connect and every read are bounded by timeout_ms.
inline bool JpZkFourLetter(const std::string& host, int port, const std::string& cmd,
                           int timeout_ms, std::string* reply, std::string* err) {
  struct addrinfo hints;
  std::memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  struct addrinfo* res = nullptr;
  const int gai = ::getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &res);
  if (gai != 0) {
    *err = std::string("getaddrinfo: ") + ::gai_strerror(gai);
    return false;
  }
  bool ok = false;
  for (struct addrinfo* ai = res; ai != nullptr && !ok; ai = ai->ai_next) {
    const int fd = ::socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
    if (fd < 0) {
      *err = std::string("socket: ") + std::strerror(errno);
      continue;
    }
    const int flags = ::fcntl(fd, F_GETFL, 0);
    ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = ::connect(fd, ai->ai_addr, ai->ai_addrlen);
    if (rc < 0 && errno == EINPROGRESS) {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLOUT;
      pfd.revents = 0;
      rc = ::poll(&pfd, 1, timeout_ms);
      if (rc == 1) {
        int so_err = 0;
        socklen_t len = sizeof(so_err);
        ::getsockopt(fd, SOL_SOCKET, SO_ERROR, &so_err, &len);
        rc = so_err == 0 ? 0 : -1;
        errno = so_err;
      } else {
        if (rc == 0) errno = ETIMEDOUT;
        rc = -1;
      }
    }
    if (rc != 0) {
      *err = std::string("connect: ") + std::strerror(errno);
      ::close(fd);
      continue;
    }
    // Requests are a few bytes: a non-blocking send of the whole word.
    const ssize_t sent = ::send(fd, cmd.data(), cmd.size(), MSG_NOSIGNAL);
    if (sent != (ssize_t) cmd.size()) {
      *err = std::string("send: ") + std::strerror(errno);
      ::close(fd);
      continue;
    }
    std::string out;
    char buf[1024];
    bool closed = false;
    while (out.size() < 64 * 1024) {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLIN;
      pfd.revents = 0;
      rc = ::poll(&pfd, 1, timeout_ms);
      if (rc <= 0) break;  // timeout or error
      const ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
      if (n > 0) {
        out.append(buf, (size_t) n);
      } else if (n == 0) {
        closed = true;
        break;
      } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        break;
      }
    }
    ::close(fd);
    if (!out.empty()) {
      *reply = out;
      ok = true;
    } else {
      *err = closed ? "empty reply" : "no reply before the timeout";
    }
  }
  ::freeaddrinfo(res);
  return ok;
}

// Parses a ZooKeeper "srvr" reply: "Mode: <mode>" and "Zxid: 0x<hex>". The
// ZAB epoch is zxid >> 32 (a new leader serves from makeZxid(epoch, 0) on).
// A server that is not serving yet ("This ZooKeeper instance is not currently
// serving requests") or a refused command gives no answer.
inline bool JpZkParseSrvr(const std::string& reply, bool* leader, uint64_t* epoch,
                          std::string* err) {
  std::istringstream in(reply);
  std::string line, mode;
  bool has_mode = false, has_zxid = false;
  uint64_t zxid = 0;
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.compare(0, 6, "Mode: ") == 0) {
      mode = line.substr(6);
      has_mode = true;
    } else if (line.compare(0, 6, "Zxid: ") == 0) {
      const std::string hex = line.substr(6);
      char* end = nullptr;
      errno = 0;
      const unsigned long long z = std::strtoull(hex.c_str(), &end, 16);
      if (end != hex.c_str() && *end == '\0' && errno == 0) {
        zxid = (uint64_t) z;
        has_zxid = true;
      }
    }
  }
  if (!has_mode || !has_zxid) {
    std::string first = reply.substr(0, reply.find('\n'));
    if (first.size() > 120) first.resize(120);
    *err = "unexpected srvr reply: " + first;
    return false;
  }
  *leader = mode == "leader";
  *epoch = zxid >> 32;
  return true;
}

// The current ZAB epoch of a ZooKeeper server from its data directory,
// max(version-2/currentEpoch, version-2/acceptedEpoch) (decimal files that
// QuorumPeer writes when it joins an epoch). Unlike srvr's Zxid, which on a
// follower is the last processed zxid and may still be from an older epoch,
// this is the newest epoch the server took part in. False if neither file
// can be read.
inline bool JpZkDataDirEpoch(const std::string& data_dir, uint64_t* epoch, std::string* err) {
  bool any = false;
  uint64_t best = 0;
  for (const char* name : {"currentEpoch", "acceptedEpoch"}) {
    const std::string path = data_dir + "/version-2/" + name;
    FILE* f = std::fopen(path.c_str(), "r");
    if (f == nullptr) continue;
    char buf[64] = {0};
    const size_t got = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    buf[got] = '\0';
    char* end = nullptr;
    errno = 0;
    const unsigned long long v = std::strtoull(buf, &end, 10);
    if (end == buf || errno != 0) continue;
    while (*end == '\n' || *end == '\r' || *end == ' ') end++;
    if (*end != '\0') continue;
    any = true;
    best = std::max<uint64_t>(best, (uint64_t) v);
  }
  if (!any) {
    *err = "no readable currentEpoch/acceptedEpoch under " + data_dir + "/version-2";
    return false;
  }
  *epoch = best;
  return true;
}

// Runs a blocking backend query every interval on its own thread (like the
// connection pools' worker threads, never on the reactor) and publishes the
// newest answer; Latest() is a cheap locked copy for the reactor-side poller.
class JetpackLeaderProbe {
 public:
  // One answer of the backend node (see JpTermProbe).
  struct Answer {
    bool leader = false;
    uint64_t term = 0;
    uint64_t current_term = 0;
  };
  // On the probe thread: true if the backend answered (*a set), else false
  // with *err. Exceptions count as failures.
  using FnEx = std::function<bool(Answer* a, std::string* err)>;
  // The plain form (*leader, *term): a leader's term is its current term; a
  // non-leader's is not known to be current.
  using Fn = std::function<bool(bool* leader, uint64_t* term, std::string* err)>;

  JetpackLeaderProbe(const std::string& tag, FnEx fn, int interval_ms)
      : tag_(tag), fn_(std::move(fn)), interval_ms_(interval_ms < 1 ? 1 : interval_ms) {}
  JetpackLeaderProbe(const std::string& tag, Fn fn, int interval_ms)
      : JetpackLeaderProbe(tag, FnEx([fn](Answer* a, std::string* err) -> bool {
                             if (!fn(&a->leader, &a->term, err)) return false;
                             a->current_term = a->leader ? a->term : 0;
                             return true;
                           }),
                           interval_ms) {}
  JetpackLeaderProbe(const JetpackLeaderProbe&) = delete;
  JetpackLeaderProbe& operator=(const JetpackLeaderProbe&) = delete;
  ~JetpackLeaderProbe() { Stop(); }

  void Start() {
    std::lock_guard<std::mutex> g(mu_);
    if (started_ || stop_) return;
    started_ = true;
    th_ = std::thread([this]() { Run(); });
  }

  // Joins the thread; it returns within one query's own timeout.
  void Stop() {
    {
      std::lock_guard<std::mutex> g(mu_);
      stop_ = true;
    }
    cv_.notify_all();
    if (th_.joinable() && th_.get_id() != std::this_thread::get_id()) th_.join();
  }

  JpTermProbe Latest() const {
    std::lock_guard<std::mutex> g(mu_);
    return sample_;
  }

 private:
  void Run() {
    uint64_t fails = 0;
    auto last_log = std::chrono::steady_clock::now();
    while (true) {
      bool ok = false;
      Answer a;
      std::string err;
      try {
        ok = fn_(&a, &err);
      } catch (const std::exception& e) {
        ok = false;
        err = e.what();
      } catch (...) {
        ok = false;
        err = "unknown exception";
      }
      {
        std::lock_guard<std::mutex> g(mu_);
        sample_.seq++;
        sample_.ok = ok;
        sample_.leader = ok && a.leader;
        sample_.term = ok ? a.term : 0;
        sample_.current_term = ok ? a.current_term : 0;
      }
      const auto now = std::chrono::steady_clock::now();
      if (!ok) {
        fails++;
        if (fails == 1 || now - last_log >= std::chrono::seconds(10)) {
          last_log = now;
          if (err.size() > 200) err.resize(200);
          Log_warn("%s self-detection probe failed (%llu in a row): %s", tag_.c_str(),
                   (unsigned long long) fails, err.c_str());
        }
      } else if (fails > 0) {
        Log_info("%s self-detection probe answers again after %llu failures", tag_.c_str(),
                 (unsigned long long) fails);
        fails = 0;
      }
      std::unique_lock<std::mutex> lk(mu_);
      if (cv_.wait_for(lk, std::chrono::milliseconds(interval_ms_), [this]() { return stop_; })) {
        return;
      }
    }
  }

  const std::string tag_;
  const FnEx fn_;
  const int interval_ms_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
  bool started_ = false;
  bool stop_ = false;
  JpTermProbe sample_;
  std::thread th_;
};

}  // namespace janus
