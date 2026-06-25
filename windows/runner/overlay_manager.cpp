#include "overlay_manager.h"

#include <shellscalingapi.h>

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <cmath>
#include <set>
#include <string>
#include <thread>

#include "cursor_image.h"
#include "image_codec.h"
#include "wgc_capturer.h"
#include "window_enum.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

inline int64_t MonId(HMONITOR m) {
  return static_cast<int64_t>(reinterpret_cast<intptr_t>(m));
}
inline HMONITOR HMon(int64_t id) {
  return reinterpret_cast<HMONITOR>(static_cast<intptr_t>(id));
}

double MonitorScale(HMONITOR mon) {
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  return dpi_x / 96.0;
}

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool GetBool(const EncodableMap& map, const char* key, bool dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<bool>(v)) return *p;
  }
  return dflt;
}

double GetDouble(const EncodableMap& map, const char* key, double dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return static_cast<double>(*p);
    if (auto p = std::get_if<int64_t>(v)) return static_cast<double>(*p);
  }
  return dflt;
}

std::string GetString(const EncodableMap& map, const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<std::string>(v)) return *p;
  }
  return {};
}

std::wstring Wide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(),
                              static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      w.data(), n);
  return w;
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

BOOL CALLBACK CollectMonitor(HMONITOR mon, HDC, LPRECT, LPARAM lp) {
  reinterpret_cast<std::vector<HMONITOR>*>(lp)->push_back(mon);
  return TRUE;
}

std::vector<HMONITOR> EnumerateMonitors() {
  std::vector<HMONITOR> out;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&out));
  return out;
}

int CALLBACK FontFamilyProc(const LOGFONTW* lf, const TEXTMETRICW*, DWORD,
                            LPARAM lp) {
  auto* set = reinterpret_cast<std::set<std::wstring>*>(lp);
  // Skip the '@' vertical-writing duplicates.
  if (lf->lfFaceName[0] != L'@') set->insert(lf->lfFaceName);
  return 1;
}

EncodableValue EnumerateFontFamilies() {
  HDC hdc = GetDC(nullptr);
  LOGFONTW lf{};
  lf.lfCharSet = DEFAULT_CHARSET;
  std::set<std::wstring> families;
  EnumFontFamiliesExW(hdc, &lf, FontFamilyProc,
                      reinterpret_cast<LPARAM>(&families), 0);
  ReleaseDC(nullptr, hdc);
  EncodableList list;
  for (const auto& f : families) list.push_back(EncodableValue(Utf8(f)));
  return EncodableValue(std::move(list));
}

std::unique_ptr<EncodableValue> Args(EncodableMap m) {
  return std::make_unique<EncodableValue>(EncodableValue(std::move(m)));
}

}  // namespace

OverlayManager* OverlayManager::instance_ = nullptr;

OverlayManager::OverlayManager(const flutter::DartProject& project,
                               HWND control_hwnd)
    : project_(project), control_hwnd_(control_hwnd) {
  instance_ = this;
}

OverlayManager::~OverlayManager() {
  StopCursorTracking();
  SetDrawingLock(0);
  SetCursorHidden(false);
  if (instance_ == this) instance_ = nullptr;
}

// ---- lifecycle ------------------------------------------------------------

void OverlayManager::SyncUnitsToScreens() {
  std::vector<HMONITOR> mons = EnumerateMonitors();
  std::set<int64_t> current;
  for (HMONITOR m : mons) {
    current.insert(MonId(m));
    EnsureUnit(m);
  }
  for (auto it = units_.begin(); it != units_.end();) {
    if (current.find(it->first) == current.end()) {
      it = units_.erase(it);
    } else {
      ++it;
    }
  }
}

OverlayManager::Unit* OverlayManager::EnsureUnit(HMONITOR mon) {
  int64_t id = MonId(mon);
  auto existing = units_.find(id);
  if (existing != units_.end()) return &existing->second;

  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(mon, &mi)) return nullptr;

  Unit unit;
  unit.display_id = id;
  unit.window = std::make_unique<OverlayWindow>();
  if (!unit.window->Create(project_, mi.rcMonitor)) return nullptr;
  RegisterUnitChannels(unit);
  auto inserted = units_.emplace(id, std::move(unit));
  return &inserted.first->second;
}

