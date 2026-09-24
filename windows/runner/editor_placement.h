#ifndef RUNNER_EDITOR_PLACEMENT_H_
#define RUNNER_EDITOR_PLACEMENT_H_

#include <cstdlib>
#include <string>
#include <vector>

// The editor window's placement, carried from an exiting editor host to the
// next one (over the pipe, then on the child's command line). Text so it is
// argv-safe: "left,top,right,bottom,showCmd" (normal-position rect in
// physical px + SW_SHOWMAXIMIZED / SW_SHOWNORMAL). Header-only for the tests.
namespace eplace {

struct Placement {
  long left = 0;
  long top = 0;
  long right = 0;
  long bottom = 0;
  int show_cmd = 1;  // SW_SHOWNORMAL
};

inline std::string Encode(const Placement& p) {
  return std::to_string(p.left) + "," + std::to_string(p.top) + "," +
         std::to_string(p.right) + "," + std::to_string(p.bottom) + "," +
         std::to_string(p.show_cmd);
}

inline bool Parse(const std::string& s, Placement* out) {
  std::vector<long> v;
  size_t start = 0;
  while (start <= s.size()) {
    const size_t comma = s.find(',', start);
    const std::string tok =
        s.substr(start, comma == std::string::npos ? comma : comma - start);
    if (tok.empty()) return false;
    char* end = nullptr;
    const long n = std::strtol(tok.c_str(), &end, 10);
    if (!end || *end != '\0') return false;
    v.push_back(n);
    if (comma == std::string::npos) break;
    start = comma + 1;
  }
  if (v.size() != 5) return false;
  if (v[2] <= v[0] || v[3] <= v[1]) return false;
  out->left = v[0];
  out->top = v[1];
  out->right = v[2];
  out->bottom = v[3];
  out->show_cmd = (v[4] == 3) ? 3 : 1;  // SW_SHOWMAXIMIZED or SW_SHOWNORMAL
  return true;
}

}  // namespace eplace

#endif  // RUNNER_EDITOR_PLACEMENT_H_
