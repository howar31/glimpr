#ifndef RUNNER_CAPTURE_CHANNEL_H_
#define RUNNER_CAPTURE_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

class OverlayManager;
class EditorWindow;
class PinManager;

// Async direct-capture completion marshal: a worker thread finished a capture
// and posted this; FlutterWindow routes it to CaptureChannel::OnAsyncDone,
// which completes the MethodResult on the platform thread (Flutter method
// results are not thread-safe). WM_APP+1/2 are the tray / record messages.
#define WM_GLIMPR_CAPTURE (WM_APP + 3)

// Hosts the "glimpr/capture" method channel: native direct screen capture
// (display / window / region) returning encoded image bytes to Dart, plus the
// interactive freeze-overlay trigger (beginCapture -> OverlayManager). Mirrors
// the macOS CaptureChannel + CaptureController; in-runner, not a pub plugin.
class CaptureChannel {
 public:
  explicit CaptureChannel(flutter::BinaryMessenger* messenger);
  ~CaptureChannel();

  CaptureChannel(const CaptureChannel&) = delete;
  CaptureChannel& operator=(const CaptureChannel&) = delete;

  // The control engine drives the freeze overlay through this manager (set once
  // by FlutterWindow after the OverlayManager is constructed).
  void SetOverlayManager(OverlayManager* manager) { overlay_manager_ = manager; }

  // The standalone editor the direct-capture flow's open-in-editor leg reveals,
  // and the target of the recents-changed relay (set once by FlutterWindow).
  void SetEditorWindow(EditorWindow* editor) { editor_window_ = editor; }

  // The shared pin manager the direct-capture flow's pin leg uses.
  void SetPinManager(PinManager* pins) { pin_manager_ = pins; }

  // The control HWND that receives WM_GLIMPR_CAPTURE (set once by
  // FlutterWindow::OnCreate, before any capture can be triggered). Without it
  // captures fall back to the old synchronous in-handler path.
  void SetControlHwnd(HWND hwnd) { control_hwnd_ = hwnd; }

  // Routed from FlutterWindow::MessageHandler on WM_GLIMPR_CAPTURE: completes
  // finished async captures' method results on the platform thread.
  void OnAsyncDone();

  // The direct-capture "processing" pulse: glimpr/capture setProcessing routes
  // here -> the control engine's tray (set once by FlutterWindow). Mirrors macOS
  // onCaptureProcessingChange. The interactive overlay path relays separately
  // (OverlayManager::SetProcessingRelay), but both land on the same tray.
  // The label (localized, UTF-8) is the tray's hover tooltip while pulsing.
  void SetProcessingCallback(std::function<void(bool, const std::string&)> cb) {
    proc_cb_ = std::move(cb);
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleFocusedWindow(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Runs the capture (WGC + crop + decorate + encode) OFF the platform thread
  // and completes the result via WM_GLIMPR_CAPTURE -- the synchronous version
  // blocked every Flutter engine for the whole pipeline (measured 685ms encode
  // alone on a 4K PNG). [window_leg] picks ComputeWindowDelivered.
  void RunCaptureAsync(
      flutter::EncodableMap args, bool window_leg,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableValue ComputeRegionCapture(
      const flutter::EncodableMap& map);
  flutter::EncodableValue ComputeWindowDelivered(
      const flutter::EncodableMap& map);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  OverlayManager* overlay_manager_ = nullptr;  // not owned
  EditorWindow* editor_window_ = nullptr;      // not owned
  PinManager* pin_manager_ = nullptr;          // not owned
  HWND control_hwnd_ = nullptr;                // async completion target
  // Finished async captures awaiting platform-thread completion.
  std::mutex done_mutex_;
  std::vector<std::pair<
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>,
      flutter::EncodableValue>>
      done_;
  // Direct-capture pulse (+ tooltip label) -> control tray.
  std::function<void(bool, const std::string&)> proc_cb_;
};

#endif  // RUNNER_CAPTURE_CHANNEL_H_
