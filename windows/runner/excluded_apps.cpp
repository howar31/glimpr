#include "excluded_apps.h"

#include <dwmapi.h>
#include <shellapi.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <cwchar>
#include <initializer_list>
#include <mutex>
#include <unordered_map>
#include <utility>

#include "image_codec.h"
#include "prefs_probe.h"
#include "process_identity.h"
#include "utils.h"
#include "wgc_capturer.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr char kPrefKey[] = "excluded_apps";
constexpr char kEnabledKey[] = "excluded_apps_enabled";
constexpr char kOwnWindowsKey[] = "exclude_own_windows";
// Glimpr windows the own-windows setting applies to (the Flutter-hosted
// windows and pins). Windows that manage their own capture affinity, such as
// the capture overlay and recording chrome, are left alone.
constexpr wchar_t kFlutterWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kPinWindowClass[] = L"GLIMPR_PIN_WINDOW";
constexpr ULONGLONG kListTtlMs = 1000;
constexpr int kIconSide = 48;

bool IsCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                         sizeof(cloaked))) &&
         cloaked != 0;
}

RECT VisibleBounds(HWND hwnd) {
  RECT rc{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc,
                                   sizeof(rc)))) {
    GetWindowRect(hwnd, &rc);
  }
  return rc;
}

std::wstring ClassOf(HWND hwnd) {
  wchar_t cls[96] = L"";
  GetClassNameW(hwnd, cls, 96);
  return cls;
}

// The desktop and taskbar are full-screen surfaces of the shell process; they
// never count as an application's windows, or listing the shell would black
// out the whole screen.
bool IsShellSurface(const std::wstring& cls) {
  return cls == L"Progman" || cls == L"WorkerW" || cls == L"Shell_TrayWnd" ||
         cls == L"Shell_SecondaryTrayWnd";
}

std::wstring ExePathOfPid(DWORD pid) {
  if (!pid) return {};
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return {};
  wchar_t path[1024] = {};
  DWORD size = 1024;
  std::wstring out;
  if (QueryFullProcessImageNameW(h, 0, path, &size)) out.assign(path, size);
  CloseHandle(h);
  return out;
}

// The process that owns a window's content. A packaged app's top-level frame
// belongs to a shared host process; its content window carries the real one.
DWORD ContentPid(HWND hwnd, const std::wstring& cls) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (cls != L"ApplicationFrameWindow") return pid;
  struct Ctx {
    DWORD host;
    DWORD found;
  } ctx{pid, 0};
  EnumChildWindows(
      hwnd,
      [](HWND child, LPARAM lp) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(lp);
        DWORD child_pid = 0;
        GetWindowThreadProcessId(child, &child_pid);
        if (child_pid && child_pid != c->host) {
          c->found = child_pid;
          return FALSE;
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ctx));
  return ctx.found ? ctx.found : pid;
}

std::wstring ExePathOfWindow(HWND hwnd, const std::wstring& cls) {
  return ExePathOfPid(ContentPid(hwnd, cls));
}

struct CollectCtx {
  const std::vector<capmask::Entry>* list;
  bool own_windows_cover;
  DWORD self;
  std::unordered_map<DWORD, const capmask::Entry*> entry_by_pid;
  std::vector<capmask::Window> out;
};

BOOL CALLBACK CollectProc(HWND hwnd, LPARAM lp) {
  auto* ctx = reinterpret_cast<CollectCtx*>(lp);
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsCloaked(hwnd)) return TRUE;
  if (excluded::LeftOutOfCapture(hwnd)) return TRUE;
  capmask::Window w;
  w.rect = VisibleBounds(hwnd);
  if (w.rect.right <= w.rect.left || w.rect.bottom <= w.rect.top) return TRUE;

  const std::wstring cls = ClassOf(hwnd);
  const DWORD pid = ContentPid(hwnd, cls);
  if (!IsShellSurface(cls)) {
    auto it = ctx->entry_by_pid.find(pid);
    if (it == ctx->entry_by_pid.end()) {
      it = ctx->entry_by_pid
               .emplace(pid, capmask::Find(*ctx->list, ExePathOfPid(pid)))
               .first;
    }
    if (it->second) {
      w.listed = true;
      w.blur = it->second->blur;
    }
  }
  const LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  w.opaque = (ex & (WS_EX_LAYERED | WS_EX_TRANSPARENT)) == 0;
  if (pid == ctx->self && !ctx->own_windows_cover) w.opaque = false;
  ctx->out.push_back(w);
  return TRUE;
}

std::vector<capmask::Window> Collect(const std::vector<capmask::Entry>& list,
                                     bool own_windows_cover) {
  CollectCtx ctx{&list, own_windows_cover, GetCurrentProcessId(), {}, {}};
  EnumWindows(CollectProc, reinterpret_cast<LPARAM>(&ctx));
  return std::move(ctx.out);
}

