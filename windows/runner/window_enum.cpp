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

// Append one display-local logical entry to the snap list. [title]/[app] for
// child-control entries are the top-level window's (a child's own text, e.g.
// Chrome's "Chrome Legacy Window", is useless for the %title filename).
void AppendEntry(EnumCtx* ctx, HWND hwnd, const RECT& physical,
                 const std::string& title, const std::string& app) {
  RECT inter{};
  if (!IntersectRect(&inter, &physical, &ctx->monitor)) return;
  if (inter.right - inter.left < 1 || inter.bottom - inter.top < 1) return;
  const double scale = ctx->scale;
  EncodableMap w;
  w[EncodableValue("x")] =
      EncodableValue((inter.left - ctx->monitor.left) / scale);
  w[EncodableValue("y")] =
      EncodableValue((inter.top - ctx->monitor.top) / scale);
  w[EncodableValue("w")] = EncodableValue((inter.right - inter.left) / scale);
  w[EncodableValue("h")] = EncodableValue((inter.bottom - inter.top) / scale);
  w[EncodableValue("title")] = EncodableValue(title);
  w[EncodableValue("app")] = EncodableValue(app);
  w[EncodableValue("windowNumber")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hwnd)));
  ctx->out->push_back(EncodableValue(std::move(w)));
}

BOOL CALLBACK EnumProc(HWND hwnd, LPARAM lp) {
  auto* ctx = reinterpret_cast<EnumCtx*>(lp);
  // Only our own freeze overlays are excluded; glimpr's normal windows
  // (Settings / editor) are snappable, matching macOS.
  RECT r{};
  if (!SnappableWindow(hwnd, *ctx->overlays, &r)) return TRUE;

  const std::string title = WindowTitle(hwnd);
  const std::string app = ProcessName(hwnd);

  // ShareX-parity control detection (WindowsRectangleList.IncludeChildWindows):
  // every visible descendant HWND is a snap target too -- that is how ShareX
  // frames e.g. Chrome's page area without the tab bar / toolbar (the render
  // host child window). Children are appended BEFORE their top-level window,
  // smallest first, so topmostWindowAt's first-containing scan picks the most
  // specific rect; z-ordering across windows is preserved by the outer
  // front-to-back EnumWindows. Rects are clipped to the parent (a scrolled-out
  // child must not snap outside the window).
  struct Child {
    HWND hwnd;
    RECT rect;
  };
  struct ChildCtx {
    RECT parent;
    std::vector<Child> out;
  } cc{r, {}};
  EnumChildWindows(
      hwnd,
      [](HWND child, LPARAM lp2) -> BOOL {
        auto* c = reinterpret_cast<ChildCtx*>(lp2);
        if (!IsWindowVisible(child)) return TRUE;
        RECT cr{};
        if (!GetWindowRect(child, &cr)) return TRUE;
        RECT inter{};
        if (!IntersectRect(&inter, &cr, &c->parent)) return TRUE;
        // Skip degenerate slivers; anything with real area is a target
        // (ShareX includes small controls too).
        if (inter.right - inter.left < 8 || inter.bottom - inter.top < 8) {
          return TRUE;
        }
        // A child covering (nearly) the whole window adds nothing over the
        // window entry itself and would shadow it in the first-containing
        // scan order below.
        if (EqualRect(&inter, &c->parent)) return TRUE;
        c->out.push_back({child, inter});
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&cc));
  std::stable_sort(cc.out.begin(), cc.out.end(),
                   [](const Child& a, const Child& b) {
                     const LONG64 aa =
                         static_cast<LONG64>(a.rect.right - a.rect.left) *
                         (a.rect.bottom - a.rect.top);
                     const LONG64 bb =
                         static_cast<LONG64>(b.rect.right - b.rect.left) *
                         (b.rect.bottom - b.rect.top);
                     return aa < bb;
                   });
  for (const Child& c : cc.out) AppendEntry(ctx, c.hwnd, c.rect, title, app);

  // The client area (window minus caption/borders) as its own target, like
  // ShareX's client-rect entry. Skipped when it equals the window rect
  // (borderless / custom-frame apps).
  RECT client{};
  if (GetClientRect(hwnd, &client)) {
    POINT tl{client.left, client.top};
    POINT br{client.right, client.bottom};
    if (ClientToScreen(hwnd, &tl) && ClientToScreen(hwnd, &br)) {
      RECT screen_client{tl.x, tl.y, br.x, br.y};
      if (!EqualRect(&screen_client, &r) &&
          screen_client.right - screen_client.left > 0 &&
          screen_client.bottom - screen_client.top > 0) {
        AppendEntry(ctx, hwnd, screen_client, title, app);
      }
    }
  }

  AppendEntry(ctx, hwnd, r, title, app);
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
