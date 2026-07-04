#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>

namespace clip {
// Write BGRA pixels to the clipboard as CF_DIBV5, plus the already-encoded
// PNG under the registered "PNG" format when [png] is non-null -- NO decode
// pass (the writeImage channel method has to decode its encoded bytes back to
// pixels; native capture flows hold both forms and skip that entirely).
// Thread-safe from any thread (the clipboard is not thread-affine).
bool WriteBgraToClipboard(const uint8_t* bgra, uint32_t w, uint32_t h,
                          uint32_t stride, const uint8_t* png, size_t png_len);
}  // namespace clip

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
