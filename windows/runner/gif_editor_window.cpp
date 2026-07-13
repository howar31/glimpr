#include "gif_editor_window.h"

#include <flutter_windows.h>

#include <flutter/generated_plugin_registrant.h>

#include <utility>

#include "perf_log.h"
#include "utils.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
// GIF Editor default content size + minimum (matching the macOS window:
// 1180x700, min 760x560 -- the minimum keeps the controls row intact and a
// usable preview above the filmstrip).
constexpr int kDefaultW = 1180;
constexpr int kDefaultH = 700;
constexpr int kMinW = 760;
constexpr int kMinH = 560;
}  // namespace

GifEditorWindow::GifEditorWindow(const flutter::DartProject& project,
                                 HWND control_hwnd)
    : project_(project), control_hwnd_(control_hwnd) {}

GifEditorWindow::~GifEditorWindow() {}

void GifEditorWindow::WarmUp() { EnsureCreated(); }

void GifEditorWindow::EnsureCreated() {
  if (GetHandle()) return;  // already built (warm or lazy)
  Win32Window::Point origin(100, 80);
  Win32Window::Size size(kDefaultW, kDefaultH);
  // ASCII placeholder title; the Dart side pushes the localized caption via
  // setWindowTitle as soon as it boots (the runner owns no l10n strings).
  Create(L"GIF Editor", origin, size);
  SetQuitOnClose(false);  // close hides to the engine-warm state, never quits
}

void GifEditorWindow::RevealEditor() {
  EnsureCreated();
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  if (flutter_controller_) flutter_controller_->ForceRedraw();
  SetForegroundWindow(hwnd);
}

bool GifEditorWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  auto* messenger = flutter_controller_->engine()->messenger();

  // This is the GIF-EDITOR engine: answer glimpr/role so main.dart mounts the
  // GIF editor app, and host glimpr/gifEditor (the editor <-> native bridge).
  role_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/role", &flutter::StandardMethodCodec::GetInstance());
  role_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getRole") {
          result->Success(EncodableValue("gif-editor"));
        } else {
          result->NotImplemented();
        }
      });

  gif_editor_channel_ =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "glimpr/gifEditor",
          &flutter::StandardMethodCodec::GetInstance());
  gif_editor_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& m = call.method_name();
        if (m == "hideEditor") {
          if (GetHandle()) ShowWindow(GetHandle(), SW_HIDE);
          result->Success();
        } else if (m == "setProcessing") {
          // Export commit (true) / delivered (false): relay to the control
          // engine's tray to drive the processing pulse (label = tooltip).
          bool active = false;
          std::string label;
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("active")));
            if (it != a->end()) {
              if (const auto* b = std::get_if<bool>(&it->second)) active = *b;
            }
            auto lt = a->find(EncodableValue(std::string("label")));
            if (lt != a->end()) {
              if (const auto* s = std::get_if<std::string>(&lt->second)) {
                label = *s;
              }
            }
          }
          if (proc_cb_) proc_cb_(active, label);
          result->Success();
        } else if (m == "perfMark") {
          if (const auto* a = std::get_if<EncodableMap>(call.arguments())) {
            auto it = a->find(EncodableValue(std::string("label")));
            if (it != a->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                perf::Mark(*s);
              }
            }
          }
          result->Success();
        } else if (m == "openSettings") {
          if (control_hwnd_) {
            static UINT reveal = RegisterWindowMessageW(L"GlimprRevealSettings");
            PostMessage(control_hwnd_, reveal, 0, 0);
          }
          result->Success();
        } else if (m == "setWindowTitle") {
          // Dart pushes its localized title so the OS caption follows the
          // app_language setting; native owns no l10n strings.
          if (const auto* s = std::get_if<std::string>(call.arguments())) {
            if (GetHandle() && !s->empty()) {
              SetWindowTextW(GetHandle(), Utf16FromUtf8(*s).c_str());
            }
          }
          result->Success();
        } else if (m == "titleBarDoubleClick") {
          result->Success();  // the standard caption bar handles this itself
        } else {
          result->NotImplemented();
        }
      });

  // Registered for parity with the other editor engine (clipboard/encode/
  // sound seams); later slices use them, Dart degrades if absent.
  clipboard_channel_ = std::make_unique<ClipboardChannel>(messenger);
  encode_channel_ = std::make_unique<EncodeChannel>(messenger);
  sound_channel_ = std::make_unique<SoundChannel>(messenger);

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void GifEditorWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT GifEditorWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) noexcept {
  switch (message) {
    case WM_CLOSE:
      // S1 has no dirty state: close hides directly (the engine stays warm;
      // the window is never destroyed until quit). A Dart-side dirty confirm
      // arrives with the edit slices.
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = FlutterDesktopGetDpiForMonitor(
          MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
      double scale = dpi / 96.0;
      RECT min_client = {0, 0, static_cast<LONG>(kMinW * scale),
                         static_cast<LONG>(kMinH * scale)};
      AdjustWindowRectExForDpi(&min_client, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
      info->ptMinTrackSize.x = min_client.right - min_client.left;
      info->ptMinTrackSize.y = min_client.bottom - min_client.top;
      return 0;
    }
    case WM_SETTINGCHANGE:
      // System light/dark toggle: re-theme the title bar (the warm window
      // exists from boot, so its title bar must follow the live toggle).
      if (lparam &&
          lstrcmpiW(reinterpret_cast<const wchar_t*>(lparam),
                    L"ImmersiveColorSet") == 0) {
        UpdateTheme(hwnd);
      }
      break;
    default:
      break;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) return *result;
  }
  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