std::wstring NativePath(std::wstring id) {
  std::replace(id.begin(), id.end(), L'/', L'\\');
  return id;
}

std::wstring BaseName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  std::wstring base =
      (slash == std::wstring::npos) ? path : path.substr(slash + 1);
  if (base.size() > 4 &&
      _wcsicmp(base.c_str() + base.size() - 4, L".exe") == 0) {
    base.resize(base.size() - 4);
  }
  return base;
}

// The exe's FileDescription version string, or "".
std::wstring FileDescription(const std::wstring& path) {
  DWORD handle = 0;
  const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &handle);
  if (!size) return {};
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return {};
  struct Translation {
    WORD language;
    WORD code_page;
  };
  Translation* tr = nullptr;
  UINT tr_len = 0;
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                      reinterpret_cast<LPVOID*>(&tr), &tr_len) ||
      !tr || tr_len < sizeof(Translation)) {
    return {};
  }
  wchar_t key[64] = {};
  swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\FileDescription",
             tr[0].language, tr[0].code_page);
  wchar_t* value = nullptr;
  UINT value_len = 0;
  if (!VerQueryValueW(data.data(), key, reinterpret_cast<LPVOID*>(&value),
                      &value_len) ||
      !value || value_len == 0) {
    return {};
  }
  return std::wstring(value);
}

// The file's shell icon as PNG bytes; empty when it cannot be drawn.
std::vector<uint8_t> IconPng(const std::wstring& path) {
  SHFILEINFOW info{};
  if (!SHGetFileInfoW(path.c_str(), 0, &info, sizeof(info),
                      SHGFI_ICON | SHGFI_LARGEICON) ||
      !info.hIcon) {
    return {};
  }
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = kIconSide;
  bi.bmiHeader.biHeight = -kIconSide;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(screen);
  HBITMAP dib = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  std::vector<uint8_t> png;
  if (dib && bits) {
    const size_t bytes = static_cast<size_t>(kIconSide) * kIconSide * 4;
    HGDIOBJ old = SelectObject(mem, dib);
    std::memset(bits, 0, bytes);
    DrawIconEx(mem, 0, 0, info.hIcon, kIconSide, kIconSide, 0, nullptr,
               DI_NORMAL);
    SelectObject(mem, old);
    GdiFlush();
    png = codec::EncodePng(static_cast<const uint8_t*>(bits), kIconSide,
                           kIconSide, kIconSide * 4);
  }
  if (dib) DeleteObject(dib);
  DeleteDC(mem);
  ReleaseDC(nullptr, screen);
  DestroyIcon(info.hIcon);
  return png;
}

EncodableValue Entry(const std::wstring& id) {
  const std::wstring path = NativePath(id);
  EncodableMap e;
  e[EncodableValue("id")] = EncodableValue(Utf8FromUtf16(id));
  const bool exists = GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
  std::wstring name;
  if (exists) {
    name = FileDescription(path);
    if (name.empty()) name = BaseName(path);
  }
  e[EncodableValue("name")] =
      EncodableValue(Utf8FromUtf16(name.empty() ? id : name));
  if (exists) {
    std::vector<uint8_t> png = IconPng(path);
    if (!png.empty()) e[EncodableValue("icon")] = EncodableValue(std::move(png));
  }
  return EncodableValue(std::move(e));
}

}  // namespace

