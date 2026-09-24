// Native readers for the settings the Flutter side persists in
// %APPDATA%\Howar31\<app>\shared_preferences.json (shared_preferences_windows:
// ONE compact JSON object, ASCII keys, no `flutter.` prefix, rewritten whole on
// every set). Read at process start, before any Flutter engine exists, for the
// settings the engine itself needs (GPU preference). Identity-aware: a
// GlimprDev build reads GlimprDev's file (app_identity.h). Pure functions only
// (no Flutter headers) so windows/test can cover the parsing.
#ifndef RUNNER_PREFS_PROBE_H_
#define RUNNER_PREFS_PROBE_H_

#include <windows.h>
#include <shlobj.h>

#include <cstdio>
#include <string>

#include "app_identity.h"

namespace prefs {

// The string value of `key` in a flat compact JSON object, or "" when the key
// is absent or its value is not a string. Matches the QUOTED key followed by a
// colon, so a longer key that merely ends with `key` never matches and a
// string VALUE equal to the key is skipped. No escape handling: the values we
// read are enum wire names (ASCII, no quotes or backslashes).
inline std::string JsonStringValue(const std::string& json, const char* key) {
  const std::string quoted = std::string("\"") + key + "\"";
  size_t pos = 0;
  while ((pos = json.find(quoted, pos)) != std::string::npos) {
    size_t p = pos + quoted.size();
    while (p < json.size() && (json[p] == ' ' || json[p] == '\t')) ++p;
    if (p >= json.size() || json[p] != ':') {
      pos = p;
      continue;
    }
    ++p;
    while (p < json.size() && (json[p] == ' ' || json[p] == '\t')) ++p;
    if (p >= json.size() || json[p] != '"') return std::string();
    const size_t end = json.find('"', p + 1);
    if (end == std::string::npos) return std::string();
    return json.substr(p + 1, end - p - 1);
  }
  return std::string();
}

// Mirrors lib/settings/gpu_preference.dart. kSystem = no preference, which
// must stay the fallback for anything unknown (the Dart default is `system`).
enum class GpuChoice { kSystem, kLowPower, kHighPerformance };

inline GpuChoice GpuChoiceFromWire(const std::string& wire) {
  if (wire == "low_power") return GpuChoice::kLowPower;
  if (wire == "high_performance") return GpuChoice::kHighPerformance;
  return GpuChoice::kSystem;
}

// %APPDATA%\Howar31\<GLIMPR_APP_NAME>, or "" when the known folder fails.
inline std::wstring PrefsDir() {
  PWSTR roaming = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                  &roaming))) {
    return std::wstring();
  }
  std::wstring dir(roaming);
  CoTaskMemFree(roaming);
  dir += L"\\Howar31\\";
  dir += GLIMPR_APP_NAME_W;
  return dir;
}

// The persisted string for `key`, or "" (missing file / key / non-string).
inline std::string ReadPrefsString(const char* key) {
  const std::wstring dir = PrefsDir();
  if (dir.empty()) return std::string();
  const std::wstring path = dir + L"\\shared_preferences.json";
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return std::string();
  std::string json;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) json.append(buf, n);
  fclose(f);
  return JsonStringValue(json, key);
}

}  // namespace prefs

#endif  // RUNNER_PREFS_PROBE_H_
