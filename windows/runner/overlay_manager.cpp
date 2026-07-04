#include "overlay_manager.h"

#include <shellscalingapi.h>
#include <dwmapi.h>

#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <cmath>
#include <set>
#include <string>
#include <thread>

#include "channel_args.h"
#include "cursor_image.h"
#include "utils.h"
#include "editor_window.h"
#include "hdr_compose.h"
#include "hdr_util.h"
#include "image_codec.h"
#include "perf_log.h"
#include "pin_window.h"
#include "wgc_capturer.h"
#include "win_reveal.h"
#include "window_enum.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace chanarg;

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
  // Cached: every overlay engine's font popover asks, and the installed set
  // effectively never changes within a session (restart picks up new fonts,
  // matching the macOS behaviour).
  static EncodableValue cached;
  static bool have_cached = false;
  if (have_cached) return cached;
  HDC hdc = GetDC(nullptr);
  LOGFONTW lf{};
  lf.lfCharSet = DEFAULT_CHARSET;
  std::set<std::wstring> families;
  EnumFontFamiliesExW(hdc, &lf, FontFamilyProc,
                      reinterpret_cast<LPARAM>(&families), 0);
  ReleaseDC(nullptr, hdc);
  EncodableList list;
  for (const auto& f : families)
    list.push_back(EncodableValue(Utf8FromUtf16(f)));
  cached = EncodableValue(std::move(list));
  have_cached = true;
  return cached;
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
  if (teardown_timer_) KillTimer(nullptr, teardown_timer_);
  if (present_watchdog_) KillTimer(nullptr, present_watchdog_);
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

  perf::Mark("engineWarmBegin id=" + std::to_string(id));
  Unit unit;
  unit.display_id = id;
  unit.window = std::make_unique<OverlayWindow>();
  if (!unit.window->Create(project_, mi.rcMonitor)) return nullptr;
  RegisterUnitChannels(unit);
  auto inserted = units_.emplace(id, std::move(unit));
  perf::Mark("engineWarmDone id=" + std::to_string(id));
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
        } else if (call.method_name() == "revealInExplorer") {
          if (const auto* a =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            auto it = a->find(flutter::EncodableValue(std::string("path")));
            if (it != a->end()) {
              if (const auto* p = std::get_if<std::string>(&it->second)) {
                RevealInExplorer(*p);
              }
            }
          }
          result->Success();
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
  // Feedback cue playback (shutter / completion) on this engine, like macOS.
  unit.sound = std::make_unique<SoundChannel>(msgr);
}

// ---- present / show / dismiss --------------------------------------------

