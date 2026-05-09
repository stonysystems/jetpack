#pragma once

#include <chrono>
#include <cstdlib>
#include <fstream>
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

}  // namespace jm_signal
