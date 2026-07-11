#include "tray_icon.h"

#include <shellapi.h>

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "resource.h"
#include "utils.h"

TrayIcon* TrayIcon::s_record_instance_ = nullptr;

namespace {
// Menu command ids. Global-action items map to an action-key string; the rest
// are native commands.
enum TrayCommand : UINT {
  kCmdCaptureRegion = 1001,
  kCmdCaptureWindow,
  kCmdCaptureDisplay,
  kCmdCaptureLast,
  kCmdPinScreenshot,
  kCmdPinClipboard,
  kCmdRecordRegion,
  kCmdRecordWindow,
  kCmdRecordDisplay,
  kCmdRecordLast,
  kCmdOpenEditor,
  kCmdOpenEditorClipboard,
  kCmdClearRecent,
  kCmdOpenSaveFolder,
  kCmdCheckUpdates,
  kCmdAbout,
  kCmdSettings,
  kCmdQuit,
};

// Open Recent submenu item ids occupy [kCmdRecentBase, kCmdRecentBase + N).
constexpr UINT kCmdRecentBase = 2000;

// Action keys (must match lib/shortcuts/shortcut_actions.dart).
constexpr char kActCaptureArea[] = "global.captureArea";
constexpr char kActCaptureWindow[] = "global.captureWindow";
constexpr char kActCaptureScreen[] = "global.captureScreen";
constexpr char kActCaptureLast[] = "global.captureLastRegion";
constexpr char kActPinArea[] = "global.pinArea";
constexpr char kActPinClipboard[] = "global.pinClipboard";
constexpr char kActRecordRegion[] = "global.recordRegion";
constexpr char kActRecordWindow[] = "global.recordWindow";
constexpr char kActRecordDisplay[] = "global.recordDisplay";
constexpr char kActRecordLast[] = "global.recordLastRegion";
constexpr char kActOpenEditor[] = "global.openEditor";
constexpr char kActOpenEditorClipboard[] = "global.openEditorClipboard";
constexpr char kActOpenSaveFolder[] = "menu.openSaveFolder";

std::wstring Basename(const std::string& path) {
  std::wstring w = Utf16FromUtf8(path);
  size_t slash = w.find_last_of(L"\\/");
  return slash == std::wstring::npos ? w : w.substr(slash + 1);
}

// Whether the Windows taskbar / tray uses the LIGHT theme (so the mark must be
// DARK to read). SystemUsesLightTheme governs the taskbar (distinct from
// AppsUseLightTheme). Defaults to dark taskbar (white mark) when unreadable.
bool TaskbarUsesLightTheme() {
  HKEY key;
  if (RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD value = 0, size = sizeof(value), type = 0;
  LONG r = RegQueryValueExW(key, L"SystemUsesLightTheme", nullptr, &type,
                            reinterpret_cast<LPBYTE>(&value), &size);
  RegCloseKey(key);
  return r == ERROR_SUCCESS && type == REG_DWORD && value != 0;
}

// Append a UTF-8 label (+ optional ASCII accelerator after a tab) as a wide menu
// item. Labels are localized (pushed from Dart), so widen via UTF-8.
void AppendItem(HMENU menu, UINT id, const std::string& label,
                const std::string& accel, bool enabled) {
  std::string text = label;
  if (!accel.empty()) {
    text += "\t";
    text += accel;
  }
  std::wstring wide = Utf16FromUtf8(text);
  UINT flags = MF_STRING | (enabled ? MF_ENABLED : MF_GRAYED);
  AppendMenuW(menu, flags, id, wide.c_str());
}
}  // namespace

TrayIcon::TrayIcon(HWND owner, HINSTANCE instance, HotkeyHost* hotkeys,
                   Callbacks callbacks)
    : owner_(owner), instance_(instance), hotkeys_(hotkeys),
      cb_(std::move(callbacks)) {
  icon_ = LoadThemeIcon();
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = owner_;
  nid.uID = 1;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = WM_GLIMPR_TRAY;
  nid.hIcon = icon_;
  wcscpy_s(nid.szTip, L"Glimpr");
  added_ = Shell_NotifyIconW(NIM_ADD, &nid) == TRUE;
  s_record_instance_ = this;  // one tray; routes the record-tick timer
}

TrayIcon::~TrayIcon() {
  if (record_timer_) KillTimer(nullptr, record_timer_);
  if (proc_timer_) KillTimer(nullptr, proc_timer_);
  if (s_record_instance_ == this) s_record_instance_ = nullptr;
  Remove();
  if (icon_) DestroyIcon(icon_);
  if (mark_mask_) DeleteObject(mark_mask_);
}

// Decode the theme mark ONCE into mark_px_ (BGRA) + mark_mask_; the 20 Hz
// animators then only run their per-pixel tint. Rebuilt after
// InvalidateMarkCache (theme change).
bool TrayIcon::EnsureMarkPixels() const {
  if (!mark_px_.empty()) return true;
  HICON base = LoadThemeIcon();
  if (!base) return false;
  ICONINFO ii = {};
  if (!GetIconInfo(base, &ii)) {
    DestroyIcon(base);
    return false;
  }
  BITMAP bm = {};
  GetObject(ii.hbmColor, sizeof(bm), &bm);
  mark_w_ = bm.bmWidth;
  mark_h_ = bm.bmHeight;
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = mark_w_;
  bi.bmiHeader.biHeight = -mark_h_;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  mark_px_.assign(static_cast<size_t>(mark_w_) * mark_h_ * 4, 0);
  HDC dc = GetDC(nullptr);
  GetDIBits(dc, ii.hbmColor, 0, mark_h_, mark_px_.data(), &bi, DIB_RGB_COLORS);
  ReleaseDC(nullptr, dc);
  if (mark_mask_) DeleteObject(mark_mask_);
  mark_mask_ = ii.hbmMask;  // keep the mask; hbmColor + the icon are done
  if (ii.hbmColor) DeleteObject(ii.hbmColor);
  DestroyIcon(base);
  return !mark_px_.empty();
}

void TrayIcon::InvalidateMarkCache() {
  mark_px_.clear();
  if (mark_mask_) {
    DeleteObject(mark_mask_);
    mark_mask_ = nullptr;
  }
}

// The viewfinder mark tinted for the current taskbar theme, at small-icon size.
HICON TrayIcon::LoadThemeIcon() const {
  const int id = TaskbarUsesLightTheme() ? IDI_TRAY_DARK : IDI_TRAY_WHITE;
  return static_cast<HICON>(LoadImageW(
      instance_, MAKEINTRESOURCEW(id), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
}

void TrayIcon::OnThemeChanged() {
  if (!added_) return;
  // Drop the cached mark pixels: the next animation tick (or idle repaint
  // below) rebuilds them from the new theme's resource.
  InvalidateMarkCache();
  // While recording OR processing, the animation tick repaints from the
  // (now-invalidated) cache each frame, so leave the running animation alone.
  if (recording_ || ease_out_ || processing_) return;
  HICON next = LoadThemeIcon();
  if (!next) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = owner_;
  nid.uID = 1;
  nid.uFlags = NIF_ICON;
  nid.hIcon = next;
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  if (icon_) DestroyIcon(icon_);
  icon_ = next;
}

void TrayIcon::Remove() {
  if (!added_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = owner_;
  nid.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  added_ = false;
}

void TrayIcon::OnTrayMessage(WPARAM /*wparam*/, LPARAM lparam) {
  switch (LOWORD(lparam)) {
    case WM_RBUTTONUP:
      ShowMenu();  // right-click pops the menu
      break;
    case WM_LBUTTONDBLCLK:
      if (cb_.on_reveal_settings) cb_.on_reveal_settings();  // double-click -> Settings
      break;
    // Left single-click does nothing (owner choice): no menu, no Settings, so
    // there is no single/double-click conflict.
    default:
      break;
  }
}

void TrayIcon::ShowMenu() {
  // Localized label lookup (UTF-8, pushed from Dart); English fallback until the
  // push arrives.
  auto L = [this](const char* id, const char* fallback) -> std::string {
    auto it = labels_.find(id);
    return it != labels_.end() ? it->second : std::string(fallback);
  };

  HMENU menu = CreatePopupMenu();
  // Header (disabled). Brand name, never translated.
  AppendItem(menu, 0, "Glimpr", "", false);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Live screenshot actions, with accelerator hints from the bound hotkeys.
  AppendItem(menu, kCmdCaptureRegion, L("captureArea", "Screenshot Region"),
             hotkeys_->AcceleratorLabel(kActCaptureArea), true);
  AppendItem(menu, kCmdCaptureWindow, L("captureWindow", "Screenshot Window"),
             hotkeys_->AcceleratorLabel(kActCaptureWindow), true);
  AppendItem(menu, kCmdCaptureDisplay, L("captureScreen", "Screenshot Display"),
             hotkeys_->AcceleratorLabel(kActCaptureScreen), true);
  AppendItem(menu, kCmdCaptureLast, L("captureLast", "Screenshot Last Region"),
             hotkeys_->AcceleratorLabel(kActCaptureLast), true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Pin to screen (S4).
  AppendItem(menu, kCmdPinScreenshot, L("pinArea", "Pin Screenshot"),
             hotkeys_->AcceleratorLabel(kActPinArea), true);
  AppendItem(menu, kCmdPinClipboard, L("pinClipboard", "Pin Clipboard"),
             hotkeys_->AcceleratorLabel(kActPinClipboard), true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Recording (S6). Each item toggles its mode (start when idle, stop the active
  // recording otherwise), routed through the same Dart dispatcher as the hotkeys.
  AppendItem(menu, kCmdRecordRegion, L("recordRegion", "Record Region"),
             hotkeys_->AcceleratorLabel(kActRecordRegion), true);
  AppendItem(menu, kCmdRecordWindow, L("recordWindow", "Record Window"),
             hotkeys_->AcceleratorLabel(kActRecordWindow), true);
  AppendItem(menu, kCmdRecordDisplay, L("recordDisplay", "Record Display"),
             hotkeys_->AcceleratorLabel(kActRecordDisplay), true);
  AppendItem(menu, kCmdRecordLast, L("recordLast", "Record Last Region"),
             hotkeys_->AcceleratorLabel(kActRecordLast), true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Image editor + Open Recent (S4); live: open save folder.
  AppendItem(menu, kCmdOpenEditor, L("openEditor", "Open Image Editor"),
             hotkeys_->AcceleratorLabel(kActOpenEditor), true);
  AppendItem(menu, kCmdOpenEditorClipboard,
             L("openEditorClipboard", "Open Image Editor with Clipboard"),
             hotkeys_->AcceleratorLabel(kActOpenEditorClipboard), true);
  if (recent_.empty()) {
    AppendItem(menu, 0, L("openRecent", "Open Recent"), "", false);  // greyed
  } else {
    HMENU recent = CreatePopupMenu();
    const size_t n = recent_.size();
    for (size_t i = 0; i < n; ++i) {
      AppendMenuW(recent, MF_STRING, kCmdRecentBase + static_cast<UINT>(i),
                  Basename(recent_[i]).c_str());
    }
    AppendMenuW(recent, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(recent, MF_STRING, kCmdClearRecent,
                Utf16FromUtf8(L("clearRecent", "Clear Recent")).c_str());
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(recent),
                Utf16FromUtf8(L("openRecent", "Open Recent")).c_str());
  }
  AppendItem(menu, kCmdOpenSaveFolder, L("openSaveFolder", "Open Save Folder"),
             "", true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Dart pushes an "Update available: vX.Y.Z" label when the update check
  // finds a newer release (SetUpdateStatus); idle falls back to the pushed
  // localized "check" wording like every other item.
  AppendItem(menu, kCmdCheckUpdates,
             update_label_.empty() ? L("checkUpdates", "Check for updates")
                                   : update_label_,
             "", true);
  AppendItem(menu, kCmdAbout, L("about", "About Glimpr"), "", true);
  AppendItem(menu, kCmdSettings, L("settings", "Settings..."), "", true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendItem(menu, kCmdQuit, L("quit", "Quit Glimpr"), "", true);

  POINT pt;
  GetCursorPos(&pt);
  // Win32 popup quirk: foreground the owner so the menu dismisses on outside
  // click; TPM_RETURNCMD returns the chosen id inline; the trailing post is the
  // documented MSDN workaround.
  SetForegroundWindow(owner_);
  UINT cmd = TrackPopupMenu(menu,
                            TPM_RIGHTBUTTON | TPM_RETURNCMD | TPM_NONOTIFY,
                            pt.x, pt.y, 0, owner_, nullptr);
  PostMessage(owner_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (cmd) OnCommand(cmd);
}

void TrayIcon::OnCommand(UINT command_id) {
  // Open Recent submenu items occupy a contiguous range.
  if (command_id >= kCmdRecentBase &&
      command_id < kCmdRecentBase + recent_.size()) {
    if (cb_.on_open_recent) cb_.on_open_recent(recent_[command_id - kCmdRecentBase]);
    return;
  }
  switch (command_id) {
    case kCmdCaptureRegion: hotkeys_->FireAction(kActCaptureArea); break;
    case kCmdCaptureWindow: hotkeys_->FireAction(kActCaptureWindow); break;
    case kCmdCaptureDisplay: hotkeys_->FireAction(kActCaptureScreen); break;
    case kCmdCaptureLast: hotkeys_->FireAction(kActCaptureLast); break;
    case kCmdPinScreenshot: hotkeys_->FireAction(kActPinArea); break;
    case kCmdPinClipboard: hotkeys_->FireAction(kActPinClipboard); break;
    case kCmdRecordRegion: hotkeys_->FireAction(kActRecordRegion); break;
    case kCmdRecordWindow: hotkeys_->FireAction(kActRecordWindow); break;
    case kCmdRecordDisplay: hotkeys_->FireAction(kActRecordDisplay); break;
    case kCmdRecordLast: hotkeys_->FireAction(kActRecordLast); break;
    case kCmdOpenEditor: hotkeys_->FireAction(kActOpenEditor); break;
    case kCmdOpenEditorClipboard:
      hotkeys_->FireAction(kActOpenEditorClipboard);
      break;
    case kCmdClearRecent: if (cb_.on_clear_recent) cb_.on_clear_recent(); break;
    case kCmdOpenSaveFolder: hotkeys_->FireAction(kActOpenSaveFolder); break;
    case kCmdCheckUpdates:
      if (cb_.on_check_updates) cb_.on_check_updates();
      break;
    case kCmdAbout: if (cb_.on_about) cb_.on_about(); break;
    case kCmdSettings: if (cb_.on_reveal_settings) cb_.on_reveal_settings(); break;
    case kCmdQuit: if (cb_.on_quit) cb_.on_quit(); break;
    default: break;
  }
}

void TrayIcon::SetRecentImages(std::vector<std::string> paths) {
  recent_ = std::move(paths);
}

void TrayIcon::SetLabels(std::map<std::string, std::string> labels) {
  labels_ = std::move(labels);
}

void TrayIcon::SetUpdateStatus(const std::string& label_utf8, bool available) {
  update_label_ = label_utf8;
  update_available_ = available;
}

// static
void CALLBACK TrayIcon::RecordTimerProc(HWND, UINT, UINT_PTR, DWORD) {
  if (s_record_instance_) s_record_instance_->OnRecordTick();
}

// static
void CALLBACK TrayIcon::ProcTimerProc(HWND, UINT, UINT_PTR, DWORD) {
  if (s_record_instance_) s_record_instance_->OnProcTick();
}

void TrayIcon::ApplyIcon(HICON icon) {
  if (!icon) return;
  if (!added_) {
    DestroyIcon(icon);
    return;
  }
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = owner_;
  nid.uID = 1;
  nid.uFlags = NIF_ICON;
  nid.hIcon = icon;
  Shell_NotifyIconW(NIM_MODIFY, &nid);
  if (icon_) DestroyIcon(icon_);
  icon_ = icon;
}

// The theme mark with every opaque pixel blended toward recording-red (#FF453A)
// by [mix] (0 = idle theme tint, 1 = full red). Mirrors macOS recordingIcon(mix:).
// Reads the icon's 32bpp color bitmap (alpha = the mark's coverage) and reuses
// its mask. Caller-independent; ApplyIcon takes ownership of the result.
HICON TrayIcon::MakeTintedIcon(double mix) const {
  if (!EnsureMarkPixels()) return nullptr;
  const int w = mark_w_, h = mark_h_;
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> px = mark_px_;  // tint a copy of the cached mark
  const double tr = 0xFF, tg = 0x45, tb = 0x3A;  // recording red #FF453A
  for (size_t i = 0; i < px.size(); i += 4) {
    if (px[i + 3] == 0) continue;  // transparent pixel -> leave it
    px[i + 0] = static_cast<uint8_t>(px[i + 0] + (tb - px[i + 0]) * mix);  // B
    px[i + 1] = static_cast<uint8_t>(px[i + 1] + (tg - px[i + 1]) * mix);  // G
    px[i + 2] = static_cast<uint8_t>(px[i + 2] + (tr - px[i + 2]) * mix);  // R
  }
  HICON out = nullptr;
  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color && bits) {
    std::memcpy(bits, px.data(), px.size());
    ICONINFO ni = {};
    ni.fIcon = TRUE;
    ni.hbmColor = color;
    ni.hbmMask = mark_mask_;  // reuse the cached mask
    out = CreateIconIndirect(&ni);
  }
  if (color) DeleteObject(color);
  ReleaseDC(nullptr, dc);
  return out;
}

void TrayIcon::OnRecordTick() {
  const unsigned long long now = GetTickCount64();
  double mix;
  if (ease_out_) {
    const double t = static_cast<double>(now - ease_start_ms_) / 450.0;
    if (t >= 1.0) {  // ease finished -> restore the idle theme icon, stop ticking
      ease_out_ = false;
      if (record_timer_) {
        KillTimer(nullptr, record_timer_);
        record_timer_ = 0;
      }
      ApplyIcon(LoadThemeIcon());
      return;
    }
    mix = 1.0 - t;
  } else if (recording_) {
    // 0..1..0 cosine breath over 1.7s (mac parity): idle tone <-> full red.
    const double phase =
        static_cast<double>((now - record_start_ms_) % 1700) / 1700.0;
    mix = 0.5 - 0.5 * std::cos(phase * 2.0 * 3.14159265358979);
  } else {
    if (record_timer_) {
      KillTimer(nullptr, record_timer_);
      record_timer_ = 0;
    }
    return;
  }
  HICON tinted = MakeTintedIcon(mix);
  if (tinted) ApplyIcon(tinted);
}

void TrayIcon::SetRecordingState(bool active, bool graceful) {
  if (active) {
    if (recording_) return;
    if (processing_) {  // a recording start takes the mark from a processing pulse
      processing_ = false;
      processing_stop_ = false;
      if (proc_timer_) {
        KillTimer(nullptr, proc_timer_);
        proc_timer_ = 0;
      }
    }
    recording_ = true;
    ease_out_ = false;
    record_start_ms_ = GetTickCount64();
    BOOL anim = TRUE;
    SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &anim, 0);
    if (!anim) {  // reduced motion: hold solid red, no timer
      if (record_timer_) {
        KillTimer(nullptr, record_timer_);
        record_timer_ = 0;
      }
      ApplyIcon(MakeTintedIcon(1.0));
      return;
    }
    if (!record_timer_) {
      record_timer_ = SetTimer(nullptr, 0, 50, &TrayIcon::RecordTimerProc);
    }
    OnRecordTick();  // paint the first frame immediately
    return;
  }
  if (!recording_ && !ease_out_) return;
  recording_ = false;
  if (!graceful) {  // abort / failure: snap straight back to idle
    ease_out_ = false;
    if (record_timer_) {
      KillTimer(nullptr, record_timer_);
      record_timer_ = 0;
    }
    ApplyIcon(LoadThemeIcon());
    return;
  }
  // Graceful finish: ease the red back out over ~0.45s (handled in the tick).
  ease_out_ = true;
  ease_start_ms_ = GetTickCount64();
  if (!record_timer_) {
    record_timer_ = SetTimer(nullptr, 0, 50, &TrayIcon::RecordTimerProc);
  }
}

// The theme mark filled with the logo gradient (cyan #22D3EE -> blue #3B82F6 ->
// violet #A78BFA, swept along the icon's top-left -> bottom-right diagonal ~-45deg)
// at [intensity] opacity. Mirrors macOS processingIcon(intensity:). Geometry never
// changes -- only the gradient fill + overall opacity. The 32bpp alpha-icon path
// is alpha-blended (premultiplied), so color AND alpha are scaled by the mark's
// own coverage * intensity, fading the whole mark toward transparent at a pulse
// low. Caller-independent; ApplyIcon takes ownership of the result.
HICON TrayIcon::MakeProcessingIcon(double intensity) const {
  if (!EnsureMarkPixels()) return nullptr;
  const int w = mark_w_, h = mark_h_;
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> px = mark_px_;  // fill a copy of the cached mark
  const double clamp_i = intensity < 0 ? 0 : (intensity > 1 ? 1 : intensity);
  // Logo gradient stops (memory glimpr-brand-logo): cyan @0, blue @0.52, violet @1.
  const double span = (w + h > 2) ? static_cast<double>(w + h - 2) : 1.0;
  for (int y = 0; y < h; ++y) {
    for (int x = 0; x < w; ++x) {
      const size_t i = (static_cast<size_t>(y) * w + x) * 4;
      const uint8_t a = px[i + 3];
      if (a == 0) {  // outside the mark -> fully transparent (premultiplied)
        px[i + 0] = px[i + 1] = px[i + 2] = 0;
        continue;
      }
      const double t = (static_cast<double>(x) + y) / span;  // 0..1 along diagonal
      double gr, gg, gb;
      if (t <= 0.52) {
        const double k = t / 0.52;
        gr = 0x22 + (0x3B - 0x22) * k;
        gg = 0xD3 + (0x82 - 0xD3) * k;
        gb = 0xEE + (0xF6 - 0xEE) * k;
      } else {
        const double k = (t - 0.52) / 0.48;
        gr = 0x3B + (0xA7 - 0x3B) * k;
        gg = 0x82 + (0x8B - 0x82) * k;
        gb = 0xF6 + (0xFA - 0xF6) * k;
      }
      const double cov = (a / 255.0) * clamp_i;  // mark coverage * pulse opacity
      px[i + 0] = static_cast<uint8_t>(gb * cov);  // B (premultiplied)
      px[i + 1] = static_cast<uint8_t>(gg * cov);  // G
      px[i + 2] = static_cast<uint8_t>(gr * cov);  // R
      px[i + 3] = static_cast<uint8_t>(a * clamp_i);
    }
  }
  HICON out = nullptr;
  void* bits = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color && bits) {
    std::memcpy(bits, px.data(), px.size());
    ICONINFO ni = {};
    ni.fIcon = TRUE;
    ni.hbmColor = color;
    ni.hbmMask = mark_mask_;  // reuse the cached mask
    out = CreateIconIndirect(&ni);
  }
  if (color) DeleteObject(color);
  ReleaseDC(nullptr, dc);
  return out;
}

void TrayIcon::OnProcTick() {
  if (!processing_) {
    if (proc_timer_) {
      KillTimer(nullptr, proc_timer_);
      proc_timer_ = 0;
    }
    return;
  }
  const unsigned long long now = GetTickCount64();
  const double period = 500.0;  // ms; ~3.4x faster than the 1.7s recording breath
  const double phase = static_cast<double>(now - proc_start_ms_);  // ms
  const int cycle = static_cast<int>(phase / period);
  // End at a pulse low (cycle boundary), once stopped and after >= 1 full cycle.
  // The 10s ceiling is a safety net so the pulse never gets stuck if a "stop" is
  // ever missed on an error path. Recording-initiated pulses are exempt
  // (unbounded): the finalize can legitimately exceed it and native always
  // delivers the stop.
  const bool end_now =
      (processing_stop_ && cycle >= 1 && cycle > proc_last_cycle_) ||
      (!proc_unbounded_ && phase > 10000.0);
  proc_last_cycle_ = cycle;
  if (end_now) {
    processing_ = false;
    proc_unbounded_ = false;
    if (proc_timer_) {
      KillTimer(nullptr, proc_timer_);
      proc_timer_ = 0;
    }
    ApplyIcon(LoadThemeIcon());
    SetTip(L"Glimpr");  // drop the "Processing ..." hover tooltip
    return;
  }
  double intensity = 1.0;
  if (!proc_reduce_) {
    const double local_t = std::fmod(phase, period) / period;
    // Punchy pulse (sharper than a plain cosine) so it isn't a "fast breath".
    const double base = 0.5 - 0.5 * std::cos(local_t * 2.0 * 3.14159265358979);
    intensity = 0.35 + 0.65 * std::pow(base, 0.6);
  }
  HICON icon = MakeProcessingIcon(intensity);
  if (icon) ApplyIcon(icon);
}

std::string TrayIcon::Label(const std::string& id,
                            const std::string& fallback) const {
  auto it = labels_.find(id);
  return it != labels_.end() ? it->second : fallback;
}

void TrayIcon::SetTip(const std::wstring& tip) {
  if (!added_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = owner_;
  nid.uID = 1;
  nid.uFlags = NIF_TIP;
  wcsncpy_s(nid.szTip, tip.c_str(), _TRUNCATE);
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void TrayIcon::SetProcessing(bool active, const std::string& tip_utf8,
                             bool unbounded) {
  if (active) {
    if (recording_) return;  // the recording-red breath owns the mark
    processing_stop_ = false;
    proc_unbounded_ = proc_unbounded_ || unbounded;
    // Hover tooltip: WHAT is being processed. Set on every activation so an
    // overlapping source updates it; OnProcTick's end path restores "Glimpr".
    if (!tip_utf8.empty()) SetTip(Utf16FromUtf8(tip_utf8));
    if (processing_) return;  // already pulsing -> keep it alive
    processing_ = true;
    proc_start_ms_ = GetTickCount64();
    proc_last_cycle_ = 0;
    BOOL anim = TRUE;
    SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &anim, 0);
    proc_reduce_ = !anim;  // reduced motion: static gradient fill, no movement
    if (!proc_timer_) {
      proc_timer_ = SetTimer(nullptr, 0, 50, &TrayIcon::ProcTimerProc);
    }
    OnProcTick();  // paint the first frame immediately
    return;
  }
  processing_stop_ = true;  // ends at the next pulse low after >= 1 full cycle
}
