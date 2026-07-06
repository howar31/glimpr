#include "window_enum.h"

#include <dwmapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <string>

#include "dpi_util.h"
#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

using win_enum::ProcessName;
using win_enum::WindowTitle;

bool IsCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  if (SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                      sizeof(cloaked)))) {
    return cloaked != 0;
  }
  return false;
}

// Whether [hwnd] passes the shared snappable-window filters (visible,
// non-minimized, non-cloaked, not a tool window, at least 40 px on a side),
// excluding our own freeze [overlays]. Shared by SnappableWindows' collector
// and TopWindowAt's hit test; [bounds] receives the DWM visible bounds.
bool SnappableWindow(HWND hwnd, const std::vector<HWND>& overlays,
                     RECT* bounds) {
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return false;
  if (IsCloaked(hwnd)) return false;
  if (std::find(overlays.begin(), overlays.end(), hwnd) != overlays.end()) {
    return false;
  }
  if (GetWindowLongPtr(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) return false;
  const RECT r = win_enum::VisibleWindowBounds(hwnd);
  if (r.right - r.left < 40 || r.bottom - r.top < 40) return false;
  *bounds = r;
  return true;
}

struct EnumCtx {
  RECT monitor;        // physical
  double scale;
  const std::vector<HWND>* overlays;
  EncodableList* out;  // front-to-back (EnumWindows order)
};

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lp) {
  auto* ctx = reinterpret_cast<EnumCtx*>(lp);
  // Only our own freeze overlays are excluded; glimpr's normal windows
  // (Settings / editor) are snappable, matching macOS.
  RECT r{};
  if (!SnappableWindow(hwnd, *ctx->overlays, &r)) return TRUE;

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

std::string WindowTitle(HWND hwnd) {
  int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) return {};
  std::wstring buf(static_cast<size_t>(len) + 1, L'\0');
  int got = GetWindowTextW(hwnd, buf.data(), len + 1);
  buf.resize(static_cast<size_t>(got));
  return Utf8FromUtf16(buf);
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
    name = Utf8FromUtf16(base);
  }
  CloseHandle(h);
  return name;
}

RECT VisibleWindowBounds(HWND hwnd) {
  RECT rc{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc,
                                   sizeof(rc)))) {
    GetWindowRect(hwnd, &rc);
  }
  return rc;
}

HWND TopWindowAt(POINT pt, const std::vector<HWND>& overlays) {
  struct Ctx {
    POINT pt;
    const std::vector<HWND>* overlays;
    HWND out;
  } ctx{pt, &overlays, nullptr};
  EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(lp);
        RECT r{};
        if (!SnappableWindow(hwnd, *c->overlays, &r)) return TRUE;
        if (!PtInRect(&r, c->pt)) return TRUE;
        c->out = hwnd;  // front-to-back: the first hit is the visual top
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&ctx));
  return ctx.out;
}

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