OverlayManager::Unit* OverlayManager::UnitFor(int64_t display_id) {
  auto it = units_.find(display_id);
  return it == units_.end() ? nullptr : &it->second;
}

void OverlayManager::RegisterUnitChannels(Unit& unit) {
  auto* msgr = unit.window->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  const int64_t id = unit.display_id;

  unit.role = std::make_unique<MethodChannel<EncodableValue>>(
      msgr, "glimpr/role", codec);
  unit.role->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getRole") {
          result->Success(EncodableValue("overlay"));
        } else {
          result->NotImplemented();
        }
      });

  unit.capture = std::make_unique<MethodChannel<EncodableValue>>(
      msgr, "glimpr/capture", codec);
  unit.capture->SetMethodCallHandler(
      [this, id](const auto& call, auto result) {
        HandleOverlayCapture(id, call, std::move(result));
      });

  // Native -> Dart only (onCaptureReady / onActiveDisplay / onEditorState ...).
  unit.overlay = std::make_unique<MethodChannel<EncodableValue>>(
      msgr, "glimpr/overlay", codec);

  unit.fonts = std::make_unique<MethodChannel<EncodableValue>>(
      msgr, "glimpr/fonts", codec);
  unit.fonts->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "availableFamilies") {
          result->Success(EnumerateFontFamilies());
        } else {
          result->NotImplemented();
        }
      });

  // Reuse the S2a clipboard seam (glimpr/clipboard.writeImage) on this engine.
  unit.clipboard = std::make_unique<ClipboardChannel>(msgr);
  // Native PNG/JPEG encode + Direct2D decoration for the annotated export (the
  // overlay composites on this engine), instead of the pure-Dart fallback.
  unit.encode = std::make_unique<EncodeChannel>(msgr);
}

// ---- present / show / dismiss --------------------------------------------

void OverlayManager::BeginCapture(bool pin_only, bool live_select) {
  SyncUnitsToScreens();
  POINT cursor{};
  GetCursorPos(&cursor);
  HMONITOR cursor_mon = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  const int64_t cursor_id = MonId(cursor_mon);
  PresentBegin(cursor_id);

  if (live_select) {
    // Recording live-select picker is deferred to S6; nothing to present.
    return;
  }

  std::vector<HMONITOR> mons = EnumerateMonitors();
  // Cursor display first (a valid strict-weak-ordering: "is-cursor" sorts ahead
  // of "is-not") so it is PRESENTED first, mirroring the macOS jobs.sort.
  std::stable_sort(mons.begin(), mons.end(),
                   [cursor_id](HMONITOR a, HMONITOR b) {
                     return (MonId(a) == cursor_id) && (MonId(b) != cursor_id);
                   });

  // Capture every monitor IN PARALLEL -- each worker has its OWN WinRT MTA + D3D
  // device + frame pool (no shared state), so a multi-display freeze is not
  // staggered across displays (mirrors macOS's parallel captureAll). The present
  // (onCaptureReady) stays on this platform thread, cursor display first.
  std::vector<std::optional<CaptureFrame>> frames(mons.size());
  {
    std::vector<std::thread> workers;
    workers.reserve(mons.size());
    for (size_t i = 0; i < mons.size(); ++i) {
      workers.emplace_back([&frames, &mons, i]() {
        try {
          winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }
        frames[i] = wgc::CaptureMonitor(mons[i], false);
        winrt::uninit_apartment();
      });
    }
    for (auto& t : workers) t.join();
  }
  for (size_t i = 0; i < mons.size(); ++i) {
    if (!frames[i]) continue;
    const bool is_cursor = (MonId(mons[i]) == cursor_id);
    EncodableMap dict =
        BuildDisplayDict(mons[i], std::move(*frames[i]), is_cursor, cursor);
    PresentFrame(MonId(mons[i]), std::move(dict), pin_only, live_select);
  }
}

