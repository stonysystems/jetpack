#pragma once

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <sys/stat.h>
#include <sys/types.h>

// Minimal file-based signaling utility for JetPack ↔ Mongo coordination.
// Both sides append lines of the form "<role>:<value>" to a shared file
// named "JM_Jetpack_<host>" located under /tmp by default (override with
// env JM_SIGNAL_DIR). No external dependencies beyond the C++17 standard
// library.
namespace jm_signal {

inline std::string BaseDir(const std::string& role = "") {
  const char* env = std::getenv("JM_SIGNAL_DIR");
  if (env && *env) {
    return std::string(env);
  }
  // Since mongo code write signal to /tmp to pass signal to local machine
  // if (role == "mongo")
  //   return "/tmp";
// #ifdef AWS
//   return "/home/ubuntu/code/tmp";
// #else
  return "/tmp";
// #endif
}

inline std::string FilePath(const std::string& role, const std::string& host) {
  return BaseDir(role) + "/JM_Jetpack_" + host;
}

inline void set_key(const std::string& role,
                    const std::string& value,
                    const std::string& host) {
  const auto path = FilePath(role, host);
  const auto parent = BaseDir(role);
  if (!parent.empty()) {
    ::mkdir(parent.c_str(), 0755); // ignore errors if exists
  }
  std::ofstream out(path, std::ios::app);
  if (!out.is_open()) {
#ifdef JM_SIGNAL_DEBUG
  Log_info("[JM_SIGNAL][SET] FAIL role=%s value=%s host=%s path=%s",
           role.c_str(), value.c_str(), host.c_str(), path.c_str());
#endif
    throw std::runtime_error("Failed to open signal file: " + path);
  }
  out << role << ":" << value << "\n";
  out.flush();
#ifdef JM_SIGNAL_DEBUG
  Log_info("[JM_SIGNAL][SET] role=%s value=%s host=%s path=%s",
           role.c_str(), value.c_str(), host.c_str(), path.c_str());
#endif
}

inline void wait_for_key(const std::string& role,
                         const std::string& value,
                         const std::string& host) {
  const auto path = FilePath(role, host);
  const std::string needle = role + ":" + value;
  for (;;) {
    std::ifstream in(path);
    // std::system("ls /home/ubuntu/code/tmp");
    if (in.is_open()) {
      std::string line;
      while (std::getline(in, line)) {
        if (line == needle) {
          return;
        } else {
          Log_info("[CLIENT_SYNC] line=%s not match needle=%s", line.c_str(), needle.c_str());
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

inline bool exists_key(const std::string& role,
                       const std::string& value,
                       const std::string& host) {
  const auto path = FilePath(role, host);
  const std::string needle = role + ":" + value;
  std::ifstream in(path);
  if (!in.is_open()) {
#ifdef JM_SIGNAL_DEBUG
    Log_info("[JM_SIGNAL][EXISTS] missing file path=%s role=%s value=%s host=%s",
             path.c_str(), role.c_str(), value.c_str(), host.c_str());
#endif
    return false;
  }
  std::string line;
  while (std::getline(in, line)) {
    if (line == needle) {
#ifdef JM_SIGNAL_DEBUG
      Log_info("[JM_SIGNAL][EXISTS] found role=%s value=%s host=%s path=%s",
               role.c_str(), value.c_str(), host.c_str(), path.c_str());
#endif
      return true;
    }
  }
#ifdef JM_SIGNAL_DEBUG
  Log_info("[JM_SIGNAL][EXISTS] not found role=%s value=%s host=%s path=%s",
           role.c_str(), value.c_str(), host.c_str(), path.c_str());
#endif
  return false;
}

// Newest "<role>:<value>" line whose value starts with value_prefix, or "" if
// there is none. The signal file is append-only and shared by both sides of the
// handshake, so filtering by prefix keeps an unrelated later "<role>:..." line
// from masking a pending payload. value_prefix="" matches any value.
inline std::string read_latest_value(const std::string& role,
                                     const std::string& host,
                                     const std::string& value_prefix = "") {
  const auto path = FilePath(role, host);
  const std::string line_prefix = role + ":" + value_prefix;
  std::ifstream in(path);
  if (!in.is_open()) return std::string();
  std::string line, latest;
  while (std::getline(in, line)) {
    if (line.rfind(line_prefix, 0) == 0) {   // starts with "<role>:<value_prefix>"
      latest = line.substr(role.size() + 1); // strip "<role>:" -> keep value
    }
  }
  return latest;
}

// Parse the unsigned integer following "<key>=" in s, e.g. key="term" in
// "viewchange term=6 nonce=17 lead=9" -> 6. "<key>=" counts only at position 0
// or right after a space, so key="term" does not read "xterm=6" and key="lead"
// does not read "mislead=3"; the first such occurrence decides. Returns false
// if the key is absent, is not followed by at least one digit, or the number
// does not fit in 64 bits.
inline bool parse_uint_field(const std::string& s,
                             const std::string& key,
                             uint64_t& out) {
  const std::string pat = key + "=";
  auto pos = s.find(pat);
  while (pos != std::string::npos && pos != 0 && s[pos - 1] != ' ') {
    pos = s.find(pat, pos + 1);
  }
  if (pos == std::string::npos) return false;
  pos += pat.size();
  uint64_t v = 0;
  bool any = false;
  for (; pos < s.size() && s[pos] >= '0' && s[pos] <= '9'; ++pos) {
    const uint64_t d = static_cast<uint64_t>(s[pos] - '0');
    if (v > (UINT64_MAX - d) / 10) return false;  // overflow
    v = v * 10 + d;
    any = true;
  }
  if (!any) return false;
  out = v;
  return true;
}

// Newest "<role>:<prefix>" line (the prefix followed by the end of the line or
// a space, so "viewchange" does not match "viewchanged ...") and the term it
// carries: "mongo:primary_elected term=7 loc=1" -> *term = 7. *nonce (may be
// null) gets nonce= if present, else 0. *value_out (may be null) gets the
// newest matching value even when it carries no term, so a caller can tell a
// legacy term-less line ("mongo:primary_elected") from no line at all.
// Returns false if there is no matching line or the newest one has no term=;
// an older term-bearing line is then NOT used (the newest line wins).
inline bool read_latest_term(const std::string& role,
                             const std::string& host,
                             const std::string& prefix,
                             uint64_t* term,
                             uint64_t* nonce,
                             std::string* value_out = nullptr) {
  const auto path = FilePath(role, host);
  const std::string line_prefix = role + ":" + prefix;
  std::string latest;
  bool found = false;
  std::ifstream in(path);
  if (in.is_open()) {
    std::string line;
    while (std::getline(in, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (line.compare(0, line_prefix.size(), line_prefix) == 0 &&
          (line.size() == line_prefix.size() || line[line_prefix.size()] == ' ')) {
        latest = line.substr(role.size() + 1);  // strip "<role>:"
        found = true;
      }
    }
  }
  if (value_out != nullptr) *value_out = found ? latest : std::string();
  if (nonce != nullptr) *nonce = 0;
  if (!found) return false;
  uint64_t t = 0;
  if (!parse_uint_field(latest, "term", t)) return false;
  *term = t;
  if (nonce != nullptr) {
    uint64_t n = 0;
    if (parse_uint_field(latest, "nonce", n)) *nonce = n;
  }
  return true;
}

}  // namespace jm_signal
