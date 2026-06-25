#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "capture_channel.h"
#include "clipboard_channel.h"
#include "overlay_manager.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native channel hosts (in-runner, like macOS).
  std::unique_ptr<CaptureChannel> capture_channel_;
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
  // The control engine's role channel: answers getRole -> 'control' so Dart's
  // _getRole resolves on the first try instead of burning the 10x20ms retry.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> role_channel_;

  // The per-display freeze-overlay engines + windows (lazy-created on first
  // capture). The macOS OverlayManager analogue.
  std::unique_ptr<OverlayManager> overlay_manager_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
