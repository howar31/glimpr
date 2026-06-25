#include "encode_channel.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <optional>
#include <vector>

#include "decoration.h"
#include "image_codec.h"
#include "wgc_capturer.h"  // CaptureFrame

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool GetBool(const EncodableMap& map, const char* key, bool dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<bool>(v)) return *p;
  }
  return dflt;
}

int GetInt(const EncodableMap& map, const char* key, int dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return static_cast<int>(*p);
  }
  return dflt;
}

double GetDouble(const EncodableMap& map, const char* key, double dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return static_cast<double>(*p);
    if (auto p = std::get_if<int64_t>(v)) return static_cast<double>(*p);
  }
  return dflt;
}

std::optional<int64_t> GetInt64(const EncodableMap& map, const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
  }
  return std::nullopt;
}

const std::vector<uint8_t>* GetBytes(const EncodableMap& map, const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<std::vector<uint8_t>>(v)) return p;
  }
  return nullptr;
}

const EncodableMap* GetMap(const EncodableMap& map, const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<EncodableMap>(v)) return p;
  }
  return nullptr;
}

deco::DecoSpec ParseDecoSpec(const EncodableMap& m) {
  deco::DecoSpec s;
  s.margin = GetDouble(m, "margin", 0);
  s.cornerRadius = GetDouble(m, "cornerRadius", 0);
  s.shadowBlur = GetDouble(m, "shadowBlur", 0);
  s.shadowDx = GetDouble(m, "shadowDx", 0);
  s.shadowDy = GetDouble(m, "shadowDy", 0);
  if (auto c = GetInt64(m, "shadowColor")) s.shadowArgb = static_cast<uint32_t>(*c);
  if (auto f = GetInt64(m, "fill")) s.fillArgb = static_cast<uint32_t>(*f);
  s.shapeFromAlpha = GetBool(m, "shapeFromAlpha", false);
  return s;
}

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
