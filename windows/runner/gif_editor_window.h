#ifndef RUNNER_GIF_EDITOR_WINDOW_H_
#define RUNNER_GIF_EDITOR_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>
#include <string>

#include "clipboard_channel.h"
#include "encode_channel.h"
#include "sound_channel.h"
#include "win32_window.h"

// The standalone GIF Editor: a resident, revealable top-level window hosting
// its OWN Flutter engine (role 'gif-editor'), mirroring EditorWindow's
// lifecycle (deferred warm-up or lazy creation on first reveal; closing only
// hides; never destroyed until the app quits). S1 hosts no file dialogs
// (Dart's file_selector owns them on Windows) and accepts no drops yet.
class GifEditorWindow : public Win32Window {
 public:
  GifEditorWindow(const flutter::DartProject& project, HWND control_hwnd);
  ~GifEditorWindow() override;

  GifEditorWindow(const GifEditorWindow&) = delete;
  GifEditorWindow& operator=(const GifEditorWindow&) = delete;

  // Build the engine + hidden window now (deferred warm-up). Idempotent.
  void WarmUp();
  // Reveal the GIF Editor (lazy-creates the engine if warm-up hasn't run).
  void RevealEditor();

  // The export "processing" pulse: glimpr/gifEditor setProcessing relays here
  // -> the control engine's tray (set once by FlutterWindow).
  void SetProcessingCallback(std::function<void(bool, const std::string&)> cb) {
    proc_cb_ = std::move(cb);
  }

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept override;

 private:
  // Lazily create the window + engine (calls Win32Window::Create -> OnCreate).
  void EnsureCreated();

  flutter::DartProject project_;
  HWND control_hwnd_ = nullptr;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> role_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      gif_editor_channel_;
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
  std::unique_ptr<EncodeChannel> encode_channel_;
  std::unique_ptr<SoundChannel> sound_channel_;

  // Export pulse (+ tooltip label) -> control tray.
  std::function<void(bool, const std::string&)> proc_cb_;
};

#endif  // RUNNER_GIF_EDITOR_WINDOW_H_
