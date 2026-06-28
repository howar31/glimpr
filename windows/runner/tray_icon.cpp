#include "tray_icon.h"

#include <shellapi.h>

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "resource.h"

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

// UTF-8 -> UTF-16 (recent filenames may be non-ASCII, unlike the ASCII menu
// labels). The naive widening in AppendItem is ASCII-only, so recents convert
// properly here.
std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                              nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      w.data(), n);
  return w;
}

std::wstring Basename(const std::string& path) {
  std::wstring w = Utf8ToWide(path);
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
  std::wstring wide = Utf8ToWide(text);
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
  if (s_record_instance_ == this) s_record_instance_ = nullptr;
  Remove();
  if (icon_) DestroyIcon(icon_);
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
  // While recording, the breath tick re-tints from the live theme each frame
  // (MakeTintedIcon -> LoadThemeIcon), so leave the animation alone here.
  if (recording_ || ease_out_) return;
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
                Utf8ToWide(L("clearRecent", "Clear Recent")).c_str());
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(recent),
                Utf8ToWide(L("openRecent", "Open Recent")).c_str());
  }
  AppendItem(menu, kCmdOpenSaveFolder, L("openSaveFolder", "Open Save Folder"),
             "", true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
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

// static
void CALLBACK TrayIcon::RecordTimerProc(HWND, UINT, UINT_PTR, DWORD) {
  if (s_record_instance_) s_record_instance_->OnRecordTick();
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
  HICON base = LoadThemeIcon();
  if (!base) return nullptr;
  ICONINFO ii = {};
  if (!GetIconInfo(base, &ii)) {
    DestroyIcon(base);
    return nullptr;
  }
  BITMAP bm = {};
  GetObject(ii.hbmColor, sizeof(bm), &bm);
  const int w = bm.bmWidth, h = bm.bmHeight;
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  std::vector<uint8_t> px(static_cast<size_t>(w) * h * 4, 0);
  HDC dc = GetDC(nullptr);
  GetDIBits(dc, ii.hbmColor, 0, h, px.data(), &bi, DIB_RGB_COLORS);
  const double tr = 0xFF, tg = 0x45, tb = 0x3A;  // recording red #FF453A
  for (size_t i = 0; i < px.size(); i += 4) {
    if (px[i + 3] == 0) continue;  // transparent pixel -> leave it
    px[i + 0] = static_cast<uint8_t>(px[i + 0] + (tb - px[i + 0]) * mix);  // B
    px[i + 1] = static_cast<uint8_t>(px[i + 1] + (tg - px[i + 1]) * mix);  // G
    px[i + 2] = static_cast<uint8_t>(px[i + 2] + (tr - px[i + 2]) * mix);  // R
  }
  HICON out = nullptr;
  void* bits = nullptr;
  HBITMAP color = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (color && bits) {
    std::memcpy(bits, px.data(), px.size());
    ICONINFO ni = {};
    ni.fIcon = TRUE;
    ni.hbmColor = color;
    ni.hbmMask = ii.hbmMask;  // reuse the base mask
    out = CreateIconIndirect(&ni);
  }
  if (color) DeleteObject(color);
  ReleaseDC(nullptr, dc);
  if (ii.hbmColor) DeleteObject(ii.hbmColor);
  if (ii.hbmMask) DeleteObject(ii.hbmMask);
  DestroyIcon(base);
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
