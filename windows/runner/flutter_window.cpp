#include "flutter_window.h"

#include <shellapi.h>

#include <cstdio>
#include <optional>
#include <string>
#include <vector>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
// Deferred overlay warm-up: pre-create the per-display overlay engines this long
// after launch (off the launch critical path) so the first capture is instant.
// A capture during the delay just lazy-creates them itself (no regression).
constexpr UINT_PTR kWarmupTimerId = 0xB001;
constexpr UINT kWarmupDelayMs = 2000;

// The running executable's full path.
std::wstring ExePath() {
  wchar_t buf[MAX_PATH];
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf);
}

// "major.minor.patch (build)" from the exe's VERSIONINFO resource.
std::string AppVersionString() {
  std::wstring path = ExePath();
  DWORD handle = 0;
  DWORD size = GetFileVersionInfoSizeW(path.c_str(), &handle);
  if (size == 0) return "";
  std::vector<BYTE> data(size);
  if (!GetFileVersionInfoW(path.c_str(), 0, size, data.data())) return "";
  VS_FIXEDFILEINFO* info = nullptr;
  UINT len = 0;
  if (!VerQueryValueW(data.data(), L"\\",
                      reinterpret_cast<LPVOID*>(&info), &len) ||
      !info) {
    return "";
  }
  char out[64];
  sprintf_s(out, "%u.%u.%u (%u)",
            HIWORD(info->dwProductVersionMS), LOWORD(info->dwProductVersionMS),
            HIWORD(info->dwProductVersionLS), LOWORD(info->dwProductVersionLS));
  return out;
}

// Wait for THIS pid to exit, then start a fresh instance (the single-instance
// mutex would reject an immediate relaunch). Mirrors the macOS sh-watcher.
void RelaunchApp() {
  DWORD pid = GetCurrentProcessId();
  std::wstring exe = ExePath();
  wchar_t cmd[1024];
  swprintf_s(cmd,
    L"cmd.exe /c \":loop & tasklist /FI \\\"PID eq %lu\\\" | find \\\"%lu\\\" "
    L">nul && (timeout /t 1 /nobreak >nul & goto loop) & start \\\"\\\" "
    L"\\\"%ls\\\"\"",
    pid, pid, exe.c_str());
  STARTUPINFOW si = {};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {};
  if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE,
                     CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr,
                     &si, &pi)) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
}

// Launch-at-login: a per-user HKCU Run value pointing at the exe.
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Glimpr";

bool IsLaunchAtLogin() {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) !=
      ERROR_SUCCESS) {
    return false;
  }
  LONG r = RegQueryValueExW(key, kRunValue, nullptr, nullptr, nullptr, nullptr);
  RegCloseKey(key);
  return r == ERROR_SUCCESS;
}

