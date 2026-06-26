#include "tray_icon.h"

#include <shellapi.h>

#include <string>

#include "resource.h"

namespace {
// Menu command ids. Global-action items map to an action-key string; the rest
// are native commands.
enum TrayCommand : UINT {
  kCmdCaptureRegion = 1001,
  kCmdCaptureWindow,
  kCmdCaptureDisplay,
  kCmdCaptureLast,
  kCmdOpenSaveFolder,
  kCmdAbout,
  kCmdSettings,
  kCmdQuit,
};

// Action keys (must match lib/shortcuts/shortcut_actions.dart).
constexpr char kActCaptureArea[] = "global.captureArea";
constexpr char kActCaptureWindow[] = "global.captureWindow";
constexpr char kActCaptureScreen[] = "global.captureScreen";
constexpr char kActCaptureLast[] = "global.captureLastRegion";
constexpr char kActOpenSaveFolder[] = "menu.openSaveFolder";

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

// Append an ASCII label (+ optional accelerator after a tab) as a wide menu
// item. Labels are ASCII (cp950 build), so a plain widening is safe.
void AppendItem(HMENU menu, UINT id, const std::string& label,
                const std::string& accel, bool enabled) {
  std::string text = label;
  if (!accel.empty()) {
    text += "\t";
    text += accel;
  }
  std::wstring wide(text.begin(), text.end());
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
}

TrayIcon::~TrayIcon() {
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
  HMENU menu = CreatePopupMenu();
  // Header (disabled).
  AppendItem(menu, 0, "Glimpr", "", false);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Live screenshot actions, with accelerator hints from the bound hotkeys.
  AppendItem(menu, kCmdCaptureRegion, "Screenshot Region",
             hotkeys_->AcceleratorLabel(kActCaptureArea), true);
  AppendItem(menu, kCmdCaptureWindow, "Screenshot Window",
             hotkeys_->AcceleratorLabel(kActCaptureWindow), true);
  AppendItem(menu, kCmdCaptureDisplay, "Screenshot Display",
             hotkeys_->AcceleratorLabel(kActCaptureScreen), true);
  AppendItem(menu, kCmdCaptureLast, "Screenshot Last Region",
             hotkeys_->AcceleratorLabel(kActCaptureLast), true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Deferred: pin (S4).
  AppendItem(menu, 0, "Pin Screenshot", "", false);
  AppendItem(menu, 0, "Pin Clipboard", "", false);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Deferred: recording (S6).
  AppendItem(menu, 0, "Record Region", "", false);
  AppendItem(menu, 0, "Record Window", "", false);
  AppendItem(menu, 0, "Record Display", "", false);
  AppendItem(menu, 0, "Record Last Region", "", false);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Deferred: editor / recent (S4); live: open save folder.
  AppendItem(menu, 0, "Open Image Editor", "", false);
  AppendItem(menu, 0, "Open Image Editor with Clipboard", "", false);
  AppendItem(menu, 0, "Open Recent", "", false);
  AppendItem(menu, kCmdOpenSaveFolder, "Open Save Folder", "", true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendItem(menu, kCmdAbout, "About Glimpr", "", true);
  AppendItem(menu, kCmdSettings, "Settings...", "", true);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendItem(menu, kCmdQuit, "Quit Glimpr", "", true);

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
  switch (command_id) {
    case kCmdCaptureRegion: hotkeys_->FireAction(kActCaptureArea); break;
    case kCmdCaptureWindow: hotkeys_->FireAction(kActCaptureWindow); break;
    case kCmdCaptureDisplay: hotkeys_->FireAction(kActCaptureScreen); break;
    case kCmdCaptureLast: hotkeys_->FireAction(kActCaptureLast); break;
    case kCmdOpenSaveFolder: hotkeys_->FireAction(kActOpenSaveFolder); break;
    case kCmdAbout: if (cb_.on_about) cb_.on_about(); break;
    case kCmdSettings: if (cb_.on_reveal_settings) cb_.on_reveal_settings(); break;
    case kCmdQuit: if (cb_.on_quit) cb_.on_quit(); break;
    default: break;
  }
}