void OverlayManager::BeginCapture(bool pin_only, bool live_select) {
  if (presenting_) {
    // A previous capture's present -> overlayReady -> Show chain is still in
    // flight; dropping this re-trigger keeps the chains from overlapping (the
    // rapid-mash crash). Cleared when every presented display is shown (Show)
    // or the overlay is dismissed.
    return;
  }
  perf::Mark(live_select ? "captureAllBegin live=1" : "captureAllBegin live=0");
  SyncUnitsToScreens();
  POINT cursor{};
  GetCursorPos(&cursor);
  HMONITOR cursor_mon = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  const int64_t cursor_id = MonId(cursor_mon);
  PresentBegin(cursor_id);

  std::vector<HMONITOR> mons = EnumerateMonitors();
  // Cursor display first (a valid strict-weak-ordering: "is-cursor" sorts ahead
  // of "is-not") so it is PRESENTED first, mirroring the macOS jobs.sort.
  std::stable_sort(mons.begin(), mons.end(),
                   [cursor_id](HMONITOR a, HMONITOR b) {
                     return (MonId(a) == cursor_id) && (MonId(b) != cursor_id);
                   });

  // A fresh live record-select drops any STALE feeds first. EndLiveSelect also
  // RE-INCLUDES every overlay in capture, so it MUST run BEFORE we set the
  // exclusion below -- otherwise it clobbers the exclusion and the loupe's live
  // WGC feed captures our own crosshair/veil (the "crosshair in the loupe" bug).
  if (live_select) EndLiveSelect();
  live_select_ = live_select;

  // The overlay window is ALWAYS DWM-glass (a frozen screenshot still reads
  // opaque); only capture-EXCLUSION flips: exclude while a live loupe feed is/will
  // be running (this live-select, OR a prior record-select still suspended beneath
  // -- its feed persists across a screenshot-over-RS so the resurfaced loupe keeps
  // sampling the true desktop), re-include otherwise so a recording over a session
  // still captures the overlay as content.
  const bool exclude = live_select || !live_sources_.empty();
  for (HMONITOR m : mons) {
    Unit* u = UnitFor(MonId(m));
    if (u && u->window) u->window->SetCaptureExcluded(exclude);
  }

  if (live_select) {
    // LIVE record-select (full macOS parity): NO frozen capture -- the overlay is
    // transparent and the real desktop shows through; the loupe samples a
    // per-display live WGC feed. Present a geometry-only (transparent-base) dict.
    // (Stale feeds already dropped + capture exclusion applied above.)
    int presented = 0;
    for (HMONITOR m : mons) {
      const int64_t id = MonId(m);
      auto src = std::make_unique<LiveFrameSource>();
      src->Start(m);  // failures are silent -> the loupe just stays empty
      live_sources_[id] = std::move(src);
      const bool is_cursor = (id == cursor_id);
      PresentFrame(id, BuildLiveDisplayDict(m, is_cursor, cursor), pin_only,
                   true);
      ++presented;
    }
    if (presented > 0) {
      presenting_ = true;
      pending_shows_ = presented;
      ArmPresentWatchdog();
    }
    return;
  }

  // Frozen multi-display capture (screenshot / pin): capture every monitor IN
  // PARALLEL -- each worker has its OWN WinRT MTA + D3D device + frame pool (no
  // shared state), so a multi-display freeze is not staggered across displays
  // (mirrors macOS's parallel captureAll). The present (onCaptureReady) stays on
  // this platform thread, cursor display first.
  //
  // A frozen screenshot/pin taken over an ACTIVE record-select must capture the
  // RS crosshair/veil/loupe as CONTENT (macOS parity: an op's OWN live chrome
  // self-excludes, but the OTHER op's chrome is captured). The exclusion applied
  // above (for the still-alive RS loupe feed) hides our overlay from WGC, so
  // momentarily re-INCLUDE the overlays for THIS one grab, then re-exclude right
  // after: the loupe is not displayed while RS suspends beneath the new freeze
  // layer, and re-excluding here keeps the RESTORED loupe clean (no resurface
  // hook needed). DwmFlush forces DWM to compose the now-included overlay before
  // the fresh WGC session samples it, else the grab could miss it by a frame.
  const bool unexclude_for_grab = !live_sources_.empty();
  if (unexclude_for_grab) {
    for (HMONITOR m : mons) {
      Unit* u = UnitFor(MonId(m));
      if (u && u->window) u->window->SetCaptureExcluded(false);
    }
    DwmFlush();
  }
  // HDR-base retention decision belongs to the FREEZE moment: when the Dart
  // hdr_screenshot setting is on, HDR monitors capture in fp16 anyway (the
  // wash-out fix) and keep the raw buffer for the annotated export's HDR
  // sibling. One generation only; stale bases die here or in TeardownUnits.
  const bool keep_f16 = hdr::ReadHdrScreenshotSetting();
  ++hdr_gen_;
  hdr_bases_.clear();
  std::vector<std::optional<CaptureFrame>> frames(mons.size());
  {
    std::vector<std::thread> workers;
    workers.reserve(mons.size());
    for (size_t i = 0; i < mons.size(); ++i) {
      workers.emplace_back([&frames, &mons, i, keep_f16]() {
        try {
          winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (...) {
        }
        // force_opaque_alpha: the frozen base must read fully opaque on the
        // permanent DWM-glass overlay window (see wgc_capturer.h).
        frames[i] = wgc::CaptureMonitor(mons[i], false, keep_f16,
                                        /*force_opaque_alpha=*/true);
        winrt::uninit_apartment();
      });
    }
    for (auto& t : workers) t.join();
  }
  perf::Mark("captureAllJoined n=" + std::to_string(mons.size()));
  if (unexclude_for_grab) {
    // Restore the resting exclusion so the RS loupe feed is clean when RS
    // resurfaces (record hotkey while suspended, or the freeze layer draining).
    for (HMONITOR m : mons) {
      Unit* u = UnitFor(MonId(m));
      if (u && u->window) u->window->SetCaptureExcluded(true);
    }
  }
  int presented = 0;
  for (size_t i = 0; i < mons.size(); ++i) {
    if (!frames[i]) continue;
    const int64_t id = MonId(mons[i]);
    const bool is_cursor = (id == cursor_id);
    // Retain the fp16 base (extracted BEFORE the frame moves into the dict).
    if (!frames[i]->f16.empty()) {
      HdrBase hb;
      hb.w = frames[i]->width;
      hb.h = frames[i]->height;
      hb.sdr_white_nits = frames[i]->sdr_white_nits;
      hb.gen = hdr_gen_;
      hb.f16 = std::move(frames[i]->f16);
      hdr_bases_[id] = std::move(hb);
    }
    EncodableMap dict =
        BuildDisplayDict(mons[i], std::move(*frames[i]), is_cursor, cursor);
    if (hdr_bases_.count(id) != 0) {
      dict[EncodableValue("hdrGen")] = EncodableValue(hdr_bases_[id].gen);
    }
    PresentFrame(id, std::move(dict), pin_only, false);
    perf::Mark("presentFrame id=" + std::to_string(id));
    ++presented;
  }
  // Block re-triggers until every presented display has been shown (or the
  // overlay is dismissed) so the async reveal chains never overlap. Nothing
  // presented (capture fully failed) -> no chain, so do not arm the guard.
  if (presented > 0) {
    presenting_ = true;
    pending_shows_ = presented;
    ArmPresentWatchdog();
  }
}

void OverlayManager::WarmUp() {
  // Build the per-display engines now (hidden, resident-warm) so the first
  // capture skips the engine-boot cold start. SyncUnitsToScreens is the same
  // lazy-create path BeginCapture uses, so this is purely a head start: an
  // already-built unit is reused, and a capture racing this just finds the
  // engines ready (or builds them itself -- both on the UI thread, no overlap).
  SyncUnitsToScreens();
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
  // The frozen base arrives fully OPAQUE: BeginCapture's workers pass
  // force_opaque_alpha to wgc::CaptureMonitor, which stamps alpha=255 during
  // the readback row copy (cache-hot; a separate full-frame pass here cost
  // 5-15ms per 4K display). Rationale in wgc_capturer.h. The live
  // record-select path stays transparent: BuildLiveDisplayDict passes an
  // EMPTY buffer and Dart paints its transparent stub.
  // Move the BGRA buffer into the reply (never copied).
  d[EncodableValue("rawBytes")] = EncodableValue(std::move(frame.bgra));
  return d;
}

EncodableMap OverlayManager::BuildLiveDisplayDict(HMONITOR mon, bool is_cursor,
                                                  POINT cursor_global) {
  // Live-select: no frozen pixels. Reuse BuildDisplayDict with an EMPTY frame
  // sized to the monitor -- Dart paints a transparent stub base + reads the live
  // loupe feed, so the empty rawBytes is never decoded. Geometry + cursor +
  // snappable windows still flow so the picker (crop HUD / window-snap) works.
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  CaptureFrame f;
  f.width = static_cast<uint32_t>(mi.rcMonitor.right - mi.rcMonitor.left);
  f.height = static_cast<uint32_t>(mi.rcMonitor.bottom - mi.rcMonitor.top);
  f.stride = f.width * 4;  // f.bgra stays empty
  return BuildDisplayDict(mon, std::move(f), is_cursor, cursor_global);
}

void OverlayManager::EndLiveSelect() {
  for (auto& kv : live_sources_) {
    if (kv.second) kv.second->Stop();
  }
  live_sources_.clear();
  live_select_ = false;
  // Re-include the overlays in capture: with no loupe feed running, a recording
  // over a screenshot session beneath must capture the overlay as content.
  for (auto& kv : units_) {
    if (kv.second.window) kv.second.window->SetCaptureExcluded(false);
  }
}

void OverlayManager::RelayRecordSelectHotkey() {
  // Relay to every overlay engine; the shared Dart (_onRecordSelectHotkey)
  // resurfaces a suspended picker or cancels a foreground one per its own state.
  for (auto& kv : units_) {
    if (kv.second.overlay) {
      kv.second.overlay->InvokeMethod("onRecordSelectHotkey", nullptr);
    }
  }
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
  perf::Mark("overlayShown id=" + std::to_string(display_id));
  // One presented display shown; when the last one is up the capture chain has
  // settled -> release the guard so the next trigger (deliberate layer-stack /
  // re-capture) can proceed without overlapping this chain.
  if (presenting_ && --pending_shows_ <= 0) {
    presenting_ = false;
    pending_shows_ = 0;
    if (present_watchdog_) {
      KillTimer(nullptr, present_watchdog_);
      present_watchdog_ = 0;
    }
  }

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
  presenting_ = false;  // session ended -> release the capture-serialization guard
  pending_shows_ = 0;
  if (present_watchdog_) {
    KillTimer(nullptr, present_watchdog_);
    present_watchdog_ = 0;
  }
  EndLiveSelect();  // stop any live record-select loupe feeds
  StopCursorTracking();
  SetCursorHidden(false);
  SetDrawingLock(0);
  for (auto& kv : units_) {
    if (kv.second.window) kv.second.window->Hide();
  }
  // Repair the WinUI3 content-island input that a RENDERED overlay engine breaks
  // in other apps: destroy + re-warm the engines a beat after dismiss. Deferred
  // via a one-shot timer so the teardown runs OUTSIDE this dismissOverlay channel
  // handler (whose engine it would otherwise destroy mid-call). See TeardownUnits.
  if (teardown_timer_) KillTimer(nullptr, teardown_timer_);
  teardown_timer_ = SetTimer(nullptr, 0, 250, &OverlayManager::TeardownProc);
}

void OverlayManager::TeardownUnits() {
  if (teardown_timer_) {
    KillTimer(nullptr, teardown_timer_);
    teardown_timer_ = 0;
  }
  if (presenting_) return;  // a new capture started in the gap -- leave it intact
  perf::Mark("teardownBegin");
  hdr_bases_.clear();  // the annotated export consumed (or forfeited) them
  units_.clear();  // ~Unit -> ~OverlayWindow destroys each Flutter engine + window;
                   // releasing the engine is what repairs the other apps' islands.
  WarmUp();        // recreate warm engines so the NEXT capture stays instant (a
                   // fresh engine that has not capture-rendered does not re-break).
  perf::Mark("teardownEnd");
}

// static
void CALLBACK OverlayManager::TeardownProc(HWND, UINT, UINT_PTR, DWORD) {
  if (instance_) instance_->TeardownUnits();
}

// Arm (or re-arm) the stuck-present watchdog: one shot, a few seconds after
// the present fan-out. A healthy chain releases the guard (and kills this
// timer) within a few hundred ms; firing means an engine never delivered
// overlayReady, which previously wedged ALL captures until a dismiss.
void OverlayManager::ArmPresentWatchdog() {
  if (present_watchdog_) KillTimer(nullptr, present_watchdog_);
  present_watchdog_ =
      SetTimer(nullptr, 0, 4000, &OverlayManager::PresentWatchdogProc);
}

void OverlayManager::ReleaseStuckPresentGuard() {
  if (present_watchdog_) {
    KillTimer(nullptr, present_watchdog_);
    present_watchdog_ = 0;
  }
  if (!presenting_) return;
  perf::Mark("presentGuardWatchdog pending=" + std::to_string(pending_shows_));
  presenting_ = false;
  pending_shows_ = 0;
}

// static
void CALLBACK OverlayManager::PresentWatchdogProc(HWND, UINT, UINT_PTR, DWORD) {
  if (instance_) instance_->ReleaseStuckPresentGuard();
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

  if (method == "encodeHdrRegion") {
    // The annotated export's HDR sibling: composite the Dart-supplied overlay
    // segments + effect ops onto this display's freeze-retained fp16 base and
    // return the encoded JXR. Null reply = no base retained (SDR monitor,
    // setting off at freeze, or a stale layer generation) -> Dart skips it.
    const auto get_i64 = [](const EncodableMap& m, const char* key,
                            int64_t dflt) -> int64_t {
      auto it = m.find(EncodableValue(key));
      if (it == m.end()) return dflt;
      if (auto p = std::get_if<int32_t>(&it->second)) return *p;
      if (auto p = std::get_if<int64_t>(&it->second)) return *p;
      return dflt;
    };
    const auto get_str = [](const EncodableMap& m,
                            const char* key) -> std::string {
      auto it = m.find(EncodableValue(key));
      if (it == m.end()) return {};
      if (auto p = std::get_if<std::string>(&it->second)) return *p;
      return {};
    };
    const auto base_it = hdr_bases_.find(display_id);
    if (base_it == hdr_bases_.end() ||
        base_it->second.gen != get_i64(args, "gen", -1)) {
      result->Success();
      return;
    }
    const HdrBase& hb = base_it->second;
    const int cx = static_cast<int>(std::lround(GetDouble(args, "x", 0)));
    const int cy = static_cast<int>(std::lround(GetDouble(args, "y", 0)));
    const int cw = static_cast<int>(std::lround(GetDouble(args, "w", 0)));
    const int ch = static_cast<int>(std::lround(GetDouble(args, "h", 0)));
    std::vector<hdrc::Item> items;
    if (auto list_it = args.find(EncodableValue("items"));
        list_it != args.end()) {
      if (auto* list = std::get_if<flutter::EncodableList>(&list_it->second)) {
        for (const auto& entry : *list) {
          auto* m = std::get_if<EncodableMap>(&entry);
          if (!m) continue;
          const std::string t = get_str(*m, "t");
          hdrc::Item item;
          if (t == "overlay") {
            item.kind = hdrc::Item::kOverlay;
            auto b = m->find(EncodableValue("bytes"));
            if (b == m->end()) continue;
            auto* bytes = std::get_if<std::vector<uint8_t>>(&b->second);
            if (!bytes) continue;
            item.rgba = *bytes;
            item.ow = static_cast<uint32_t>(get_i64(*m, "w", 0));
            item.oh = static_cast<uint32_t>(get_i64(*m, "h", 0));
          } else if (t == "blur" || t == "pixelate") {
            item.kind =
                t == "blur" ? hdrc::Item::kBlur : hdrc::Item::kPixelate;
            item.x = GetDouble(*m, "x", 0);
            item.y = GetDouble(*m, "y", 0);
            item.w = GetDouble(*m, "w", 0);
            item.h = GetDouble(*m, "h", 0);
            item.sigma = GetDouble(*m, "sigma", 0);
            item.cell = GetDouble(*m, "cell", 0);
          } else if (t == "magnify") {
            item.kind = hdrc::Item::kMagnify;
            item.sx = GetDouble(*m, "sx", 0);
            item.sy = GetDouble(*m, "sy", 0);
            item.sw = GetDouble(*m, "sw", 0);
            item.sh = GetDouble(*m, "sh", 0);
            item.dx = GetDouble(*m, "dx", 0);
            item.dy = GetDouble(*m, "dy", 0);
            item.dw = GetDouble(*m, "dw", 0);
            item.dh = GetDouble(*m, "dh", 0);
          } else if (t == "spotlight") {
            item.kind = hdrc::Item::kSpotlight;
            const std::string effect = get_str(*m, "effect");
            item.sp_effect = effect == "blur" ? 1
                             : effect == "pixelate" ? 2
                                                    : 0;
            item.sp_strength = GetDouble(*m, "strength", 0);
            item.sp_dim = GetDouble(*m, "dim", 0);
            item.sp_feather = GetDouble(*m, "feather", 0);
            if (auto holes_it = m->find(EncodableValue("holes"));
                holes_it != m->end()) {
              if (auto* holes =
                      std::get_if<flutter::EncodableList>(&holes_it->second)) {
                for (const auto& hv : *holes) {
                  auto* hm = std::get_if<EncodableMap>(&hv);
                  if (!hm) continue;
                  hdrc::Hole hole;
                  hole.x = GetDouble(*hm, "x", 0);
                  hole.y = GetDouble(*hm, "y", 0);
                  hole.w = GetDouble(*hm, "w", 0);
                  hole.h = GetDouble(*hm, "h", 0);
                  hole.radius = GetDouble(*hm, "radius", 0);
                  item.holes.push_back(hole);
                }
              }
            }
          } else {
            continue;
          }
          items.push_back(std::move(item));
        }
      }
    }
    const uint8_t* mask = nullptr;
    int mask_w = 0, mask_h = 0, mask_row = 0;
    // Points straight into the call arguments (alive for this synchronous
    // handler) -- the previous local copy duplicated a full-frame mask.
    if (auto mk = args.find(EncodableValue("mask")); mk != args.end()) {
      if (auto* mb = std::get_if<std::vector<uint8_t>>(&mk->second)) {
        mask = mb->data();
        mask_w = static_cast<int>(get_i64(args, "maskW", 0));
        mask_h = static_cast<int>(get_i64(args, "maskH", 0));
        mask_row = static_cast<int>(get_i64(args, "maskRowBytes", 0));
        if (mask_row <= 0) mask_row = mask_w * 4;
      }
    }
    auto encoded = hdrc::ComposeToJxr(
        reinterpret_cast<const uint16_t*>(hb.f16.data()), hb.w, hb.h,
        hb.sdr_white_nits, cx, cy, cw, ch, items, mask, mask_w, mask_h,
        mask_row);
    if (encoded.empty()) {
      result->Success();
      return;
    }
    EncodableMap reply;
    reply[EncodableValue("bytes")] = EncodableValue(std::move(encoded));
    reply[EncodableValue("ext")] = EncodableValue("jxr");
    result->Success(EncodableValue(std::move(reply)));
    return;
  }

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
  if (method == "openInEditor") {
    // The overlay flow's open-in-editor leg: reveal the editor + load the file.
    if (const auto* path = Find(args, "path")) {
      if (const auto* p = std::get_if<std::string>(path)) {
        if (editor_window_) editor_window_->OpenWithPath(*p);
      }
    }
    result->Success();
    return;
  }
  if (method == "recentChanged") {
    // An overlay capture saved a file into the shared recent store -> tell the
    // editor engine to reload + re-push its list to the tray submenu.
    if (editor_window_) editor_window_->RefreshRecent();
    result->Success();
    return;
  }
  if (method == "pinImage") {
    // The overlay flow's pin leg: float [path] in place over the captured region
    // (x/y/w/h global logical) when present, else centered.
    std::string path = GetString(args, "path");
    if (!path.empty() && pin_manager_) {
      std::optional<RECT> place;
      if (Find(args, "w") && Find(args, "h")) {
        const double x = GetDouble(args, "x", 0.0);
        const double y = GetDouble(args, "y", 0.0);
        const double w = GetDouble(args, "w", 0.0);
        const double h = GetDouble(args, "h", 0.0);
        place = RECT{static_cast<LONG>(std::lround(x)),
                     static_cast<LONG>(std::lround(y)),
                     static_cast<LONG>(std::lround(x + w)),
                     static_cast<LONG>(std::lround(y + h))};
      }
      pin_manager_->Pin(path, place);
    }
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
    MessageBoxW(nullptr, Utf16FromUtf8(GetString(args, "message")).c_str(),
                L"Glimpr",
                MB_OK | MB_ICONWARNING);
    result->Success();
    return;
  }
  // Booleans the Dart overlay path may query.
  if (method == "accessibilityTrusted") {
    result->Success(EncodableValue(false));
    return;
  }
  if (method == "loupeSample") {
    // Live record-select loupe: a span x span RGBA patch around the native pixel
    // (x, y) from THIS display's live feed; null before the first frame (the
    // loupe just stays empty). Mirrors the macOS loupeSample.
    auto it = live_sources_.find(display_id);
    if (it != live_sources_.end() && it->second) {
      auto get_int = [&](const char* k) -> int {
        const auto* v = Find(args, k);
        if (!v) return 0;
        if (const auto* p = std::get_if<int32_t>(v)) return *p;
        if (const auto* p = std::get_if<int64_t>(v)) return static_cast<int>(*p);
        if (const auto* p = std::get_if<double>(v)) return static_cast<int>(*p);
        return 0;
      };
      auto patch =
          it->second->Sample(get_int("x"), get_int("y"), get_int("span"));
      if (patch) {
        result->Success(EncodableValue(std::move(*patch)));
        return;
      }
    }
    result->Success();  // null -> blank loupe until a live frame arrives
    return;
  }
  // Methods still deferred on Windows (element snap, window-alpha snap mask): a
  // safe null reply so the shared Dart degrades (rect snap).
  if (method == "captureWindowImage" || method == "elementSnapAt") {
    result->Success();  // null -> Dart falls back (rect snap)
    return;
  }
  if (method == "recordSelection") {
    // Relay the record-select confirm/cancel to the control engine's record
    // channel (-> Dart onRecordSelection -> RecordController). Same UI thread,
    // so the cross-engine hop is a direct call.
    if (record_relay_) {
      const auto* a = std::get_if<EncodableMap>(call.arguments());
      record_relay_(a ? EncodableValue(*a) : EncodableValue());
    }
    result->Success();
    return;
  }
  if (method == "stopLoupeFeed") {
    // Record-select ended (confirm/cancel): stop the live loupe feeds. The
    // transparent overlay is restored to opaque on the next screenshot capture.
    EndLiveSelect();
    result->Success();
    return;
  }
  if (method == "setProcessing") {
    // Capture committed (true) / delivered (false): relay to the control engine's
    // tray to drive the logo-gradient processing pulse (mirrors macOS, where the
    // overlay engine forwards setProcessing to the status item). The optional
    // label becomes the tray's hover tooltip while pulsing.
    if (processing_relay_) {
      processing_relay_(GetBool(args, "active", false),
                        GetString(args, "label"));
    }
    result->Success();
    return;
  }
  if (method == "perfMark") {
    // Dart-side perf marks (overlay frame stats, export timing) land on the
    // same timeline as the native marks. Inert unless debugHooks is on.
    perf::Mark(GetString(args, "label"));
    result->Success();
    return;
  }
  if (method == "requestAccessibility" || method == "shareSheet" ||
      method == "recordSelectHotkey") {
    result->Success();
    return;
  }
  result->NotImplemented();
}
