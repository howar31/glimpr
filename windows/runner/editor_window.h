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
#include "editor_placement.h"
#include "encode_channel.h"
#include "sound_channel.h"
#include "win32_window.h"

struct IDropTarget;

// The editor host process's way out to the main process (editor_host.h).
// Everything the editor needs from the resident side (tray recents, pins, the
// processing pulse, Settings) is a one-way message; nothing waits for a reply.
class EditorHostLink {
 public:
  virtual ~EditorHostLink() = default;
  // Proxy a main-process-bound glimpr/imageEditor method with its arguments.
  virtual void Call(const std::string& method,
                    const flutter::EncodableValue& args) = 0;
  // The editor Dart signalled editorReady: the host can take requests.
  virtual void Ready() = 0;
  // The editor window went hidden (Dart hideEditor): arm the exit gate.
  virtual void Hidden() = 0;
  // The editor window was revealed: cancel a pending exit.
  virtual void Shown() = 0;
  virtual DWORD main_pid() const = 0;
};

// The standalone Image Editor: a revealable top-level window hosting its OWN
// Flutter engine (role 'image-editor'). Mirrors the macOS editor window. On
// Windows it lives in a per-open child process (editor_host.h): built hidden
// at process start, shown once the first frame has rendered, and the process
// exits after the window closes, so the OS reclaims the engine's memory.
class EditorWindow : public Win32Window {
 public:
  EditorWindow(const flutter::DartProject& project, EditorHostLink* link);
  ~EditorWindow() override;

  EditorWindow(const EditorWindow&) = delete;
  EditorWindow& operator=(const EditorWindow&) = delete;

  // Build the engine + hidden window now. Idempotent.
  void WarmUp();
  // Reveal the editor (creates the engine if WarmUp has not run yet). The
  // first reveal of this process waits for the first rendered frame.
  void RevealEditor();
  // Reveal + load an image file (buffered until the editor Dart is ready).
  void OpenWithPath(const std::string& path);
  // Reveal + load the clipboard image.
  void LoadClipboard();

  // Ask the editor Dart to clear its recent list (tray "Clear Recent").
  void ClearRecent();
  // Ask the editor Dart to reload + re-push its recent list (a capture flow
  // saved a file). Dropped harmlessly before the engine exists.
  void RefreshRecent();

  // Window placement carried over from the previous editor host; applied on
  // the first reveal.
  void ApplyPlacement(const eplace::Placement& p) { placement_ = p; }
  // The current placement (normal-position rect + maximized), for the next
  // host. False without a window.
  bool GetPlacement(eplace::Placement* out) const;
  // Exit-gate inputs: an export / GIF encode is in flight; the window is not
  // visible.
  bool processing() const { return processing_; }
  bool IsHidden() const;

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
  EditorHostLink* link_;  // not owned; outlives this window

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> role_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      editor_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      fonts_channel_;
  std::unique_ptr<ClipboardChannel> clipboard_channel_;
  std::unique_ptr<EncodeChannel> encode_channel_;
  std::unique_ptr<SoundChannel> sound_channel_;

  bool ready_ = false;            // editor Dart has signalled editorReady
  bool pending_clipboard_ = false;
  std::optional<std::string> pending_path_;
  bool shown_once_ = false;   // the first-frame reveal has happened
  bool processing_ = false;   // Dart setProcessing(active)
  std::optional<eplace::Placement> placement_;
  // Captured right before the window hides (a hidden window no longer
  // reports whether it was maximized).
  std::optional<eplace::Placement> last_placement_;
  void CapturePlacement();
  // OLE drop target (EditorDropTarget): vetoes non-image drags at hover, the
  // same timing as macOS. Registered in OnCreate, revoked in OnDestroy.
  IDropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_EDITOR_WINDOW_H_