EncodableMap OverlayManager::BuildDisplayDict(HMONITOR mon, CaptureFrame frame,
                                              bool is_cursor,
                                              POINT cursor_global) {
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonitorScale(mon);
  const double left = mi.rcMonitor.left / scale;
  const double top = mi.rcMonitor.top / scale;
  const double width = (mi.rcMonitor.right - mi.rcMonitor.left) / scale;
  const double height = (mi.rcMonitor.bottom - mi.rcMonitor.top) / scale;

  EncodableMap d;
  d[EncodableValue("displayId")] = EncodableValue(MonId(mon));
  d[EncodableValue("left")] = EncodableValue(left);
  d[EncodableValue("top")] = EncodableValue(top);
  d[EncodableValue("width")] = EncodableValue(width);
  d[EncodableValue("height")] = EncodableValue(height);
  d[EncodableValue("scaleFactor")] = EncodableValue(scale);
  d[EncodableValue("isCursorDisplay")] = EncodableValue(is_cursor);
  if (is_cursor) {
    const double cursor_x = (cursor_global.x - mi.rcMonitor.left) / scale;
    const double cursor_y = (cursor_global.y - mi.rcMonitor.top) / scale;
    d[EncodableValue("cursorX")] = EncodableValue(cursor_x);
    d[EncodableValue("cursorY")] = EncodableValue(cursor_y);
    // The OS cursor image for the overlay's toggleable pointer layer: a native-px
    // PNG + its display-local logical top-left (cursor minus hotspot). The frozen
    // frame itself is captured WITHOUT the cursor. Absent for unrenderable cursors.
    if (auto cur = cursorimg::Capture()) {
      auto png = codec::EncodePng(cur->bgra.data(), cur->width, cur->height,
                                  cur->width * 4);
      if (!png.empty()) {
        d[EncodableValue("cursorImage")] = EncodableValue(std::move(png));
        d[EncodableValue("cursorLeft")] =
            EncodableValue(cursor_x - cur->hotspot_x / scale);
        d[EncodableValue("cursorTop")] =
            EncodableValue(cursor_y - cur->hotspot_y / scale);
      }
    }
  }
  d[EncodableValue("pixelWidth")] = EncodableValue(static_cast<int64_t>(frame.width));
  d[EncodableValue("pixelHeight")] = EncodableValue(static_cast<int64_t>(frame.height));
  d[EncodableValue("rowBytes")] = EncodableValue(static_cast<int64_t>(frame.stride));
  d[EncodableValue("windows")] =
      EncodableValue(win_enum::SnappableWindows(mon, OverlayHwnds()));
  // Move the BGRA buffer into the reply (never copied).
  d[EncodableValue("rawBytes")] = EncodableValue(std::move(frame.bgra));
  return d;
}

std::vector<HWND> OverlayManager::OverlayHwnds() const {
  std::vector<HWND> out;
  for (const auto& kv : units_) {
    if (kv.second.window) out.push_back(kv.second.window->hwnd());
  }
  return out;
}

void OverlayManager::PresentBegin(int64_t cursor_display_id) {
  key_display_id_ = cursor_display_id;
  StartCursorTracking();
}

void OverlayManager::PresentFrame(int64_t display_id, EncodableMap dict,
                                  bool pin_only, bool live_select) {
  Unit* u = UnitFor(display_id);
  if (!u || !u->overlay) return;
  EncodableMap args;
  args[EncodableValue("display")] = EncodableValue(std::move(dict));
  args[EncodableValue("pinOnly")] = EncodableValue(pin_only);
  args[EncodableValue("liveSelect")] = EncodableValue(live_select);
  u->overlay->InvokeMethod("onCaptureReady", Args(std::move(args)));
}

void OverlayManager::Show(int64_t display_id) {
  Unit* u = UnitFor(display_id);
  if (!u || !u->window) return;
  HMONITOR mon = HMon(display_id);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!GetMonitorInfo(mon, &mi)) return;
  const bool activate =
      (display_id == key_display_id_) || key_display_id_ == 0;
  u->window->Show(mi.rcMonitor, activate);

  // If the cursor is ALREADY on this display, claim active now. The user may
  // have moved here during the capture latency, before this display's editor
  // existed to receive the active handoff -- the cursor poll sent onActiveDisplay
  // to a not-yet-mounted EditorCanvas (lost), then its dedup (active == this)
  // suppressed a resend, so the crosshair would not track until the cursor left
  // and re-entered. Re-assert now that the window + editor are ready.
  POINT pt{};
  GetCursorPos(&pt);
  if (MonId(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST)) == display_id) {
    SetActiveDisplay(display_id, pt);
  }
}

