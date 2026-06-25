#include "capture_channel.h"

#include <windows.h>
#include <shellscalingapi.h>

#include <flutter/standard_method_codec.h>

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

  // T2: whole display (the requested rect is applied as a crop in Task 3).
  auto frame = wgc::CaptureMonitor(mon, show_cursor);
  if (!frame) {
    result->Success(EncodableValue());
    return;
  }

  std::vector<uint8_t> bytes =
      jpeg ? codec::EncodeJpeg(frame->bgra.data(), frame->width, frame->height,
                               frame->stride, quality)
           : codec::EncodePng(frame->bgra.data(), frame->width, frame->height,
                               frame->stride);
  if (bytes.empty()) {
    result->Success(EncodableValue());
    return;
  }

  const double logical_w = frame->width / scale;
  const double logical_h = frame->height / scale;
  const double left = mi.rcMonitor.left / scale;
  const double top = mi.rcMonitor.top / scale;

  EncodableMap reply;
  reply[EncodableValue("bytes")] = EncodableValue(std::move(bytes));
  reply[EncodableValue("displayId")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(mon)));
  reply[EncodableValue("x")] = EncodableValue(0.0);
  reply[EncodableValue("y")] = EncodableValue(0.0);
  reply[EncodableValue("w")] = EncodableValue(logical_w);
  reply[EncodableValue("h")] = EncodableValue(logical_h);
  reply[EncodableValue("left")] = EncodableValue(left);
  reply[EncodableValue("top")] = EncodableValue(top);
  reply[EncodableValue("scaleFactor")] = EncodableValue(scale);
  result->Success(EncodableValue(std::move(reply)));
}
