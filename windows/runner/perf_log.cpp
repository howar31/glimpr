#include "perf_log.h"

#include <windows.h>
#include <shlobj.h>

#include <cstdio>

namespace perf {
namespace {

bool g_enabled = false;
HANDLE g_file = INVALID_HANDLE_VALUE;
LARGE_INTEGER g_qpc_freq{};
LARGE_INTEGER g_qpc_origin{};
CRITICAL_SECTION g_lock;

std::wstring PrefsDir() {
  PWSTR roaming = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                  &roaming))) {
    return L"";
  }
  std::wstring dir(roaming);
  CoTaskMemFree(roaming);
  return dir + L"\\com.example\\glimpr";
}

// The same flat shared_preferences.json the Dart perf gate reads
// (lib/perf/perf_gate.dart), so ONE debugHooks switch arms both sides. A dumb
// substring probe is enough (flat compact JSON, unique ASCII key) -- the same
// idiom as hdr_util's ReadHdrScreenshotSetting.
bool ReadGate() {
  std::wstring path = PrefsDir();
  if (path.empty()) return false;
  path += L"\\shared_preferences.json";
  FILE* f = nullptr;
  if (_wfopen_s(&f, path.c_str(), L"rb") != 0 || !f) return false;
  std::string json;
  char buf[4096];
  size_t n;
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) json.append(buf, n);
  fclose(f);
  const size_t key = json.find("\"debugHooks\"");
  if (key == std::string::npos) return false;
  const size_t colon = json.find(':', key);
  if (colon == std::string::npos) return false;
  size_t v = colon + 1;
  while (v < json.size() && (json[v] == ' ' || json[v] == '\t')) ++v;
  return json.compare(v, 4, "true") == 0;
}

}  // namespace

void Init() {
  g_enabled = ReadGate();
  if (!g_enabled) return;
  InitializeCriticalSection(&g_lock);
  QueryPerformanceFrequency(&g_qpc_freq);
  QueryPerformanceCounter(&g_qpc_origin);
  const std::wstring path = PrefsDir() + L"\\perf.log";
  g_file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                       nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (g_file == INVALID_HANDLE_VALUE) {
    g_enabled = false;
    return;
  }
  // Wall-clock header so runs can be correlated with external sampling
  // (SSH Get-Date / Get-Process timestamps). Marks are ms since this line.
  SYSTEMTIME st{};
  GetLocalTime(&st);
  char head[96];
  const int len = _snprintf_s(
      head, _TRUNCATE, "# launch %04u-%02u-%02u %02u:%02u:%02u.%03u\r\n",
      st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
      st.wMilliseconds);
  DWORD written = 0;
  if (len > 0) WriteFile(g_file, head, static_cast<DWORD>(len), &written, nullptr);
  Mark("launchBegin");
}

bool Enabled() { return g_enabled; }

void Mark(const std::string& label) {
  if (!g_enabled) return;
  LARGE_INTEGER now{};
  QueryPerformanceCounter(&now);
  const double ms = (now.QuadPart - g_qpc_origin.QuadPart) * 1000.0 /
                    static_cast<double>(g_qpc_freq.QuadPart);
  char line[512];
  const int len =
      _snprintf_s(line, _TRUNCATE, "%.3f %s\r\n", ms, label.c_str());
  if (len <= 0) return;
  EnterCriticalSection(&g_lock);
  DWORD written = 0;
  WriteFile(g_file, line, static_cast<DWORD>(len), &written, nullptr);
  LeaveCriticalSection(&g_lock);
}

}  // namespace perf