void OverlayManager::Hide(int64_t display_id) {
  Unit* u = UnitFor(display_id);
  if (u && u->window) u->window->Hide();
}

void OverlayManager::DismissAll() {
  StopCursorTracking();
  SetCursorHidden(false);
  SetDrawingLock(0);
  for (auto& kv : units_) {
    if (kv.second.window) kv.second.window->Hide();
  }
}

// ---- cursor poll / active display ----------------------------------------

void OverlayManager::StartCursorTracking() {
  active_display_id_ = key_display_id_;
  if (cursor_timer_) KillTimer(nullptr, cursor_timer_);
  // ~125 Hz, matching the macOS 1/120 s poll.
  cursor_timer_ = SetTimer(nullptr, 0, 8, &OverlayManager::TimerProc);
}

void OverlayManager::StopCursorTracking() {
  if (cursor_timer_) {
    KillTimer(nullptr, cursor_timer_);
    cursor_timer_ = 0;
  }
  active_display_id_ = 0;
}

// static
void CALLBACK OverlayManager::TimerProc(HWND, UINT, UINT_PTR, DWORD) {
  if (instance_) instance_->TickCursor();
}

void OverlayManager::TickCursor() {
  if (drawing_lock_id_ != 0) {
    ConfineToDrawingDisplay();
    return;
  }
  POINT pt{};
  GetCursorPos(&pt);
  HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  const int64_t id = MonId(mon);
  if (id == 0 || !UnitFor(id) || id == active_display_id_) return;
  SetActiveDisplay(id, pt);
}

void OverlayManager::SetActiveDisplay(int64_t display_id, POINT global) {
  active_display_id_ = display_id;
  Unit* u = UnitFor(display_id);
  if (!u) return;
  if (u->window) u->window->SetForeground();
  HMONITOR mon = HMon(display_id);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonitorScale(mon);
  const double lx = (global.x - mi.rcMonitor.left) / scale;
  const double ly = (global.y - mi.rcMonitor.top) / scale;
  for (auto& kv : units_) {
    if (!kv.second.overlay) continue;
    EncodableMap a;
    a[EncodableValue("activeId")] = EncodableValue(display_id);
    a[EncodableValue("cursorX")] = EncodableValue(lx);
    a[EncodableValue("cursorY")] = EncodableValue(ly);
    kv.second.overlay->InvokeMethod("onActiveDisplay", Args(std::move(a)));
  }
}

// ---- drawing lock / warp / cursor hide -----------------------------------

void OverlayManager::SetDrawingLock(int64_t display_id_or_zero) {
  if (display_id_or_zero != 0) {
    drawing_lock_id_ = display_id_or_zero;
    ConfineToDrawingDisplay();
  } else {
    if (drawing_lock_id_ != 0) ClipCursor(nullptr);
    drawing_lock_id_ = 0;
  }
}

void OverlayManager::ConfineToDrawingDisplay() {
  if (drawing_lock_id_ == 0) return;
  HMONITOR mon = HMon(drawing_lock_id_);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (GetMonitorInfo(mon, &mi)) ClipCursor(&mi.rcMonitor);
}

void OverlayManager::WarpCursor(double logical_global_x,
                                double logical_global_y) {
  // The warp targets the active (or drawing-lock) display during a keyboard
  // nudge; global-logical * that display's scale recovers physical pixels.
  int64_t id = drawing_lock_id_ ? drawing_lock_id_ : active_display_id_;
  HMONITOR mon = id ? HMon(id) : nullptr;
  const double scale = mon ? MonitorScale(mon) : 1.0;
  SetCursorPos(static_cast<int>(std::lround(logical_global_x * scale)),
               static_cast<int>(std::lround(logical_global_y * scale)));
}

