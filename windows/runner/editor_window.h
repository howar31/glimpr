#ifndef RUNNER_EDITOR_WINDOW_H_
#define RUNNER_EDITOR_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "clipboard_channel.h"
#include "encode_channel.h"
#include "sound_channel.h"
#include "win32_window.h"

class PinManager;
struct IDropTarget;

// The standalone Image Editor: a resident, revealable top-level window hosting
// its OWN Flutter engine (role 'image-editor'). Mirrors the macOS warm editor
// window. Windows creates+renders the engine at runtime (no launch-born hack),
// so it is built hidden on a deferred warm-up timer (or lazily on first reveal)
// and never destroyed until the app quits; closing only hides it.
class EditorWindow : public Win32Window {
 public:
  EditorWindow(const flutter::DartProject& project, HWND control_hwnd);
  ~EditorWindow() override;

  EditorWindow(const EditorWindow&) = delete;
  EditorWindow& operator=(const EditorWindow&) = delete;

  // Build the engine + hidden window now (deferred warm-up). Idempotent.
  void WarmUp();
  // Reveal the editor (lazy-creates the engine if warm-up hasn't run yet).
  void RevealEditor();
  // Reveal + load an image file (buffered until the editor Dart is ready).
  void OpenWithPath(const std::string& path);
  // Reveal + load the clipboard image.
  void LoadClipboard();

  // The tray "Open Recent" submenu source: invoked whenever the editor pushes a
  // refreshed recent-images list (Task 8 wires this to the tray).
  void SetRecentImagesCallback(
      std::function<void(std::vector<std::string>)> cb);
  // Ask the editor Dart to clear its recent list (tray "Clear Recent").
  void ClearRecent();
  // Ask the editor Dart to reload + re-push its recent list. Fanned out by the
  // capture/overlay engines after they save a file (native-mediated broadcast);
  // dropped harmlessly if the editor engine isn't built yet (its editorReady
  // refresh covers that case).
  void RefreshRecent();
  // Route the editor's pin flow leg to the shared pin manager (Task 7).
  void SetPinManager(PinManager* pm) { pin_manager_ = pm; }

  // The editor-export "processing" pulse: glimpr/imageEditor setProcessing relays
  // here -> the control engine's tray (set once by FlutterWindow). Mirrors macOS,
  // where the editor's Done/export drives the status-item processing pulse.
  // The label (localized, UTF-8) is the tray's hover tooltip while pulsing.
  // A .gif reached the image editor (drop / Open dialog / recents): Dart
  // forwards it here and FlutterWindow relays to the GIF editor window.
  void SetOpenGifRelay(std::function<void(const std::string&)> cb) {
    open_gif_relay_ = std::move(cb);
  }

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
  // Flush any pending load once the editor Dart signals 'editorReady'.
  void FlushPending();
  void InvokeLoadPath(const std::string& path);
  void InvokeLoadClipboard();

  flutter::DartProject project_;
  HWND control_hwnd_ = nullptr;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> role_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      editor_channel_;
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
  std::unique_ptr<EncodeChannel> encode_channel_;
  std::unique_ptr<SoundChannel> sound_channel_;

  bool ready_ = false;            // editor Dart has signalled editorReady
  bool pending_clipboard_ = false;
  std::optional<std::string> pending_path_;

  std::function<void(std::vector<std::string>)> recent_cb_;
  std::function<void(const std::string&)> open_gif_relay_;
  // Editor-export pulse (+ tooltip label) -> control tray.
  std::function<void(bool, const std::string&)> proc_cb_;
  PinManager* pin_manager_ = nullptr;
  // OLE drop target (EditorDropTarget): vetoes non-image drags at hover, the
  // same timing as macOS. Registered in OnCreate, revoked in OnDestroy.
  IDropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_EDITOR_WINDOW_H_
