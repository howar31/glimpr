#include "recorder.h"

#include <d3d11.h>
#include <dxgi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shellscalingapi.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.Graphics.DirectX.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <thread>

namespace {

namespace cap = winrt::Windows::Graphics::Capture;
namespace dx = winrt::Windows::Graphics::DirectX;
namespace d3d = winrt::Windows::Graphics::DirectX::Direct3D11;

// Bits-per-pixel quality tiers -- MUST match macOS (RecordingController) so the
// cross-platform output behaviour is identical.
double BppFor(const std::string& q) {
  if (q == "low") return 0.045;
  if (q == "medium") return 0.09;
  return 0.18;  // high (default)
}

uint32_t EvenDown(uint32_t v) { return v & ~1u; }

double MonScale(HMONITOR mon) {
  UINT dx_ = 96, dy_ = 96;
  if (FAILED(GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, &dx_, &dy_))) dx_ = 96;
  return dx_ / 96.0;
}

winrt::com_ptr<ID3D11Device> CreateD3DDevice() {
  winrt::com_ptr<ID3D11Device> device;
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                      D3D_FEATURE_LEVEL_11_0};
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2, D3D11_SDK_VERSION,
      device.put(), nullptr, nullptr);
  if (FAILED(hr)) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels, 2,
                           D3D11_SDK_VERSION, device.put(), nullptr, nullptr);
  }
  return SUCCEEDED(hr) ? device : nullptr;
}

d3d::IDirect3DDevice WrapDevice(winrt::com_ptr<ID3D11Device> const& device) {
  auto dxgi = device.as<IDXGIDevice>();
  winrt::com_ptr<::IInspectable> inspectable;
  winrt::check_hresult(
      CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
  return inspectable.as<d3d::IDirect3DDevice>();
}

winrt::com_ptr<IGraphicsCaptureItemInterop> GetInterop() {
  auto factory = winrt::get_activation_factory<cap::GraphicsCaptureItem>();
  return factory.as<IGraphicsCaptureItemInterop>();
}

// A captured frame copied off the GPU: capture-size BGRA8888 (top-down,
// stride = width*4) plus its capture timestamp (QPC-based 100ns ticks).
struct QueuedFrame {
  std::vector<uint8_t> bgra;
  LONGLONG ts100ns = 0;
};

}  // namespace

struct Recorder::Impl {
  // ---- capture (Windows.Graphics.Capture) --------------------------------
  winrt::com_ptr<ID3D11Device> device;
  winrt::com_ptr<ID3D11DeviceContext> context;
  winrt::com_ptr<ID3D11Texture2D> staging;  // reused readback target
  cap::GraphicsCaptureItem item{nullptr};
  cap::Direct3D11CaptureFramePool pool{nullptr};
  cap::GraphicsCaptureSession session{nullptr};
  winrt::event_token frame_token{};
  uint32_t cap_w = 0, cap_h = 0;  // capture (source) pixels

  // ---- encode (Media Foundation IMFSinkWriter) ---------------------------
  bool mf_started = false;
  winrt::com_ptr<IMFSinkWriter> writer;
  DWORD video_stream = 0;
  uint32_t out_w = 0, out_h = 0;  // encoded (possibly capped) pixels
  LONGLONG frame_interval = 0;    // 100ns per target frame (fps throttle/dur)

  // ---- timeline ----------------------------------------------------------
  std::atomic<LONGLONG> session_start{-1};  // first frame ts (100ns)
  LONGLONG paused_accum = 0;                // S6b; 0 in S6a
  LONGLONG last_enqueued = -1;              // throttle gate

  // ---- worker / queue ----------------------------------------------------
  std::thread encoder;
  std::mutex queue_mutex;
  std::condition_variable queue_cv;
  std::deque<QueuedFrame> queue;
  std::atomic<bool> stop_requested{false};
  std::mutex readback_mutex;  // serialize the immediate-context Map across pool threads

  // ---- async error -------------------------------------------------------
  HWND async_target = nullptr;
  UINT async_msg = 0;
  std::mutex error_mutex;
  std::string async_error;
  std::atomic<bool> failed{false};

  std::wstring output_path_w;

  void EncoderLoop();
  void OnFrameArrived();
  void Cleanup();
};

Recorder::Recorder() : impl_(std::make_unique<Impl>()) {}
Recorder::~Recorder() {
  if (active_) Abort();
}

std::string Recorder::TakeAsyncError() {
  std::lock_guard<std::mutex> lock(impl_->error_mutex);
  std::string e = std::move(impl_->async_error);
  impl_->async_error.clear();
  return e;
}

