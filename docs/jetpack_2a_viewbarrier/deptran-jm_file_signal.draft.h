// DRAFT (route 2a) — additions to jm_file_signal.h.
//
// MERGE:
//   * add `#include <cstdint>` to the TOP-OF-FILE includes (lines 3-9, global scope).
//   * paste the two functions below INSIDE `namespace jm_signal { ... }`,
//     just before the closing `}  // namespace jm_signal` (line 114).
//     (They call FilePath(), which lives in that namespace.)

// Newest "<role>:<value>" line whose value starts with value_prefix, or "" if
// none. Prefix-filtering prevents an unrelated later "<role>:..." line from
// masking a pending payload. value_prefix="" matches any value.
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

// Parse the unsigned integer after "<key>=" in s. e.g. key="term" in
// "viewchange term=6 lead=9 member=9" -> 6. Returns true on success.
inline bool parse_uint_field(const std::string& s,
                             const std::string& key,
                             uint64_t& out) {
  const std::string pat = key + "=";
  auto pos = s.find(pat);
  if (pos == std::string::npos) return false;
  pos += pat.size();
  uint64_t v = 0;
  bool any = false;
  for (; pos < s.size() && s[pos] >= '0' && s[pos] <= '9'; ++pos) {
    v = v * 10 + static_cast<uint64_t>(s[pos] - '0');
    any = true;
  }
  if (!any) return false;
  out = v;
  return true;
}
