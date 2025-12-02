#pragma once

#include <chrono>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>
#include <sys/stat.h>
#include <sys/types.h>

// Minimal file-based signaling utility for JetPack ↔ Mongo coordination.
// Both sides append lines of the form "<role>:<value>" to a shared file
// named "JM_Jetpack_<host>" located under /tmp by default (override with
// env JM_SIGNAL_DIR). No external dependencies beyond the C++17 standard
// library.
namespace jm_signal {

inline std::string BaseDir() {
  const char* env = std::getenv("JM_SIGNAL_DIR");
  if (env && *env) {
    return std::string(env);
  }
#ifdef AWS
  return "/home/ubuntu/code/tmp";
#endif
#ifndef AWS
  return "/tmp";
#endif
}

inline std::string FilePath(const std::string& host) {
  return BaseDir() + "/JM_Jetpack_" + host;
}

inline void set_key(const std::string& role,
                    const std::string& value,
                    const std::string& host) {
  const auto path = FilePath(host);
  const auto parent = BaseDir();
  if (!parent.empty()) {
    ::mkdir(parent.c_str(), 0755); // ignore errors if exists
  }
  std::ofstream out(path, std::ios::app);
  if (!out.is_open()) {
    throw std::runtime_error("Failed to open signal file: " + path);
  }
  out << role << ":" << value << "\n";
  out.flush();
}

inline void wait_for_key(const std::string& role,
                         const std::string& value,
                         const std::string& host) {
  const auto path = FilePath(host);
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
  const auto path = FilePath(host);
  const std::string needle = role + ":" + value;
  std::ifstream in(path);
  if (!in.is_open()) {
    return false;
  }
  std::string line;
  while (std::getline(in, line)) {
    if (line == needle) {
      return true;
    }
  }
  return false;
}

}  // namespace jm_signal
