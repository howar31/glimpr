#ifndef RUNNER_PROCESS_IDENTITY_H_
#define RUNNER_PROCESS_IDENTITY_H_

#include <windows.h>

#include <cwctype>
#include <string>

// "Is that window ours?" now that glimpr runs as several processes (main,
// record worker, overlay host, editor host): any process running this same
// exe counts as ours. Header-only so the native tests cover it.
namespace procid {

inline bool SameExePath(const std::wstring& a, const std::wstring& b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i) {
    if (std::towlower(a[i]) != std::towlower(b[i])) return false;
  }
  return true;
}

inline const std::wstring& OwnExePath() {
  static const std::wstring path = [] {
    wchar_t buf[MAX_PATH]{};
    const DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    return std::wstring(buf, n);
  }();
  return path;
}

inline bool IsOurProcess(DWORD pid) {
  if (pid == 0) return false;
  if (pid == GetCurrentProcessId()) return true;
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return false;
  wchar_t buf[MAX_PATH]{};
  DWORD n = MAX_PATH;
  const bool ok = QueryFullProcessImageNameW(h, 0, buf, &n) != 0;
  CloseHandle(h);
  return ok && SameExePath(std::wstring(buf, n), OwnExePath());
}

}  // namespace procid

#endif  // RUNNER_PROCESS_IDENTITY_H_