void SetLaunchAtLogin(bool enable) {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) !=
      ERROR_SUCCESS) {
    return;
  }
  if (enable) {
    std::wstring quoted = L"\"" + ExePath() + L"\"";
    RegSetValueExW(
        key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(quoted.c_str()),
        static_cast<DWORD>((quoted.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(key, kRunValue);
  }
  RegCloseKey(key);
}
}  // namespace

UINT FlutterWindow::reveal_message_ = 0;

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  auto* messenger = flutter_controller_->engine()->messenger();

  // Native capture/clipboard channels (in-runner, mirroring macOS).
  capture_channel_ = std::make_unique<CaptureChannel>(messenger);
  clipboard_channel_ = std::make_unique<ClipboardChannel>(messenger);

  // This is the CONTROL engine: answer glimpr/role (so main.dart mounts the
  // Settings app without the retry) plus the Settings surface the shared
  // settings UI invokes (close / about / version / external links / relaunch).
  role_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/role",
      &flutter::StandardMethodCodec::GetInstance());
  role_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "getRole") {
          result->Success(EncodableValue("control"));
        } else if (m == "closeSettings") {
          ShowWindow(GetHandle(), SW_HIDE);  // close = hide to tray
          result->Success();
        } else if (m == "setShortcutRecording") {
          result->Success();  // no native key interceptor on Windows -> no-op
        } else if (m == "appVersion") {
          result->Success(EncodableValue(AppVersionString()));
        } else if (m == "openExternalUrl") {
          if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
            auto it = args->find(EncodableValue(std::string("url")));
            if (it != args->end()) {
              if (const auto* url = std::get_if<std::string>(&it->second)) {
                std::wstring wurl(url->begin(), url->end());
                ShellExecuteW(nullptr, L"open", wurl.c_str(), nullptr, nullptr,
                              SW_SHOWNORMAL);
              }
            }
          }
          result->Success();
        } else if (m == "relaunch") {
          RelaunchApp();
          Quit();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Launch-at-login (HKCU Run key).
  login_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/login",
      &flutter::StandardMethodCodec::GetInstance());
  login_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const auto& m = call.method_name();
        if (m == "isEnabled") {
          result->Success(EncodableValue(IsLaunchAtLogin()));
        } else if (m == "setEnabled") {
          bool enable = false;
          if (const auto* b = std::get_if<bool>(call.arguments())) enable = *b;
          SetLaunchAtLogin(enable);
          result->Success(EncodableValue(IsLaunchAtLogin()));
        } else {
          result->NotImplemented();
        }
      });

  // Global hotkeys (Win32 RegisterHotKey, fired via WM_HOTKEY to this window).
  hotkey_host_ = std::make_unique<HotkeyHost>(messenger, GetHandle());

  // The freeze-overlay manager owns the per-display engines (lazy). The control
  // window's HWND is passed so its own window is excluded from window-snap and
  // the overlay's openSettings can raise it.
  overlay_manager_ = std::make_unique<OverlayManager>(project_, GetHandle());
  capture_channel_->SetOverlayManager(overlay_manager_.get());

  // System tray (the menu-bar analogue). Live items fire through the same Dart
  // dispatcher as the hotkeys; Settings / About / Quit are native callbacks.
  tray_icon_ = std::make_unique<TrayIcon>(
      GetHandle(), GetModuleHandle(nullptr), hotkey_host_.get(),
      TrayIcon::Callbacks{
          [this]() { RevealControlWindow(); },
          [this]() {
            RevealControlWindow();
            role_channel_->InvokeMethod("showAbout", nullptr);
          },
          [this]() { Quit(); },
      });

  // A second instance posts this to reveal the running one's Settings.
  reveal_message_ = RegisterWindowMessageW(L"GlimprRevealSettings");

  // Deferred background warm-up: a short while after launch, pre-build the
  // overlay engines so the first capture is instant (without slowing launch).
  SetTimer(GetHandle(), kWarmupTimerId, kWarmupDelayMs, nullptr);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Resident shell: start HIDDEN in the tray (no window at launch, mirroring the
  // macOS at-rest accessory). main.dart still runs (registers hotkeys + builds
  // the tray) without frames; the first frame is produced on the first
  // RevealControlWindow (tray double-click / "Settings" / overlay openSettings).

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RevealControlWindow() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  if (flutter_controller_) flutter_controller_->ForceRedraw();
  SetForegroundWindow(hwnd);
}

void FlutterWindow::Quit() {
  if (tray_icon_) tray_icon_->Remove();
  PostQuitMessage(0);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Resident-shell messages, handled before Flutter / the base window proc.
  if (message == WM_HOTKEY && hotkey_host_) {
    hotkey_host_->Fire(static_cast<int>(wparam));
    return 0;
  }
  if (message == WM_GLIMPR_TRAY && tray_icon_) {
    tray_icon_->OnTrayMessage(wparam, lparam);
    return 0;
  }
  if (message == WM_TIMER && wparam == kWarmupTimerId) {
    KillTimer(GetHandle(), kWarmupTimerId);  // one-shot
    if (overlay_manager_) overlay_manager_->WarmUp();
    return 0;
  }
  if (message == WM_CLOSE) {
    ShowWindow(GetHandle(), SW_HIDE);  // close = hide to tray; do not destroy
    return 0;
  }
  if (reveal_message_ != 0 && message == reveal_message_) {
    RevealControlWindow();  // a second instance asked us to show Settings
    return 0;
  }
  // Taskbar light/dark flip -> re-tint the tray mark. Non-consuming: Flutter
  // still receives WM_SETTINGCHANGE to update its own theme.
  if (message == WM_SETTINGCHANGE && tray_icon_ && lparam &&
      lstrcmpiW(reinterpret_cast<const wchar_t*>(lparam),
                L"ImmersiveColorSet") == 0) {
    tray_icon_->OnThemeChanged();
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
