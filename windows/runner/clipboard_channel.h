#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Hosts the "glimpr/clipboard" method channel: write an encoded image
// (PNG/JPEG bytes) to the system clipboard. Mirrors the macOS clipboard seam.
class ClipboardChannel {
 public:
  explicit ClipboardChannel(flutter::BinaryMessenger* messenger);
  ~ClipboardChannel();

  ClipboardChannel(const ClipboardChannel&) = delete;
  ClipboardChannel& operator=(const ClipboardChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
