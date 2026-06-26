#ifndef RUNNER_CAPTURE_CHANNEL_H_
#define RUNNER_CAPTURE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class OverlayManager;
class EditorWindow;
class PinManager;

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

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleCaptureRegion(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleFocusedWindow(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleCaptureWindowDelivered(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  OverlayManager* overlay_manager_ = nullptr;  // not owned
  EditorWindow* editor_window_ = nullptr;      // not owned
  PinManager* pin_manager_ = nullptr;          // not owned
};

#endif  // RUNNER_CAPTURE_CHANNEL_H_
