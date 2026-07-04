#include "capture_channel.h"

#include <windows.h>
#include <dwmapi.h>
#include <shellscalingapi.h>

#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstring>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <winrt/base.h>

#include "clipboard_channel.h"
#include "decoration.h"
#include "editor_window.h"
#include "image_codec.h"
#include "overlay_manager.h"
#include "perf_log.h"
#include "pin_window.h"
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
  // Carry the raw fp16 rendition (HDR captures) through the same crop.
  if (!f.f16.empty()) {
    out.sdr_white_nits = f.sdr_white_nits;
    out.max_nits = f.max_nits;
    const size_t src_stride = static_cast<size_t>(f.width) * 8;
    const size_t dst_stride = static_cast<size_t>(out.width) * 8;
    out.f16.resize(dst_stride * out.height);
    for (uint32_t row = 0; row < out.height; ++row) {
      const uint8_t* src = f.f16.data() +
                           static_cast<size_t>(py + row) * src_stride +
                           static_cast<size_t>(px) * 8;
      std::memcpy(out.f16.data() + static_cast<size_t>(row) * dst_stride, src,
                  dst_stride);
    }
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
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    RunCaptureAsync(args ? *args : EncodableMap(), /*window_leg=*/false,
                    std::move(result));
    return;
  }
  if (call.method_name() == "focusedWindow") {
    HandleFocusedWindow(call, std::move(result));
    return;
  }
  if (call.method_name() == "captureWindowDelivered") {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    RunCaptureAsync(args ? *args : EncodableMap(), /*window_leg=*/true,
                    std::move(result));
    return;
  }
  if (call.method_name() == "beginCapture") {
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    if (overlay_manager_) {
      overlay_manager_->BeginCapture(GetBool(map, "pinOnly", false),
                                     GetBool(map, "liveSelect", false));
    }
    result->Success();
    return;
  }
  if (call.method_name() == "recordSelectHotkey") {
    // A record hotkey while the record-select picker is up: relay to the overlay
    // engines so the picker resurfaces / cancels (mirrors macOS).
    if (overlay_manager_) overlay_manager_->RelayRecordSelectHotkey();
    result->Success();
    return;
  }
  if (call.method_name() == "openInEditor") {
    // The direct-capture flow's open-in-editor leg: reveal the editor + load the
    // saved/temp file.
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    if (const auto* v = Find(map, "path")) {
      if (const auto* path = std::get_if<std::string>(v)) {
        if (editor_window_) editor_window_->OpenWithPath(*path);
      }
    }
    result->Success();
    return;
  }
  if (call.method_name() == "recentChanged") {
    // A direct capture saved a file into the shared recent store -> tell the
    // editor engine to reload + re-push its list to the tray submenu.
    if (editor_window_) editor_window_->RefreshRecent();
    result->Success();
    return;
  }
  if (call.method_name() == "setProcessing") {
    // Direct-capture commit (true) / delivered (false): drive the tray's
    // logo-gradient processing pulse (mirrors macOS onCaptureProcessingChange).
    // The optional label becomes the tray's hover tooltip while pulsing.
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    std::string label;
    if (const auto* v = Find(map, "label")) {
      if (const auto* s = std::get_if<std::string>(v)) label = *s;
    }
    if (proc_cb_) proc_cb_(GetBool(map, "active", false), label);
    result->Success();
    return;
  }
  if (call.method_name() == "showError") {
    // The control engine (RecordController et al.) surfaces errors here. Without
    // this handler the call returned NotImplemented and the unawaited Future
    // swallowed it -> a failed recording looked like "no response". Mirrors the
    // overlay engine's showError (OverlayManager).
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    std::string msg;
    if (const auto* v = Find(map, "message")) {
      if (const auto* s = std::get_if<std::string>(v)) msg = *s;
    }
    std::wstring wmsg;
    int n = MultiByteToWideChar(CP_UTF8, 0, msg.c_str(), -1, nullptr, 0);
    if (n > 0) {
      wmsg.resize(static_cast<size_t>(n - 1));
      MultiByteToWideChar(CP_UTF8, 0, msg.c_str(), -1, wmsg.data(), n);
    }
    MessageBoxW(nullptr, wmsg.c_str(), L"Glimpr", MB_OK | MB_ICONWARNING);
    result->Success();
    return;
  }
  if (call.method_name() == "perfMark") {
    // Dart-side perf marks (direct-capture delivery etc.) land on the same
    // timeline as the native marks. Inert unless the debugHooks gate is on.
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    if (const auto* v = Find(map, "label")) {
      if (const auto* s = std::get_if<std::string>(v)) perf::Mark(*s);
    }
    result->Success();
    return;
  }
  if (call.method_name() == "pinImage") {
    // The capture flow's pin leg: float [path] as a pin, in place over the
    // captured region when x/y/w/h are present, else centered.
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& map = args ? *args : empty;
    std::string path;
    if (const auto* v = Find(map, "path")) {
      if (const auto* p = std::get_if<std::string>(v)) path = *p;
    }
    if (!path.empty() && pin_manager_) {
      std::optional<RECT> place;
      if (HasKey(map, "w") && HasKey(map, "h")) {
        const double x = GetDouble(map, "x", 0.0);
        const double y = GetDouble(map, "y", 0.0);
        const double w = GetDouble(map, "w", 0.0);
        const double h = GetDouble(map, "h", 0.0);
        place = RECT{static_cast<LONG>(std::lround(x)),
                     static_cast<LONG>(std::lround(y)),
                     static_cast<LONG>(std::lround(x + w)),
                     static_cast<LONG>(std::lround(y + h))};
      }
      pin_manager_->Pin(path, place);
    }
    result->Success();
    return;
  }
  result->NotImplemented();
}

