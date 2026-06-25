#include "capture_channel.h"

#include <windows.h>
#include <shellscalingapi.h>

#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "decoration.h"
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

std::optional<int64_t> GetInt64(const EncodableMap& map, const char* key) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
  }
  return std::nullopt;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()),
                      s.data(), n, nullptr, nullptr);
  return s;
}

std::string WindowTitle(HWND hwnd) {
  int len = GetWindowTextLengthW(hwnd);
  if (len <= 0) return {};
  std::wstring buf(static_cast<size_t>(len) + 1, L'\0');
  int got = GetWindowTextW(hwnd, buf.data(), len + 1);
  buf.resize(static_cast<size_t>(got));
  return Utf8(buf);
}

std::string ProcessName(HWND hwnd) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (!pid) return {};
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!h) return {};
  std::string name;
  wchar_t path[MAX_PATH] = {};
  DWORD sz = MAX_PATH;
  if (QueryFullProcessImageNameW(h, 0, path, &sz)) {
    std::wstring p(path, sz);
    size_t slash = p.find_last_of(L"\\/");
    std::wstring base = (slash == std::wstring::npos) ? p : p.substr(slash + 1);
    if (base.size() > 4 &&
        _wcsicmp(base.c_str() + base.size() - 4, L".exe") == 0) {
      base = base.substr(0, base.size() - 4);
    }
    name = Utf8(base);
  }
  CloseHandle(h);
  return name;
}

// The topmost real, foreign top-level window (skip our own windows + tool
// windows + invisible/tiny), so the in-app test button captures the window
// behind the Settings window rather than glimpr itself.
HWND PickForegroundWindow() {
  DWORD self = GetCurrentProcessId();
  HWND start = GetForegroundWindow();
  for (HWND w = start ? start : GetTopWindow(nullptr); w;
       w = GetWindow(w, GW_HWNDNEXT)) {
    if (!IsWindowVisible(w) || IsIconic(w)) continue;
    if (GetWindowLongPtr(w, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) continue;
    RECT rc{};
    if (!GetWindowRect(w, &rc)) continue;
    if (rc.right - rc.left < 40 || rc.bottom - rc.top < 40) continue;
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (pid == self) continue;
    return w;
  }
  return nullptr;
}

CaptureFrame CropFrame(const CaptureFrame& f, long px, long py, long pw,
                       long ph) {
  CaptureFrame out;
  if (px < 0) px = 0;
  if (py < 0) py = 0;
  if (px > static_cast<long>(f.width)) px = f.width;
  if (py > static_cast<long>(f.height)) py = f.height;
  if (pw > static_cast<long>(f.width) - px) pw = static_cast<long>(f.width) - px;
  if (ph > static_cast<long>(f.height) - py)
    ph = static_cast<long>(f.height) - py;
  if (pw <= 0 || ph <= 0) return out;
  out.width = static_cast<uint32_t>(pw);
  out.height = static_cast<uint32_t>(ph);
  out.stride = out.width * 4;
  out.bgra.resize(static_cast<size_t>(out.stride) * out.height);
  for (uint32_t row = 0; row < out.height; ++row) {
    const uint8_t* src = f.bgra.data() +
                         static_cast<size_t>(py + row) * f.stride +
                         static_cast<size_t>(px) * 4;
    std::memcpy(out.bgra.data() + static_cast<size_t>(row) * out.stride, src,
                out.stride);
  }
  return out;
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
  if (call.method_name() == "focusedWindow") {
    HandleFocusedWindow(call, std::move(result));
    return;
  }
  if (call.method_name() == "captureWindowDelivered") {
    HandleCaptureWindowDelivered(call, std::move(result));
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

  // The captured region: the whole frame, or a crop of the requested
  // display-local logical rect (converted to physical pixels). Echo the rect
  // back in logical points; left/top is the monitor's global logical origin.
  CaptureFrame work;
  double reply_x = 0.0;
  double reply_y = 0.0;
  double reply_w = frame->width / scale;
  double reply_h = frame->height / scale;
  if (HasKey(map, "w") && HasKey(map, "h")) {
    const double rx = GetDouble(map, "x", 0.0);
    const double ry = GetDouble(map, "y", 0.0);
    const double rw = GetDouble(map, "w", 0.0);
    const double rh = GetDouble(map, "h", 0.0);
    work = CropFrame(*frame, std::lround(rx * scale), std::lround(ry * scale),
                     std::lround(rw * scale), std::lround(rh * scale));
    if (!work.bgra.empty()) {
      reply_x = rx;
      reply_y = ry;
      reply_w = rw;
      reply_h = rh;
    }
  }
  if (work.bgra.empty()) work = std::move(*frame);

  // Optional native decoration; also encode the plain rendition for the pin leg.
  std::optional<CaptureFrame> decorated;
  std::vector<uint8_t> plain_bytes;
  const CaptureFrame* to_encode = &work;
  if (const auto* dmap = GetMap(map, "decoration")) {
    decorated = deco::Decorate(work, ParseDecoSpec(*dmap), scale);
    if (decorated) {
      to_encode = &*decorated;
      if (GetBool(map, "alsoPlain", false)) {
        plain_bytes =
            jpeg ? codec::EncodeJpeg(work.bgra.data(), work.width, work.height,
                                     work.stride, quality)
                 : codec::EncodePng(work.bgra.data(), work.width, work.height,
                                    work.stride);
      }
    }
  }

  std::vector<uint8_t> bytes =
      jpeg ? codec::EncodeJpeg(to_encode->bgra.data(), to_encode->width,
                               to_encode->height, to_encode->stride, quality)
           : codec::EncodePng(to_encode->bgra.data(), to_encode->width,
                              to_encode->height, to_encode->stride);
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
  if (!plain_bytes.empty()) {
    reply[EncodableValue("plainBytes")] = EncodableValue(std::move(plain_bytes));
  }
  result->Success(EncodableValue(std::move(reply)));
}

void CaptureChannel::HandleFocusedWindow(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  HWND hwnd = PickForegroundWindow();
  if (!hwnd) {
    result->Success(EncodableValue());
    return;
  }
  HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  const double scale = MonitorScale(mon);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  RECT rc{};
  GetWindowRect(hwnd, &rc);

  EncodableMap reply;
  reply[EncodableValue("displayId")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(mon)));
  reply[EncodableValue("x")] =
      EncodableValue(static_cast<double>(rc.left - mi.rcMonitor.left) / scale);
  reply[EncodableValue("y")] =
      EncodableValue(static_cast<double>(rc.top - mi.rcMonitor.top) / scale);
  reply[EncodableValue("w")] =
      EncodableValue(static_cast<double>(rc.right - rc.left) / scale);
  reply[EncodableValue("h")] =
      EncodableValue(static_cast<double>(rc.bottom - rc.top) / scale);
  reply[EncodableValue("title")] = EncodableValue(WindowTitle(hwnd));
  reply[EncodableValue("app")] = EncodableValue(ProcessName(hwnd));
  reply[EncodableValue("windowNumber")] =
      EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hwnd)));
  result->Success(EncodableValue(std::move(reply)));
}

