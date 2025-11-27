#pragma once

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>

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
  return "/tmp";
}

inline std::string FilePath(const std::string& host) {
  std::filesystem::path dir(BaseDir());
  return (dir / ("JM_Jetpack_" + host)).string();
}

inline void set_key(const std::string& role,
                    const std::string& value,
                    const std::string& host) {
  const auto path = FilePath(host);
  const auto parent = std::filesystem::path(path).parent_path();
  if (!parent.empty()) {
    std::error_code ec;
    std::filesystem::create_directories(parent, ec);
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
    if (in.is_open()) {
      std::string line;
      while (std::getline(in, line)) {
        if (line == needle) {
          return;
        }
      }
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
}

}  // namespace jm_signal