void Recorder::Impl::OnFrameArrived() {
  std::vector<uint8_t> buffer;
  LONGLONG ts = 0;
  {
    std::lock_guard<std::mutex> lock(readback_mutex);
    auto frame = pool.TryGetNextFrame();
    if (!frame) return;
    ts = frame.SystemRelativeTime().count();

    // Throttle to the target fps (VFR keeps the real timestamps; this only caps
    // the rate so a 144Hz monitor does not flood the encoder + file).
    if (last_enqueued >= 0 && (ts - last_enqueued) < frame_interval) return;
    last_enqueued = ts;

    auto access = frame.Surface()
                      .as<::Windows::Graphics::DirectX::Direct3D11::
                              IDirect3DDxgiInterfaceAccess>();
    winrt::com_ptr<ID3D11Texture2D> texture;
    if (FAILED(access->GetInterface(__uuidof(ID3D11Texture2D),
                                    texture.put_void()))) {
      return;
    }
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (desc.Width != cap_w || desc.Height != cap_h || !staging) return;

    context->CopyResource(staging.get(), texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return;
    }
    const uint32_t stride = cap_w * 4;
    buffer.resize(static_cast<size_t>(stride) * cap_h);
    const auto* src = static_cast<const uint8_t*>(mapped.pData);
    for (uint32_t y = 0; y < cap_h; ++y) {
      std::memcpy(buffer.data() + static_cast<size_t>(y) * stride,
                  src + static_cast<size_t>(y) * mapped.RowPitch, stride);
    }
    context->Unmap(staging.get(), 0);
  }

  LONGLONG expected = -1;
  session_start.compare_exchange_strong(expected, ts);

  {
    std::lock_guard<std::mutex> lock(queue_mutex);
    // Bound memory: if the encoder is lagging, drop the oldest queued frame
    // rather than grow without bound (a 4K frame is ~33 MB).
    if (queue.size() >= 8) queue.pop_front();
    QueuedFrame qf;
    qf.bgra = std::move(buffer);
    qf.ts100ns = ts;
    queue.push_back(std::move(qf));
  }
  queue_cv.notify_one();
}

void Recorder::Impl::EncoderLoop() {
  const uint32_t in_stride = cap_w * 4;
  const DWORD in_size = in_stride * cap_h;
  for (;;) {
    QueuedFrame qf;
    {
      std::unique_lock<std::mutex> lock(queue_mutex);
      queue_cv.wait(lock, [&] { return !queue.empty() || stop_requested; });
      if (queue.empty()) {
        if (stop_requested) break;
        continue;
      }
      qf = std::move(queue.front());
      queue.pop_front();
    }

    LONGLONG start = session_start.load();
    if (start < 0) start = qf.ts100ns;
    LONGLONG pts = qf.ts100ns - start - paused_accum;
    if (pts < 0) pts = 0;

    winrt::com_ptr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(in_size, buf.put()))) continue;
    BYTE* dst = nullptr;
    if (FAILED(buf->Lock(&dst, nullptr, nullptr))) continue;
    // RGB32 top-down: positive stride into a top-down buffer (the input media
    // type declares MF_MT_DEFAULT_STRIDE positive).
    MFCopyImage(dst, in_stride, qf.bgra.data(), in_stride, in_stride, cap_h);
    buf->Unlock();
    buf->SetCurrentLength(in_size);

    winrt::com_ptr<IMFSample> sample;
    if (FAILED(MFCreateSample(sample.put()))) continue;
    sample->AddBuffer(buf.get());
    sample->SetSampleTime(pts);
    sample->SetSampleDuration(frame_interval);

    HRESULT hr = writer->WriteSample(video_stream, sample.get());
    if (FAILED(hr)) {
      {
        std::lock_guard<std::mutex> lock(error_mutex);
        async_error = "WriteSample failed";
      }
      failed = true;
      if (async_target) {
        PostMessage(async_target, async_msg, Recorder::kAsyncFailed, 0);
      }
      break;
    }
  }
}

void Recorder::Impl::Cleanup() {
  // Stop the capture first so no more frames are enqueued.
  if (frame_token) {
    try {
      pool.FrameArrived(frame_token);
    } catch (...) {
    }
    frame_token = {};
  }
  if (session) {
    try {
      session.Close();
    } catch (...) {
    }
    session = nullptr;
  }
  if (pool) {
    try {
      pool.Close();
    } catch (...) {
    }
    pool = nullptr;
  }
  // Drain + join the encoder.
  stop_requested = true;
  queue_cv.notify_all();
  if (encoder.joinable()) encoder.join();

  staging = nullptr;
  context = nullptr;
  device = nullptr;
  item = nullptr;
  writer = nullptr;
  {
    std::lock_guard<std::mutex> lock(queue_mutex);
    queue.clear();
  }
  if (mf_started) {
    MFShutdown();
    mf_started = false;
  }
}