void CaptureChannel::HandleCaptureWindowDelivered(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const EncodableMap empty;
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const EncodableMap& map = args ? *args : empty;

  const auto wid = GetInt64(map, "windowId");
  if (!wid || *wid == 0) {
    result->Success(EncodableValue());
    return;
  }
  HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(*wid));
  const bool show_cursor = GetBool(map, "showsCursor", false);
  const bool jpeg = GetBool(map, "jpeg", false);
  const int quality = GetInt(map, "quality", 90);

  std::optional<CaptureFrame> frame = wgc::CaptureWindow(hwnd, show_cursor);
  if (!frame) {
    // Fallback: capture the window's monitor and crop to the window rect.
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (auto monframe = wgc::CaptureMonitor(mon, show_cursor)) {
      MONITORINFO mi{};
      mi.cbSize = sizeof(MONITORINFO);
      GetMonitorInfo(mon, &mi);
      RECT rc{};
      GetWindowRect(hwnd, &rc);
      CaptureFrame cropped =
          CropFrame(*monframe, rc.left - mi.rcMonitor.left,
                    rc.top - mi.rcMonitor.top, rc.right - rc.left,
                    rc.bottom - rc.top);
      if (!cropped.bgra.empty()) frame = std::move(cropped);
    }
  }
  if (!frame) {
    result->Success(EncodableValue());
    return;
  }

  // Optional native decoration (window silhouette via shapeFromAlpha); the pin
  // leg consumes the plain rendition when requested.
  std::optional<CaptureFrame> decorated;
  std::vector<uint8_t> plain_bytes;
  const CaptureFrame* to_encode = &*frame;
  if (const auto* dmap = GetMap(map, "decoration")) {
    const double scale =
        MonitorScale(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
    decorated = deco::Decorate(*frame, ParseDecoSpec(*dmap), scale);
    if (decorated) {
      to_encode = &*decorated;
      if (GetBool(map, "alsoPlain", false)) {
        plain_bytes =
            jpeg ? codec::EncodeJpeg(frame->bgra.data(), frame->width,
                                     frame->height, frame->stride, quality)
                 : codec::EncodePng(frame->bgra.data(), frame->width,
                                    frame->height, frame->stride);
      }
    }
  }

  std::vector<uint8_t> bytes =
      jpeg ? codec::EncodeJpeg(to_encode->bgra.data(), to_encode->width,
                               to_encode->height, to_encode->stride, quality)
           : codec::EncodePng(to_encode->bgra.data(), to_encode->width,
                              to_encode->height, to_encode->stride);
  if (bytes.empty()) {
    result->Success(EncodableValue());
    return;
  }
  EncodableMap reply;
  reply[EncodableValue("bytes")] = EncodableValue(std::move(bytes));
  if (!plain_bytes.empty()) {
    reply[EncodableValue("plainBytes")] = EncodableValue(std::move(plain_bytes));
  }
  result->Success(EncodableValue(std::move(reply)));
}
