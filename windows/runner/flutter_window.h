#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "capture_channel.h"
#include "clipboard_channel.h"
#include "sound_channel.h"
#include "editor_window.h"
#include "gif_editor_window.h"
#include "hotkey_host.h"
#include "overlay_manager.h"
#include "pin_window.h"
#include "record_channel.h"
#include "tray_icon.h"
#include "win32_window.h"

// A window that hosts the control Flutter view + the resident shell (system tray
// + global hotkeys). Starts HIDDEN (tray-resident); revealed on demand as the
// Settings window. Mirrors the macOS MainFlutterWindow resident lifecycle.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Show the control window as the Settings window (tray double-click / "Settings"
  // / the overlay's openSettings / a second-instance reveal). Mirrors macOS
  // revealSettings: show + first-frame redraw + foreground.
  void RevealControlWindow();
  // Quit the resident app (tray "Quit"): remove the tray icon, force-exit.
  void Quit();

  // Broadcast message a second instance posts to reveal the running one's
  // Settings (RegisterWindowMessageW("GlimprRevealSettings")).
  static UINT reveal_message_;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Subclass proc on the Flutter view HWND: while the Settings recorder is
  // capturing, routes key messages to HotkeyHost (Flutter drops PrintScreen +
  // the Win key, so we intercept at the window-proc level) and suppresses them.
  static LRESULT CALLBACK KeyCaptureSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR id, DWORD_PTR ref);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native channel hosts (in-runner, like macOS).
  std::unique_ptr<CaptureChannel> capture_channel_;
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
  std::unique_ptr<SoundChannel> sound_channel_;
  // The control engine's role channel: getRole + the Settings surface (close,
  // about, version, external links, relaunch).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> role_channel_;
  // Launch-at-login (HKCU Run key).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> login_channel_;
  // Pro license blob storage (Credential Manager). Dumb read/write/clear; all
  // verification is Dart-side. Only the private/Pro build invokes it.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> license_channel_;
  // Installed-build self-update (glimpr/update): supported-check + verified
  // silent-install apply. Control engine only.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> update_channel_;
  // Screen recording (glimpr/record): WGC continuous capture + Media Foundation
  // encode. Control engine only (mirrors the macOS RecordingChannel).
  std::unique_ptr<RecordChannel> record_channel_;

  // Global hotkeys + the system tray (the resident shell).
  std::unique_ptr<HotkeyHost> hotkey_host_;
  std::unique_ptr<TrayIcon> tray_icon_;

  // The per-display freeze-overlay engines + windows (lazy-created on first
  // capture). The macOS OverlayManager analogue.
  std::unique_ptr<OverlayManager> overlay_manager_;

  // The standalone Image Editor engine + window (warm-built shortly after launch;
  // revealed on demand). The macOS warm editor window analogue.
  std::unique_ptr<EditorWindow> editor_window_;

  // The standalone GIF Editor engine + window (same lifecycle as the Image
  // Editor's). The macOS warm GIF editor window analogue.
  std::unique_ptr<GifEditorWindow> gif_editor_window_;

  // The live floating pins (pin-to-screen). The macOS PinPanel set analogue.
  std::unique_ptr<PinManager> pin_manager_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