void OverlayManager::SetCursorHidden(bool hidden) {
  if (hidden == cursor_hidden_) return;
  cursor_hidden_ = hidden;
  ShowCursor(hidden ? FALSE : TRUE);
}

// ---- broadcast ------------------------------------------------------------

void OverlayManager::BroadcastEditorState(int64_t from_display_id,
                                          const EncodableMap& args) {
  for (auto& kv : units_) {
    if (kv.first == from_display_id || !kv.second.overlay) continue;
    kv.second.overlay->InvokeMethod(
        "onEditorState", std::make_unique<EncodableValue>(EncodableValue(args)));
  }
}

// ---- the overlay engine's glimpr/capture handler --------------------------

void OverlayManager::HandleOverlayCapture(
    int64_t display_id, const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableMap empty;
  const auto* args_ptr = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& args = args_ptr ? *args_ptr : empty;

  if (method == "overlayReady") {
    // Reveal only AFTER the new frozen frame is actually presented, so the window
    // does not briefly flash the PREVIOUS capture's stale swapchain content (a
    // frame left dimmed by a crop scrim reads as a dark mask). ForceRedraw
    // guarantees a frame fires the one-shot next-frame callback.
    Unit* u = UnitFor(display_id);
    if (u && u->window && u->window->controller()) {
      const int64_t id = display_id;
      u->window->controller()->engine()->SetNextFrameCallback(
          [this, id]() { Show(id); });
      u->window->controller()->ForceRedraw();
    } else {
      Show(display_id);
    }
    result->Success();
    return;
  }
  if (method == "broadcastEditorState") {
    BroadcastEditorState(display_id, args);
    result->Success();
    return;
  }
  if (method == "dismissOverlay") {
    DismissAll();
    result->Success();
    return;
  }
  if (method == "hideOverlay") {
    Hide(display_id);
    result->Success();
    return;
  }
  if (method == "setDrawingLock") {
    SetDrawingLock(GetBool(args, "locked", false) ? display_id : 0);
    result->Success();
    return;
  }
  if (method == "setCursorHidden") {
    SetCursorHidden(GetBool(args, "hidden", false));
    result->Success();
    return;
  }
  if (method == "warpCursor") {
    WarpCursor(GetDouble(args, "x", 0.0), GetDouble(args, "y", 0.0));
    result->Success();
    return;
  }
  if (method == "openSettings") {
    // Simplified vs the macOS suspend-with-mask detour: dismiss the freeze and
    // raise the control (Settings) window. Route through the same reveal message
    // the tray / second-instance use so the control window's RevealControlWindow
    // (show + ForceRedraw + foreground) is the single reveal path.
    DismissAll();
    if (control_hwnd_) {
      static UINT reveal = RegisterWindowMessageW(L"GlimprRevealSettings");
      PostMessage(control_hwnd_, reveal, 0, 0);
    }
    result->Success();
    return;
  }
  if (method == "showError") {
    MessageBoxW(nullptr, Wide(GetString(args, "message")).c_str(), L"Glimpr",
                MB_OK | MB_ICONWARNING);
    result->Success();
    return;
  }
  // Booleans the Dart overlay path may query.
  if (method == "accessibilityTrusted") {
    result->Success(EncodableValue(false));
    return;
  }
  // Methods that are deferred on Windows (recording = S6, editor flows = S4,
  // element snap, pins/share, processing/perf marks, window-alpha snap mask,
  // loupe live feed): a safe null reply so the shared Dart degrades.
  if (method == "captureWindowImage" || method == "loupeSample" ||
      method == "elementSnapAt") {
    result->Success();  // null -> Dart falls back (rect snap / blank loupe)
    return;
  }
  if (method == "requestAccessibility" || method == "setProcessing" ||
      method == "perfMark" || method == "openInEditor" ||
      method == "shareSheet" || method == "pinImage" ||
      method == "recentChanged" || method == "recordSelection" ||
      method == "recordSelectHotkey" || method == "stopLoupeFeed") {
    result->Success();
    return;
  }
  result->NotImplemented();
}
