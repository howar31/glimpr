#ifndef RUNNER_ENCODE_CHANNEL_H_
#define RUNNER_ENCODE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Hosts "glimpr/encode": native PNG/JPEG encode + Direct2D decoration of the
// editor-composited image (RGBA in), so the overlay/editor export uses the same
// fast native path as the S2a direct modes instead of the pure-Dart fallback.
// Mirrors the macOS EncodeChannel. Registered on engines that composite.
class EncodeChannel {
 public:
  explicit EncodeChannel(flutter::BinaryMessenger* messenger);
  ~EncodeChannel();

  EncodeChannel(const EncodeChannel&) = delete;
  EncodeChannel& operator=(const EncodeChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_ENCODE_CHANNEL_H_
