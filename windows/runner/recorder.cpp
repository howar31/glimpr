#include "recorder.h"

#include "record_audio.h"

#include <d3d11.h>
#include <dwmapi.h>
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
#include <cmath>
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

// One Media Foundation audio stream fed from a WASAPI source: its sink-writer
// stream index, the queue of pending PCM packets (guarded by the recorder's
// shared queue mutex), and the encoder-thread monotonic-pts guard.
struct AudioStream {
  DWORD mf_index = 0;
  bool active = false;
  std::deque<AudioPacket> queue;
  LONGLONG last_pts = -1;
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
  uint32_t cap_w = 0, cap_h = 0;          // encode-input (cropped) pixels
  uint32_t crop_x = 0, crop_y = 0;        // crop offset into the source frame (px)
  uint32_t staging_w = 0, staging_h = 0;  // current staging size (= source frame)

  // ---- encode (Media Foundation IMFSinkWriter) ---------------------------
  bool mf_started = false;
  winrt::com_ptr<IMFSinkWriter> writer;
  DWORD video_stream = 0;
  uint32_t out_w = 0, out_h = 0;  // encoded (possibly capped) pixels
  LONGLONG frame_interval = 0;    // 100ns per target frame (fps throttle/dur)

  // ---- timeline / pause --------------------------------------------------
  std::atomic<LONGLONG> session_start{-1};  // first frame ts (100ns)
  std::atomic<LONGLONG> paused_accum{0};    // excluded span (100ns), grown at resume
  LONGLONG last_enqueued = -1;              // throttle gate (capture thread)
  LONGLONG last_written_pts = -1;           // monotonic guard (encoder thread)
  std::atomic<bool> paused{false};
  // Wall-clock pause/auto-stop bookkeeping (robust to a static screen that stops
  // delivering frames): paused spans are measured in wall time and applied to the
  // frame-ts timeline (WGC SystemRelativeTime is QPC-based, ~= wall time).
  ULONGLONG start_wall_ms = 0;
  ULONGLONG pause_wall_start = 0;
  int max_duration_sec = 0;
  std::thread autostop;

  // ---- worker / queue ----------------------------------------------------
  std::thread encoder;
  std::mutex queue_mutex;
  std::condition_variable queue_cv;
  std::deque<QueuedFrame> queue;
  std::atomic<bool> stop_requested{false};
  std::mutex readback_mutex;  // serialize the immediate-context Map across pool threads

  // ---- audio (WASAPI -> AAC stream(s)) -----------------------------------
  // The encoder thread is the SOLE sink-writer writer: WASAPI capture threads
  // only push packets into these queues (guarded by queue_mutex), and the encoder
  // drains video + audio in timestamp order. Two-track when both sources are on
  // (mergeAudio is handled in a later sub-slice).
  std::unique_ptr<WasapiCapture> sys_cap;
  std::unique_ptr<WasapiCapture> mic_cap;
  AudioStream audio_sys;
  AudioStream audio_mic;

  // ---- async error -------------------------------------------------------
  HWND async_target = nullptr;
  UINT async_msg = 0;
  std::mutex error_mutex;
  std::string async_error;
  std::atomic<bool> failed{false};

  std::wstring output_path_w;

  void EncoderLoop();
  void AutoStopLoop();
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

    // While paused, still drain the frame (releasing it back to the pool) but do
    // not read it back or enqueue it -- the paused span is excluded from output.
    if (paused.load()) return;

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

    // (Re)create the staging texture to match the live frame size -- it can
    // change if a recorded window is resized mid-recording.
    if (!staging || staging_w != desc.Width || staging_h != desc.Height) {
      staging = nullptr;
      D3D11_TEXTURE2D_DESC sd{};
      sd.Width = desc.Width;
      sd.Height = desc.Height;
      sd.MipLevels = 1;
      sd.ArraySize = 1;
      sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      sd.SampleDesc.Count = 1;
      sd.Usage = D3D11_USAGE_STAGING;
      sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      if (FAILED(device->CreateTexture2D(&sd, nullptr, staging.put()))) return;
      staging_w = desc.Width;
      staging_h = desc.Height;
    }