namespace excluded {

namespace {

struct Stored {
  std::vector<capmask::Entry> list;
  bool own_windows = false;
};

// The settings this unit reads, cached for kListTtlMs. [force] re-reads now.
Stored Load(bool force) {
  static std::mutex mu;
  static Stored cached;
  static ULONGLONG read_at = 0;
  static bool loaded = false;
  const ULONGLONG now = GetTickCount64();
  std::lock_guard<std::mutex> lock(mu);
  if (force || !loaded || now - read_at > kListTtlMs) {
    const std::string json = prefs::ReadPrefsJson();
    // The master switch (absent = on) leaves the stored list in place.
    cached.list = prefs::JsonBoolValue(json, kEnabledKey, true)
                      ? capmask::ParseList(Utf16FromUtf8(
                            prefs::JsonStringValue(json, kPrefKey)))
                      : std::vector<capmask::Entry>();
    cached.own_windows = prefs::JsonBoolValue(json, kOwnWindowsKey, false);
    read_at = now;
    loaded = true;
  }
  return cached;
}

std::atomic<bool> g_snap_covers_screenshot{true};

}  // namespace

std::vector<capmask::Entry> List() { return Load(false).list; }

std::vector<capmask::Entry> SnapList() {
  return g_snap_covers_screenshot.load() ? List()
                                         : std::vector<capmask::Entry>();
}

void SetSnapCoversScreenshot(bool screenshot) {
  g_snap_covers_screenshot.store(screenshot);
}

bool IsListed(HWND hwnd, const std::vector<capmask::Entry>& list) {
  if (list.empty() || !hwnd) return false;
  const std::wstring cls = ClassOf(hwnd);
  if (IsShellSurface(cls)) return false;
  return capmask::IsListed(list, ExePathOfWindow(hwnd, cls));
}

bool LeftOutOfCapture(HWND hwnd) {
  DWORD affinity = 0;
  return GetWindowDisplayAffinity(hwnd, &affinity) && affinity != WDA_NONE;
}

void ApplyOwnWindowAffinity(HWND hwnd, bool reset_when_off) {
  if (!hwnd) return;
  if (Load(reset_when_off).own_windows) {
    SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
  } else if (reset_when_off) {
    SetWindowDisplayAffinity(hwnd, WDA_NONE);
  }
}

void ReapplyOwnWindowAffinity() {
  Load(true);
  EnumWindows(
      [](HWND hwnd, LPARAM) -> BOOL {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid != GetCurrentProcessId()) return TRUE;
        const std::wstring cls = ClassOf(hwnd);
        if (cls == kFlutterWindowClass || cls == kPinWindowClass) {
          ApplyOwnWindowAffinity(hwnd, /*reset_when_off=*/true);
        }
        return TRUE;
      },
      0);
}

Mask::Mask(bool own_windows_cover)
    : list_(List()), own_windows_cover_(own_windows_cover) {
  if (active()) before_ = Collect(list_, own_windows_cover_);
}

void Mask::Resample() {
  if (active()) after_ = Collect(list_, own_windows_cover_);
}

void Mask::Apply(CaptureFrame* frame, const RECT& bounds) const {
  if (!active() || !frame || frame->bgra.empty()) return;
  // A window that did not move yields the same areas in both samples; each
  // distinct area is covered once (the blur is the costly one).
  std::vector<capmask::MaskRect> areas = capmask::MaskRects(before_, bounds);
  for (const capmask::MaskRect& m : capmask::MaskRects(after_, bounds)) {
    bool seen = false;
    for (const capmask::MaskRect& have : areas) {
      if (have.blur == m.blur && EqualRect(&have.rect, &m.rect)) seen = true;
    }
    if (!seen) areas.push_back(m);
  }
  // Blur first, black last: where both land on the same pixels the stricter
  // cover wins.
  for (const bool blur : {true, false}) {
    for (const capmask::MaskRect& m : areas) {
      if (m.blur != blur) continue;
      const RECT local{m.rect.left - bounds.left, m.rect.top - bounds.top,
                       m.rect.right - bounds.left, m.rect.bottom - bounds.top};
      if (blur) {
        capmask::BlurBgra(frame->bgra.data(), frame->width, frame->height,
                          frame->stride, local);
        if (!frame->f16.empty()) {
          capmask::BlurF16(frame->f16.data(), frame->width, frame->height,
                           local);
        }
      } else {
        capmask::FillBgra(frame->bgra.data(), frame->width, frame->height,
                          frame->stride, local);
        if (!frame->f16.empty()) {
          capmask::FillF16(frame->f16.data(), frame->width, frame->height,
                           local);
        }
      }
    }
  }
}

EncodableList RunningApps() {
  struct Ctx {
    std::vector<std::wstring> ids;
  } ctx;
  EnumWindows(
      [](HWND hwnd, LPARAM lp) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(lp);
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || IsCloaked(hwnd)) {
          return TRUE;
        }
        const RECT r = VisibleBounds(hwnd);
        if (r.right - r.left < 8 || r.bottom - r.top < 8) return TRUE;
        const std::wstring cls = ClassOf(hwnd);
        if (IsShellSurface(cls)) return TRUE;
        const DWORD pid = ContentPid(hwnd, cls);
        if (procid::IsOurProcess(pid)) return TRUE;
        const std::wstring path = ExePathOfPid(pid);
        if (path.empty()) return TRUE;
        std::wstring id = capmask::NormalizePath(path);
        if (std::find(c->ids.begin(), c->ids.end(), id) == c->ids.end()) {
          c->ids.push_back(std::move(id));
        }
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ctx));
  EncodableList out;
  for (const std::wstring& id : ctx.ids) out.push_back(Entry(id));
  return out;
}

EncodableList Resolve(const std::vector<std::string>& ids) {
  EncodableList out;
  for (const std::string& id : ids) {
    out.push_back(Entry(capmask::NormalizePath(Utf16FromUtf8(id))));
  }
  return out;
}

}  // namespace excluded
