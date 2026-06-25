#include "capture_channel.h"

#include <windows.h>
#include <shellscalingapi.h>

#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstring>
#include <optional>
#include <utility>
#include <vector>

#include "image_codec.h"
#include "wgc_capturer.h"

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

std::optional<int64_t> GetDisplayId(const EncodableMap& map) {
  if (const auto* v = Find(map, "displayId")) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
  }
  return std::nullopt;
}

double GetDouble(const EncodableMap& map, const char* key, double dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return static_cast<double>(*p);
    if (auto p = std::get_if<int64_t>(v)) return static_cast<double>(*p);
  }
  return dflt;
}

bool HasKey(const EncodableMap& map, const char* key) {
  return Find(map, key) != nullptr;
}

double MonitorScale(HMONITOR mon) {
  UINT dpi_x = 96, dpi_y = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y))) {
    dpi_x = 96;
  }
  return dpi_x / 96.0;
}

}  // namespace

CaptureChannel::CaptureChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/capture",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

CaptureChannel::~CaptureChannel() = default;

void CaptureChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "captureRegion") {
    HandleCaptureRegion(call, std::move(result));
    return;
  }
  result->NotImplemented();
}

void CaptureChannel::HandleCaptureRegion(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const EncodableMap empty;
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& map = args ? *args : empty;

  const bool jpeg = GetBool(map, "jpeg", false);
  const int quality = GetInt(map, "quality", 90);
  const bool show_cursor = GetBool(map, "showsCursor", false);
  const std::optional<int64_t> display_id = GetDisplayId(map);

  // Resolve the monitor: an explicit displayId (an HMONITOR round-tripped as an
  // int), else the monitor under the cursor.
  HMONITOR mon = nullptr;
  if (display_id && *display_id != 0) {
    mon = reinterpret_cast<HMONITOR>(static_cast<intptr_t>(*display_id));
    MONITORINFO check{};
    check.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(mon, &check)) mon = nullptr;
  }
  if (!mon) {
    POINT pt{};
    GetCursorPos(&pt);
    mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  }
  if (!mon) {
    result->Success(EncodableValue());
    return;
  }

  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonitorScale(mon);

  auto frame = wgc::CaptureMonitor(mon, show_cursor);
  if (!frame) {
    result->Success(EncodableValue());
    return;
  }

  // Encode the whole frame, or a crop of the requested display-local logical
  // rect (converted to physical pixels). Echo the captured rect back in
  // logical points; left/top is the monitor's global logical origin.
  const uint8_t* enc_data = frame->bgra.data();
  uint32_t enc_w = frame->width;
  uint32_t enc_h = frame->height;
  uint32_t enc_stride = frame->stride;
  std::vector<uint8_t> cropped;
  double reply_x = 0.0;
  double reply_y = 0.0;
  double reply_w = frame->width / scale;
  double reply_h = frame->height / scale;

  if (HasKey(map, "w") && HasKey(map, "h")) {
    const double rx = GetDouble(map, "x", 0.0);
    const double ry = GetDouble(map, "y", 0.0);
    const double rw = GetDouble(map, "w", 0.0);
    const double rh = GetDouble(map, "h", 0.0);
    long px = std::lround(rx * scale);
    long py = std::lround(ry * scale);
    long pw = std::lround(rw * scale);
    long ph = std::lround(rh * scale);
    if (px < 0) px = 0;
    if (py < 0) py = 0;
    if (px > static_cast<long>(frame->width)) px = frame->width;
    if (py > static_cast<long>(frame->height)) py = frame->height;
    if (pw > static_cast<long>(frame->width) - px)
      pw = static_cast<long>(frame->width) - px;
    if (ph > static_cast<long>(frame->height) - py)
      ph = static_cast<long>(frame->height) - py;
    if (pw > 0 && ph > 0) {
      const uint32_t cw = static_cast<uint32_t>(pw);
      const uint32_t ch = static_cast<uint32_t>(ph);
      cropped.resize(static_cast<size_t>(cw) * 4 * ch);
      for (uint32_t row = 0; row < ch; ++row) {
        const uint8_t* src = frame->bgra.data() +
                             static_cast<size_t>(py + row) * frame->stride +
                             static_cast<size_t>(px) * 4;
        std::memcpy(cropped.data() + static_cast<size_t>(row) * cw * 4, src,
                    static_cast<size_t>(cw) * 4);
      }
      enc_data = cropped.data();
      enc_w = cw;
      enc_h = ch;
      enc_stride = cw * 4;
      reply_x = rx;
      reply_y = ry;
      reply_w = rw;
      reply_h = rh;
    }
  }

  std::vector<uint8_t> bytes =
      jpeg ? codec::EncodeJpeg(enc_data, enc_w, enc_h, enc_stride, quality)
           : codec::EncodePng(enc_data, enc_w, enc_h, enc_stride);
  if (bytes.empty()) {
    result->Success(EncodableValue());
    return;
  }

  const double left = mi.rcMonitor.left / scale;
  const double top = mi.rcMonitor.top / scale;

  EncodableMap reply;
  reply[EncodableValue("bytes")] = EncodableValue(std::move(bytes));
  reply[EncodableValue("displayId")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(mon)));
  reply[EncodableValue("x")] = EncodableValue(reply_x);
  reply[EncodableValue("y")] = EncodableValue(reply_y);
  reply[EncodableValue("w")] = EncodableValue(reply_w);
  reply[EncodableValue("h")] = EncodableValue(reply_h);
  reply[EncodableValue("left")] = EncodableValue(left);
  reply[EncodableValue("top")] = EncodableValue(top);
  reply[EncodableValue("scaleFactor")] = EncodableValue(scale);
  result->Success(EncodableValue(std::move(reply)));
}
