#ifndef RUNNER_CAPTURE_CHANNEL_H_
#define RUNNER_CAPTURE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Hosts the "glimpr/capture" method channel: native direct screen capture
// (display / window / region) returning encoded image bytes to Dart. Mirrors
// the macOS CaptureChannel; in-runner, not a pub plugin.
class CaptureChannel {
 public:
  explicit CaptureChannel(flutter::BinaryMessenger* messenger);
  ~CaptureChannel();

  CaptureChannel(const CaptureChannel&) = delete;
  CaptureChannel& operator=(const CaptureChannel&) = delete;

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
};

#endif  // RUNNER_CAPTURE_CHANNEL_H_