void CaptureChannel::RunCaptureAsync(
    EncodableMap args, bool window_leg,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (!control_hwnd_) {
    // No marshal target yet (never in practice: SetControlHwnd runs at window
    // creation) -> the old synchronous path.
    EncodableValue reply =
        window_leg ? ComputeWindowDelivered(args) : ComputeRegionCapture(args);
    result->Success(std::move(reply));
    return;
  }
  // The result must complete on the platform thread; hand it to a worker via
  // shared_ptr, marshal the finished reply back with WM_GLIMPR_CAPTURE.
  std::shared_ptr<flutter::MethodResult<EncodableValue>> shared(
      result.release());
  std::thread([this, args = std::move(args), shared, window_leg]() {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
    } catch (...) {
    }
    EncodableValue reply =
        window_leg ? ComputeWindowDelivered(args) : ComputeRegionCapture(args);
    {
      std::lock_guard<std::mutex> lock(done_mutex_);
      done_.emplace_back(shared, std::move(reply));
    }
    PostMessage(control_hwnd_, WM_GLIMPR_CAPTURE, 0, 0);
    winrt::uninit_apartment();
  }).detach();
}

void CaptureChannel::OnAsyncDone() {
  std::vector<std::pair<std::shared_ptr<flutter::MethodResult<EncodableValue>>,
                        EncodableValue>>
      jobs;
  {
    std::lock_guard<std::mutex> lock(done_mutex_);
    jobs.swap(done_);
  }
  for (auto& job : jobs) job.first->Success(std::move(job.second));
}

EncodableValue CaptureChannel::ComputeRegionCapture(const EncodableMap& map) {
  perf::Mark("regionCaptureBegin");
  const bool jpeg = GetBool(map, "jpeg", false);
  const int quality = GetInt(map, "quality", 90);
  const bool show_cursor = GetBool(map, "showsCursor", false);
  // Dual-output HDR: keep the raw fp16 rendition (HDR monitors only) and
  // return it JXR-encoded beside the SDR bytes.
  const bool want_hdr = GetBool(map, "hdr", false);
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
  if (!mon) return EncodableValue();

  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonitorScale(mon);

  auto frame = wgc::CaptureMonitor(mon, show_cursor, want_hdr);
  if (!frame) return EncodableValue();
  perf::Mark("regionWgcFrame w=" + std::to_string(frame->width) +
             " h=" + std::to_string(frame->height));

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
  if (bytes.empty()) return EncodableValue();
  perf::Mark("regionEncodeDone bytes=" + std::to_string(bytes.size()));

  // The flow's clipboard leg, done natively from the BGRA in hand: writeImage
  // over the channel has to DECODE the encoded bytes back to pixels for the
  // CF_DIBV5 (baseline 369ms on a 4K PNG); here both forms already exist.
  bool copied = false;
  if (GetBool(map, "alsoCopy", false)) {
    copied = clip::WriteBgraToClipboard(
        to_encode->bgra.data(), to_encode->width, to_encode->height,
        to_encode->stride, jpeg ? nullptr : bytes.data(),
        jpeg ? 0 : bytes.size());
    perf::Mark(copied ? "nativeCopyDone ok=1" : "nativeCopyDone ok=0");
  }

  // The HDR sibling: the UNDECORATED fp16 crop as JPEG XR (empty when the
  // monitor is SDR or the encode fails -> the reply simply omits it).
  std::vector<uint8_t> hdr_bytes;
  if (want_hdr && !work.f16.empty()) {
    hdr_bytes =
        codec::EncodeJxr(work.f16.data(), work.width, work.height,
                         work.width * 8);
  }

  const double left = mi.rcMonitor.left / scale;
  const double top = mi.rcMonitor.top / scale;

  EncodableMap reply;
  reply[EncodableValue("copied")] = EncodableValue(copied);
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
  if (!hdr_bytes.empty()) {
    reply[EncodableValue("hdrBytes")] = EncodableValue(std::move(hdr_bytes));
    reply[EncodableValue("hdrExt")] = EncodableValue("jxr");
  }
  return EncodableValue(std::move(reply));
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
  // Visible bounds (exclude the invisible resize border + DWM shadow), so the
  // rect-crop fallback and the saved last-region match what the user sees.
  RECT rc{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc,
                                   sizeof(rc)))) {
    GetWindowRect(hwnd, &rc);
  }

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

