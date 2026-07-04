#include "encode_channel.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <vector>

#include "channel_args.h"
#include "deco_args.h"
#include "decoration.h"
#include "image_codec.h"
#include "wgc_capturer.h"  // CaptureFrame

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace chanarg;

// The editor composites in RGBA8888 (dart:ui rawRgba); the native codec +
// decoration take BGRA. Swap R<->B (G, A unchanged); alpha sense is preserved.
std::vector<uint8_t> RgbaToBgra(const std::vector<uint8_t>& rgba) {
  std::vector<uint8_t> bgra = rgba;
  for (size_t i = 0; i + 3 < bgra.size(); i += 4) {
    std::swap(bgra[i], bgra[i + 2]);
  }
  return bgra;
}

}  // namespace

EncodeChannel::EncodeChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/encode",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

EncodeChannel::~EncodeChannel() = default;

void EncodeChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const EncodableMap empty;
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& map = args ? *args : empty;
  const std::string& method = call.method_name();

  if (method != "png" && method != "jpeg" && method != "decorate") {
    result->NotImplemented();
    return;
  }

  const auto* rgba = GetBytes(map, "rgba");
  const int width = GetInt(map, "width", 0);
  const int height = GetInt(map, "height", 0);
  if (!rgba || width <= 0 || height <= 0 ||
      rgba->size() < static_cast<size_t>(width) * height * 4) {
    result->Success(EncodableValue());  // null -> Dart falls back
    return;
  }

  std::vector<uint8_t> bgra = RgbaToBgra(*rgba);
  const uint32_t w = static_cast<uint32_t>(width);
  const uint32_t h = static_cast<uint32_t>(height);
  const uint32_t stride = w * 4;

  // `decorate` wraps the content first; png/jpeg encode it straight.
  CaptureFrame decorated;
  const uint8_t* enc_bgra = bgra.data();
  uint32_t enc_w = w, enc_h = h, enc_stride = stride;
  bool jpeg = (method == "jpeg");

  if (method == "decorate") {
    jpeg = GetBool(map, "jpeg", false);
    const double scale = GetDouble(map, "scale", 1.0);
    if (const auto* dmap = GetMap(map, "decoration")) {
      CaptureFrame content;
      content.bgra = std::move(bgra);
      content.width = w;
      content.height = h;
      content.stride = stride;
      if (auto out = deco::Decorate(content, ParseDecoSpec(*dmap), scale)) {
        decorated = std::move(*out);
        enc_bgra = decorated.bgra.data();
        enc_w = decorated.width;
        enc_h = decorated.height;
        enc_stride = decorated.stride;
      } else {
        // Decoration failed -> let Dart fall back rather than ship plain pixels.
        result->Success(EncodableValue());
        return;
      }
    }
  }

  const int quality = GetInt(map, "quality", 90);
  std::vector<uint8_t> bytes =
      jpeg ? codec::EncodeJpeg(enc_bgra, enc_w, enc_h, enc_stride, quality)
           : codec::EncodePng(enc_bgra, enc_w, enc_h, enc_stride);
  if (bytes.empty()) {
    result->Success(EncodableValue());
    return;
  }
  result->Success(EncodableValue(std::move(bytes)));
}
