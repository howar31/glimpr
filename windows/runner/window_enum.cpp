#include "window_enum.h"

#include <dwmapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <string>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

double MonitorScale(HMONITOR mon) {
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  return dpi_x / 96.0;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                      s.data(), n, nullptr, nullptr);
  return s;
}

std::string WindowTitle(HWND hwnd) {
  int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) return {};
  std::wstring buf(static_cast<size_t>(len) + 1, L'\0');
  int got = GetWindowTextW(hwnd, buf.data(), len + 1);
  buf.resize(static_cast<size_t>(got));
  return Utf8(buf);
}

std::string ProcessName(HWND hwnd) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (!pid) return {};
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return {};
  std::string name;
  wchar_t path[MAX_PATH] = {};
  DWORD sz = MAX_PATH;
  if (QueryFullProcessImageNameW(h, 0, path, &sz)) {
    std::wstring p(path, sz);
    size_t slash = p.find_last_of(L"\\/");
    std::wstring base = (slash == std::wstring::npos) ? p : p.substr(slash + 1);
    if (base.size() > 4 &&
        _wcsicmp(base.c_str() + base.size() - 4, L".exe") == 0) {
      base = base.substr(0, base.size() - 4);
    }
    name = Utf8(base);
  }
  CloseHandle(h);
  return name;
}

bool IsCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked)))) {
    return cloaked != 0;
  }
  return false;
}

RECT VisibleBounds(HWND hwnd) {
  RECT rc{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc,
                                   sizeof(rc)))) {
    GetWindowRect(hwnd, &rc);
  }
  return rc;
}

struct EnumCtx {
  RECT monitor;        // physical
  double scale;
  const std::vector<HWND>* overlays;
  EncodableList* out;  // front-to-back (EnumWindows order)
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lp) {
  auto* ctx = reinterpret_cast<EnumCtx*>(lp);
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
  if (IsCloaked(hwnd)) return TRUE;
  // Only our own freeze overlays are excluded; glimpr's normal windows
  // (Settings / editor) are snappable, matching macOS.
  if (std::find(ctx->overlays->begin(), ctx->overlays->end(), hwnd) !=
      ctx->overlays->end()) {
    return TRUE;
  }
  // Skip tool windows (palettes / our own helper windows) and zero-size.
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if (ex & WS_EX_TOOLWINDOW) return TRUE;

  RECT r = VisibleBounds(hwnd);
  if (r.right - r.left < 40 || r.bottom - r.top < 40) return TRUE;

  RECT inter{};
  if (!IntersectRect(&inter, &r, &ctx->monitor)) return TRUE;
  if (inter.right - inter.left < 1 || inter.bottom - inter.top < 1) return TRUE;

  const double scale = ctx->scale;
  EncodableMap w;
  w[EncodableValue("x")] =
      EncodableValue((inter.left - ctx->monitor.left) / scale);
  w[EncodableValue("y")] =
      EncodableValue((inter.top - ctx->monitor.top) / scale);
  w[EncodableValue("w")] = EncodableValue((inter.right - inter.left) / scale);
  w[EncodableValue("h")] = EncodableValue((inter.bottom - inter.top) / scale);
  w[EncodableValue("title")] = EncodableValue(WindowTitle(hwnd));
  w[EncodableValue("app")] = EncodableValue(ProcessName(hwnd));
  w[EncodableValue("windowNumber")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hwnd)));
  ctx->out->push_back(EncodableValue(std::move(w)));
  return TRUE;
}

}  // namespace

namespace win_enum {

EncodableList SnappableWindows(HMONITOR mon,
                               const std::vector<HWND>& overlays) {
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(mon, &mi)) return {};
  EncodableList out;
  EnumCtx ctx{mi.rcMonitor, MonitorScale(mon), &overlays, &out};
  EnumWindows(EnumProc, reinterpret_cast<LPARAM>(&ctx));
  return out;
}

}  // namespace win_enum