EncodableValue CaptureChannel::ComputeWindowDelivered(
    const EncodableMap& map) {
  const auto wid = GetInt64(map, "windowId");
  if (!wid || *wid == 0) return EncodableValue();
  HWND hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(*wid));
  perf::Mark("windowCaptureBegin");
  const bool show_cursor = GetBool(map, "showsCursor", false);
  const bool jpeg = GetBool(map, "jpeg", false);
  const int quality = GetInt(map, "quality", 90);
  const bool want_hdr = GetBool(map, "hdr", false);

  // WGC's window capture already returns exactly the visible window (its frame
  // size equals DWMWA_EXTENDED_FRAME_BOUNDS), with the real rounded corners
  // transparent (faithful capture) -- so it is used as-is. The extended frame
  // bounds are only needed by the rect-crop fallback below.
  std::optional<CaptureFrame> frame =
      wgc::CaptureWindow(hwnd, show_cursor, want_hdr);
  if (!frame) {
    RECT efb{};
    if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &efb,
                                     sizeof(efb)))) {
      GetWindowRect(hwnd, &efb);
    }
    // Fallback: capture the window's monitor and crop to the visible bounds.
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (auto monframe = wgc::CaptureMonitor(mon, show_cursor, want_hdr)) {
      MONITORINFO mi{};
      mi.cbSize = sizeof(MONITORINFO);
      GetMonitorInfo(mon, &mi);
      CaptureFrame cropped = CropFrame(
          *monframe, efb.left - mi.rcMonitor.left, efb.top - mi.rcMonitor.top,
          efb.right - efb.left, efb.bottom - efb.top);
      if (!cropped.bgra.empty()) frame = std::move(cropped);
    }
  }
  if (!frame) return EncodableValue();
  perf::Mark("windowWgcFrame w=" + std::to_string(frame->width) +
             " h=" + std::to_string(frame->height));

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
  if (bytes.empty()) return EncodableValue();
  perf::Mark("windowEncodeDone bytes=" + std::to_string(bytes.size()));
  // Native clipboard leg from the in-hand BGRA (see ComputeRegionCapture).
  bool copied = false;
  if (GetBool(map, "alsoCopy", false)) {
    copied = clip::WriteBgraToClipboard(
        to_encode->bgra.data(), to_encode->width, to_encode->height,
        to_encode->stride, jpeg ? nullptr : bytes.data(),
        jpeg ? 0 : bytes.size());
    perf::Mark(copied ? "nativeCopyDone ok=1" : "nativeCopyDone ok=0");
  }
  // The HDR sibling: the UNDECORATED fp16 window capture as JPEG XR.
  std::vector<uint8_t> hdr_bytes;
  if (want_hdr && !frame->f16.empty()) {
    hdr_bytes = codec::EncodeJxr(frame->f16.data(), frame->width,
                                 frame->height, frame->width * 8);
  }
  EncodableMap reply;
  reply[EncodableValue("copied")] = EncodableValue(copied);
  reply[EncodableValue("bytes")] = EncodableValue(std::move(bytes));
  if (!plain_bytes.empty()) {
    reply[EncodableValue("plainBytes")] = EncodableValue(std::move(plain_bytes));
  }
  if (!hdr_bytes.empty()) {
    reply[EncodableValue("hdrBytes")] = EncodableValue(std::move(hdr_bytes));
    reply[EncodableValue("hdrExt")] = EncodableValue("jxr");
  }
  return EncodableValue(std::move(reply));
}