bool Recorder::Start(const Spec& spec, HWND async_target, UINT async_msg,
                     StartedInfo* out, std::string* error) {
  auto fail = [&](const char* msg) {
    if (error) *error = msg;
    impl_->Cleanup();
    return false;
  };
  if (active_) return fail("already recording");

  // Reset per-session state on the (possibly reused) impl.
  impl_->session_start = -1;
  impl_->paused_accum = 0;
  impl_->last_enqueued = -1;
  impl_->stop_requested = false;
  impl_->failed = false;
  impl_->async_target = async_target;
  impl_->async_msg = async_msg;
  {
    std::lock_guard<std::mutex> lock(impl_->error_mutex);
    impl_->async_error.clear();
  }

  // ---- resolve the capture source (S6a: display only) --------------------
  HMONITOR mon = nullptr;
  if (spec.display_id != 0) {
    mon = reinterpret_cast<HMONITOR>(static_cast<intptr_t>(spec.display_id));
    MONITORINFO check{};
    check.cbSize = sizeof(MONITORINFO);
    if (!GetMonitorInfo(mon, &check)) mon = nullptr;
  }
  if (!mon) {
    POINT pt{};
    GetCursorPos(&pt);
    mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  }
  if (!mon) return fail("no monitor");
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonScale(mon);

  // ---- D3D + capture item ------------------------------------------------
  try {
    impl_->device = CreateD3DDevice();
    if (!impl_->device) return fail("no d3d device");
    impl_->device->GetImmediateContext(impl_->context.put());
    auto rtDevice = WrapDevice(impl_->device);

    auto interop = GetInterop();
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    winrt::check_hresult(interop->CreateForMonitor(
        mon, reinterpret_cast<GUID const&>(iid), winrt::put_abi(impl_->item)));

    auto size = impl_->item.Size();
    impl_->cap_w = static_cast<uint32_t>(size.Width);
    impl_->cap_h = static_cast<uint32_t>(size.Height);
    if (impl_->cap_w == 0 || impl_->cap_h == 0) return fail("empty capture size");

    // Reused staging texture for the per-frame CPU readback.
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = impl_->cap_w;
    sd.Height = impl_->cap_h;
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(impl_->device->CreateTexture2D(&sd, nullptr,
                                              impl_->staging.put()))) {
      return fail("staging texture");
    }

    impl_->pool = cap::Direct3D11CaptureFramePool::CreateFreeThreaded(
        rtDevice, dx::DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    impl_->session = impl_->pool.CreateCaptureSession(impl_->item);
    try {
      impl_->session.IsBorderRequired(false);
    } catch (...) {
    }
    try {
      impl_->session.IsCursorCaptureEnabled(spec.show_cursor);
    } catch (...) {
    }
  } catch (...) {
    return fail("capture setup threw");
  }

  // ---- output dimensions (mp4 long-side cap, even-rounded) ---------------
  uint32_t out_w = impl_->cap_w, out_h = impl_->cap_h;
  if (spec.max_long_side > 0) {
    const uint32_t longest = (std::max)(out_w, out_h);
    if (longest > static_cast<uint32_t>(spec.max_long_side)) {
      const double r = static_cast<double>(spec.max_long_side) / longest;
      out_w = static_cast<uint32_t>(out_w * r);
      out_h = static_cast<uint32_t>(out_h * r);
    }
  }
  out_w = (std::max)(2u, EvenDown(out_w));
  out_h = (std::max)(2u, EvenDown(out_h));
  impl_->out_w = out_w;
  impl_->out_h = out_h;

  const int fps = (std::max)(1, spec.fps);
  impl_->frame_interval = 10000000LL / fps;

  // ---- Media Foundation sink writer --------------------------------------
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return fail("MFStartup");
  impl_->mf_started = true;

  impl_->output_path_w.assign(spec.output_path.begin(), spec.output_path.end());
  // (Output path is built by Dart and is ASCII/path-safe; widen byte-wise.)
  {
    int n = MultiByteToWideChar(CP_UTF8, 0, spec.output_path.c_str(), -1,
                                nullptr, 0);
    if (n > 0) {
      std::wstring w(static_cast<size_t>(n - 1), L'\0');
      MultiByteToWideChar(CP_UTF8, 0, spec.output_path.c_str(), -1, w.data(), n);
      impl_->output_path_w = std::move(w);
    }
  }

  winrt::com_ptr<IMFSinkWriter> writer;
  if (FAILED(MFCreateSinkWriterFromURL(impl_->output_path_w.c_str(), nullptr,
                                       nullptr, writer.put()))) {
    return fail("MFCreateSinkWriterFromURL");
  }

  const double bpp = BppFor(spec.video_quality);
  UINT32 bitrate = static_cast<UINT32>(
      (std::max)(500000.0, static_cast<double>(out_w) * out_h * fps * bpp));

  // Output (encoded) type.
  winrt::com_ptr<IMFMediaType> out_type;
  if (FAILED(MFCreateMediaType(out_type.put()))) return fail("out type");
  out_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  out_type->SetGUID(MF_MT_SUBTYPE,
                    spec.hevc ? MFVideoFormat_HEVC : MFVideoFormat_H264);
  out_type->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
  out_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  MFSetAttributeSize(out_type.get(), MF_MT_FRAME_SIZE, out_w, out_h);
  MFSetAttributeRatio(out_type.get(), MF_MT_FRAME_RATE, fps, 1);
  MFSetAttributeRatio(out_type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(writer->AddStream(out_type.get(), &impl_->video_stream))) {
    return fail("AddStream");
  }

  // Input (raw) type: RGB32 == BGRA8888 in memory, top-down (positive stride).
  winrt::com_ptr<IMFMediaType> in_type;
  if (FAILED(MFCreateMediaType(in_type.put()))) return fail("in type");
  in_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  in_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  in_type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  in_type->SetUINT32(MF_MT_DEFAULT_STRIDE, impl_->cap_w * 4);
  MFSetAttributeSize(in_type.get(), MF_MT_FRAME_SIZE, impl_->cap_w, impl_->cap_h);
  MFSetAttributeRatio(in_type.get(), MF_MT_FRAME_RATE, fps, 1);
  MFSetAttributeRatio(in_type.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (FAILED(writer->SetInputMediaType(impl_->video_stream, in_type.get(),
                                       nullptr))) {
    return fail("SetInputMediaType");
  }

  if (FAILED(writer->BeginWriting())) return fail("BeginWriting");
  impl_->writer = writer;

  // ---- arm the frame callback + start the encoder + the capture ---------
  Impl* impl = impl_.get();
  impl_->frame_token = impl_->pool.FrameArrived(
      [impl](auto&&, auto&&) { impl->OnFrameArrived(); });
  impl_->encoder = std::thread([impl] { impl->EncoderLoop(); });
  try {
    impl_->session.StartCapture();
  } catch (...) {
    return fail("StartCapture threw");
  }

  active_ = true;
  if (out) {
    out->display_id = static_cast<int64_t>(reinterpret_cast<intptr_t>(mon));
    out->x = 0.0;
    out->y = 0.0;
    out->w = impl_->cap_w / scale;
    out->h = impl_->cap_h / scale;
  }
  return true;
}

bool Recorder::Stop(std::string* out_path, std::string* error) {
  if (!active_) {
    if (error) *error = "not recording";
    return false;
  }
  active_ = false;

  // Stop the source + drain the encoder before finalizing.
  if (impl_->frame_token) {
    try {
      impl_->pool.FrameArrived(impl_->frame_token);
    } catch (...) {
    }
    impl_->frame_token = {};
  }
  if (impl_->session) {
    try {
      impl_->session.Close();
    } catch (...) {
    }
    impl_->session = nullptr;
  }
  impl_->stop_requested = true;
  impl_->queue_cv.notify_all();
  if (impl_->encoder.joinable()) impl_->encoder.join();

  bool ok = true;
  if (impl_->failed) {
    ok = false;
    if (error) *error = "encode failed";
  } else if (impl_->writer) {
    HRESULT hr = impl_->writer->Finalize();
    if (FAILED(hr)) {
      ok = false;
      if (error) *error = "Finalize failed";
    }
  }

  const std::wstring path_w = impl_->output_path_w;
  std::string path_utf8;
  if (!path_w.empty()) {
    int n = WideCharToMultiByte(CP_UTF8, 0, path_w.c_str(),
                                static_cast<int>(path_w.size()), nullptr, 0,
                                nullptr, nullptr);
    path_utf8.resize(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, path_w.c_str(),
                        static_cast<int>(path_w.size()), path_utf8.data(), n,
                        nullptr, nullptr);
  }

  impl_->Cleanup();
  if (ok && out_path) *out_path = path_utf8;
  return ok;
}

void Recorder::Abort() {
  if (!active_) {
    impl_->Cleanup();
    return;
  }
  active_ = false;
  const std::wstring path_w = impl_->output_path_w;
  impl_->Cleanup();
  if (!path_w.empty()) DeleteFileW(path_w.c_str());
}
