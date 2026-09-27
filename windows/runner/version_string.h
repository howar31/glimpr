#ifndef RUNNER_VERSION_STRING_H_
#define RUNNER_VERSION_STRING_H_

#include <string>

// The exe's ProductVersion STRING as the Flutter tool writes it:
// "<build-name>+<build-number>", e.g. "1.21.1+35" or "1.21.1-rc.1+35". Unlike
// the numeric VERSIONINFO fields it keeps a prerelease suffix, so a release
// candidate shows and compares as one (CI passes the tag as the build name).
// Header-only so the native tests cover it.
namespace version_string {

// Splits "<marketing>+<build>"; the build part may be absent. False on an
// empty input (outputs untouched).
inline bool Split(const std::string& product_version, std::string* marketing,
                  std::string* build) {
  if (product_version.empty()) return false;
  const size_t plus = product_version.find('+');
  if (plus == std::string::npos) {
    *marketing = product_version;
    build->clear();
  } else {
    *marketing = product_version.substr(0, plus);
    *build = product_version.substr(plus + 1);
  }
  return !marketing->empty();
}

// "1.21.1-rc.1 (35)", or just the marketing version when there is no build.
inline std::string Display(const std::string& marketing,
                           const std::string& build) {
  return build.empty() ? marketing : marketing + " (" + build + ")";
}

}  // namespace version_string

#endif  // RUNNER_VERSION_STRING_H_