    context->CopyResource(staging.get(), texture.get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
      return;
    }
    // Copy the crop window [crop_x, crop_y, cap_w x cap_h] from the source into a
    // tightly-packed, encode-sized buffer (zero-filled; anything outside the
    // source -- e.g. a shrunk window -- stays black).
    const uint32_t stride = cap_w * 4;
    buffer.assign(static_cast<size_t>(stride) * cap_h, 0);
    const auto* src = static_cast<const uint8_t*>(mapped.pData);
    uint32_t copy_w = cap_w;
    if (crop_x >= desc.Width) {
      copy_w = 0;
    } else if (crop_x + copy_w > desc.Width) {
      copy_w = desc.Width - crop_x;
    }
    if (copy_w > 0) {
      for (uint32_t y = 0; y < cap_h; ++y) {
        const uint32_t sy = crop_y + y;
        if (sy >= desc.Height) break;  // below the source -> leave black
        std::memcpy(buffer.data() + static_cast<size_t>(y) * stride,
                    src + static_cast<size_t>(sy) * mapped.RowPitch +
                        static_cast<size_t>(crop_x) * 4,
                    static_cast<size_t>(copy_w) * 4);
      }
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
  constexpr LONGLONG kMaxTs = 0x7fffffffffffffffLL;
  for (;;) {
    enum Pick { kNone, kVideo, kSys, kMic } pick = kNone;
    QueuedFrame vf;
    AudioPacket ap;
    {
      std::unique_lock<std::mutex> lock(queue_mutex);
      queue_cv.wait(lock, [&] {
        return !queue.empty() || !audio_sys.queue.empty() ||
               !audio_mic.queue.empty() || stop_requested;
      });
      const LONGLONG vt = queue.empty() ? kMaxTs : queue.front().ts100ns;
      const LONGLONG st =
          audio_sys.queue.empty() ? kMaxTs : audio_sys.queue.front().qpc100ns;
      const LONGLONG mt =
          audio_mic.queue.empty() ? kMaxTs : audio_mic.queue.front().qpc100ns;
      if (vt == kMaxTs && st == kMaxTs && mt == kMaxTs) {
        if (stop_requested) break;
        continue;
      }
      // Write the earliest-timestamped pending sample first so no single sink
      // stream runs far ahead of the others (global time order).
      if (vt <= st && vt <= mt) {
        pick = kVideo;
        vf = std::move(queue.front());
        queue.pop_front();
      } else if (st <= mt) {
        pick = kSys;
        ap = std::move(audio_sys.queue.front());
        audio_sys.queue.pop_front();
      } else {
        pick = kMic;
        ap = std::move(audio_mic.queue.front());
        audio_mic.queue.pop_front();
      }
    }

    LONGLONG start = session_start.load();
    HRESULT hr = S_OK;

    if (pick == kVideo) {
      if (start < 0) start = vf.ts100ns;
      LONGLONG pts = vf.ts100ns - start - paused_accum.load();
      if (pts < 0) pts = 0;
      // Monotonic guard: a resume's wall-clock gap estimate can momentarily land
      // a frame at/before the last written pts; nudge it forward.
      if (pts <= last_written_pts) pts = last_written_pts + 1;
      last_written_pts = pts;

      winrt::com_ptr<IMFMediaBuffer> buf;
      if (FAILED(MFCreateMemoryBuffer(in_size, buf.put()))) continue;
      BYTE* dst = nullptr;
      if (FAILED(buf->Lock(&dst, nullptr, nullptr))) continue;
      // RGB32 top-down: positive stride into a top-down buffer (the input media
      // type declares MF_MT_DEFAULT_STRIDE positive).
      MFCopyImage(dst, in_stride, vf.bgra.data(), in_stride, in_stride, cap_h);
      buf->Unlock();
      buf->SetCurrentLength(in_size);

      winrt::com_ptr<IMFSample> sample;
      if (FAILED(MFCreateSample(sample.put()))) continue;
      sample->AddBuffer(buf.get());
      sample->SetSampleTime(pts);
      sample->SetSampleDuration(frame_interval);
      hr = writer->WriteSample(video_stream, sample.get());
    } else {
      AudioStream& as = (pick == kSys) ? audio_sys : audio_mic;
      if (start < 0) start = ap.qpc100ns;
      LONGLONG pts = ap.qpc100ns - start - paused_accum.load();
      if (pts < 0) pts = 0;
      if (pts <= as.last_pts) pts = as.last_pts + 1;
      as.last_pts = pts;

      const DWORD bytes =
          static_cast<DWORD>(ap.samples.size() * sizeof(int16_t));
      const LONGLONG frames =
          static_cast<LONGLONG>(ap.samples.size() / WasapiCapture::kChannels);
      const LONGLONG dur =
          frames * 10000000LL / static_cast<LONGLONG>(WasapiCapture::kSampleRate);

      winrt::com_ptr<IMFMediaBuffer> buf;
      if (FAILED(MFCreateMemoryBuffer(bytes, buf.put()))) continue;
      BYTE* dst = nullptr;
      if (FAILED(buf->Lock(&dst, nullptr, nullptr))) continue;
      std::memcpy(dst, ap.samples.data(), bytes);
      buf->Unlock();
      buf->SetCurrentLength(bytes);

      winrt::com_ptr<IMFSample> sample;
      if (FAILED(MFCreateSample(sample.put()))) continue;
      sample->AddBuffer(buf.get());
      sample->SetSampleTime(pts);
      sample->SetSampleDuration(dur);
      hr = writer->WriteSample(as.mf_index, sample.get());
    }

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

void Recorder::Impl::AutoStopLoop() {
  // Wall-clock elapsed (excluding paused spans) -> auto-stop. Wall time rather
  // than frame timestamps so a static screen that stops delivering frames still
  // stops on time. One-shot: posts kAsyncAutoStop and exits; the platform-thread
  // stop path tears the session down.
  while (!stop_requested.load()) {
    Sleep(250);
    if (stop_requested.load()) return;
    if (max_duration_sec <= 0) return;
    if (paused.load()) continue;
    const ULONGLONG now = GetTickCount64();
    long long elapsed_ms = static_cast<long long>(now - start_wall_ms) -
                           (paused_accum.load() / 10000);
    if (elapsed_ms >= static_cast<long long>(max_duration_sec) * 1000) {
      if (async_target) {
        PostMessage(async_target, async_msg, Recorder::kAsyncAutoStop, 0);
      }
      return;
    }
  }
}

void Recorder::Impl::Cleanup() {
  // Stop the audio sources first so no more packets are enqueued.
  if (sys_cap) {
    sys_cap->Stop();
    sys_cap.reset();
  }
  if (mic_cap) {
    mic_cap->Stop();
    mic_cap.reset();
  }
  audio_sys.active = false;
  audio_mic.active = false;
  // Stop the video capture so no more frames are enqueued.
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
  // Drain + join the worker threads.
  stop_requested = true;
  queue_cv.notify_all();
  if (encoder.joinable()) encoder.join();
  if (autostop.joinable()) autostop.join();

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
  impl_->last_written_pts = -1;
  impl_->paused = false;
  impl_->pause_wall_start = 0;
  impl_->max_duration_sec = (std::max)(0, spec.max_duration_sec);
  impl_->stop_requested = false;
  impl_->failed = false;
  impl_->async_target = async_target;
  impl_->async_msg = async_msg;
  {
    std::lock_guard<std::mutex> lock(impl_->error_mutex);
    impl_->async_error.clear();
  }
  impl_->audio_sys.active = false;
  impl_->audio_sys.last_pts = -1;
  impl_->audio_mic.active = false;
  impl_->audio_mic.last_pts = -1;
  {
    std::lock_guard<std::mutex> lock(impl_->queue_mutex);
    impl_->audio_sys.queue.clear();
    impl_->audio_mic.queue.clear();
  }

  // ---- resolve the capture source (display / region / window) ------------
  HMONITOR mon = nullptr;
  HWND hwnd = nullptr;
  const bool window_mode = spec.mode == Mode::kWindow && spec.window_id != 0;
  if (window_mode) {
    hwnd = reinterpret_cast<HWND>(static_cast<intptr_t>(spec.window_id));
    if (!IsWindow(hwnd)) return fail("no window");
    mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  } else {
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
  }
  if (!mon) return fail("no monitor");
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  GetMonitorInfo(mon, &mi);
  const double scale = MonScale(mon);

  // A region crop applies only when a rect was given (region / lastRegion).
  const bool region = !window_mode && spec.w > 0 && spec.h > 0;

  // ---- D3D + capture item ------------------------------------------------
  uint32_t src_w = 0, src_h = 0;
  try {
    impl_->device = CreateD3DDevice();
    if (!impl_->device) return fail("no d3d device");
    impl_->device->GetImmediateContext(impl_->context.put());
    auto rtDevice = WrapDevice(impl_->device);

    auto interop = GetInterop();
    const winrt::guid iid = winrt::guid_of<cap::GraphicsCaptureItem>();
    if (window_mode) {
      winrt::check_hresult(interop->CreateForWindow(
          hwnd, reinterpret_cast<GUID const&>(iid),
          winrt::put_abi(impl_->item)));
    } else {
      winrt::check_hresult(interop->CreateForMonitor(
          mon, reinterpret_cast<GUID const&>(iid),
          winrt::put_abi(impl_->item)));
    }

    auto size = impl_->item.Size();
    src_w = static_cast<uint32_t>(size.Width);
    src_h = static_cast<uint32_t>(size.Height);
    if (src_w == 0 || src_h == 0) return fail("empty capture size");

    // Encode-input window: the full source (display/window), or the requested
    // region (display-local logical points -> source pixels).
    impl_->crop_x = 0;
    impl_->crop_y = 0;
    impl_->cap_w = src_w;
    impl_->cap_h = src_h;
    if (region) {
      long cx = std::lround(spec.x * scale);
      long cy = std::lround(spec.y * scale);
      long cw = std::lround(spec.w * scale);
      long ch = std::lround(spec.h * scale);
      if (cx < 0) cx = 0;
      if (cy < 0) cy = 0;
      if (cw > static_cast<long>(src_w) - cx) cw = static_cast<long>(src_w) - cx;
      if (ch > static_cast<long>(src_h) - cy) ch = static_cast<long>(src_h) - cy;
      if (cw >= 2 && ch >= 2) {
        impl_->crop_x = static_cast<uint32_t>(cx);
        impl_->crop_y = static_cast<uint32_t>(cy);
        impl_->cap_w = static_cast<uint32_t>(cw);
        impl_->cap_h = static_cast<uint32_t>(ch);
      }
    }

    // The staging texture is (re)created lazily in OnFrameArrived to match the
    // live frame size (so a window resized mid-recording is handled).
    impl_->staging = nullptr;
    impl_->staging_w = 0;
    impl_->staging_h = 0;

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

  // ---- WASAPI audio sources ----------------------------------------------
  // Started BEFORE the writer's audio streams so only sources that actually open
  // get an mp4 audio track (no empty-track finalize). Packets accumulate in the
  // bounded queues until the encoder thread starts draining them; while paused
  // they are dropped (the span is excluded). Two separate tracks when both are
  // on (mergeAudio is handled in a later sub-slice).
  Impl* impl = impl_.get();
  if (spec.system_audio) {
    impl_->sys_cap = std::make_unique<WasapiCapture>();
    impl_->audio_sys.active = impl_->sys_cap->Start(
        WasapiCapture::Kind::kLoopback, [impl](const AudioPacket& p) {
          if (impl->paused.load()) return;
          {
            std::lock_guard<std::mutex> lock(impl->queue_mutex);
            if (impl->audio_sys.queue.size() < 128)
              impl->audio_sys.queue.push_back(p);
          }
          impl->queue_cv.notify_one();
        });
    if (!impl_->audio_sys.active) impl_->sys_cap.reset();
  }
  if (spec.microphone) {
    impl_->mic_cap = std::make_unique<WasapiCapture>();
    impl_->audio_mic.active = impl_->mic_cap->Start(
        WasapiCapture::Kind::kMicrophone, [impl](const AudioPacket& p) {
          if (impl->paused.load()) return;
          {
            std::lock_guard<std::mutex> lock(impl->queue_mutex);
            if (impl->audio_mic.queue.size() < 128)
              impl->audio_mic.queue.push_back(p);
          }
          impl->queue_cv.notify_one();
        });
    if (!impl_->audio_mic.active) impl_->mic_cap.reset();
  }

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

  // Add an AAC audio stream (output) fed by 48k/stereo/s16 PCM (input) for each
  // active WASAPI source. The sink writer inserts the AAC encoder MFT.
  auto add_audio = [&](DWORD* out_index) -> bool {
    winrt::com_ptr<IMFMediaType> aout;
    if (FAILED(MFCreateMediaType(aout.put()))) return false;
    aout->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    aout->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    aout->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    aout->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, WasapiCapture::kSampleRate);
    aout->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, WasapiCapture::kChannels);
    aout->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 16000);  // ~128 kbps
    aout->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
    DWORD idx = 0;
    if (FAILED(writer->AddStream(aout.get(), &idx))) return false;

    winrt::com_ptr<IMFMediaType> ain;
    if (FAILED(MFCreateMediaType(ain.put()))) return false;
    ain->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    ain->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    ain->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    ain->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, WasapiCapture::kSampleRate);
    ain->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, WasapiCapture::kChannels);
    ain->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, WasapiCapture::kChannels * 2);
    ain->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                   WasapiCapture::kSampleRate * WasapiCapture::kChannels * 2);
    if (FAILED(writer->SetInputMediaType(idx, ain.get(), nullptr))) return false;
    *out_index = idx;
    return true;
  };
  if (impl_->audio_sys.active && !add_audio(&impl_->audio_sys.mf_index)) {
    impl_->audio_sys.active = false;
    if (impl_->sys_cap) {
      impl_->sys_cap->Stop();
      impl_->sys_cap.reset();
    }
  }
  if (impl_->audio_mic.active && !add_audio(&impl_->audio_mic.mf_index)) {
    impl_->audio_mic.active = false;
    if (impl_->mic_cap) {
      impl_->mic_cap->Stop();
      impl_->mic_cap.reset();
    }
  }

  if (FAILED(writer->BeginWriting())) return fail("BeginWriting");
  impl_->writer = writer;

  // ---- arm the frame callback + start the encoder + the capture ---------
  impl_->frame_token = impl_->pool.FrameArrived(
      [impl](auto&&, auto&&) { impl->OnFrameArrived(); });
  impl_->encoder = std::thread([impl] { impl->EncoderLoop(); });
  impl_->start_wall_ms = GetTickCount64();
  if (impl_->max_duration_sec > 0) {
    impl_->autostop = std::thread([impl] { impl->AutoStopLoop(); });
  }
  try {
    impl_->session.StartCapture();
  } catch (...) {
    return fail("StartCapture threw");
  }

  active_ = true;
  if (out) {
    out->display_id = static_cast<int64_t>(reinterpret_cast<intptr_t>(mon));
    if (window_mode) {
      // The window's visible bounds at start, display-local logical points.
      RECT rc{};
      if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rc,
                                       sizeof(rc)))) {
        GetWindowRect(hwnd, &rc);
      }
      out->x = (rc.left - mi.rcMonitor.left) / scale;
      out->y = (rc.top - mi.rcMonitor.top) / scale;
      out->w = (rc.right - rc.left) / scale;
      out->h = (rc.bottom - rc.top) / scale;
    } else if (region) {
      out->x = spec.x;
      out->y = spec.y;
      out->w = spec.w;
      out->h = spec.h;
    } else {
      out->x = 0.0;
      out->y = 0.0;
      out->w = src_w / scale;
      out->h = src_h / scale;
    }
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

void Recorder::Pause() {
  if (!active_ || impl_->paused.load()) return;
  impl_->pause_wall_start = GetTickCount64();
  impl_->paused = true;  // capture + encoder stop writing from here
}

void Recorder::Resume() {
  if (!active_ || !impl_->paused.load()) return;
  // Grow the excluded span by the paused wall duration (ms -> 100ns) BEFORE
  // clearing the flag, so the next encoded frame already sees the new offset.
  const ULONGLONG gap_ms = GetTickCount64() - impl_->pause_wall_start;
  impl_->paused_accum.fetch_add(static_cast<LONGLONG>(gap_ms) * 10000);
  impl_->paused = false;
}

bool Recorder::paused() const { return impl_->paused.load(); }
