#include "recorder.h"

#include "record_audio.h"
#include "record_gif.h"

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

// QueryPerformanceCounter as 100ns ticks. ONE clock shared by the video capture
// (WGC) and the audio capture (WASAPI) so their timestamps are comparable: WGC
// SystemRelativeTime and WASAPI u64QPCPosition are on DIFFERENT epochs, and
// subtracting one from the other produced a giant-negative audio pts -> clamped
// to 0 -> the whole audio track crammed at pts~0 ("mic only plays ~1 second").
LONGLONG Qpc100ns() {
  static const LONGLONG freq = [] {
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    return f.QuadPart ? f.QuadPart : 10000000LL;
  }();
  LARGE_INTEGER c{};
  QueryPerformanceCounter(&c);
  // Split seconds + remainder so QuadPart * 1e7 cannot overflow int64 (QuadPart
  // is ~1e12 on a machine up for a day; *1e7 would exceed int64 max).
  return (c.QuadPart / freq) * 10000000LL +
         (c.QuadPart % freq) * 10000000LL / freq;
}

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

// Live PCM mixer (the mergeAudio path): sums the system + mic streams onto ONE
// AAC track. Mirrors the macOS AudioMixer (RecordingKit.swift): both sources
// arrive already 48 kHz / stereo / s16 (WASAPI AUTOCONVERTPCM handles the device
// mix format AND the mono-mic -> stereo upmix, so no converter is needed here,
// unlike macOS). Each source is laid down CONTIGUOUSLY by a per-source frame
// cursor (advanced by the real sample count), with the packet pts used only to
// seed the cursor and to re-sync across a genuine capture gap -- because the
// WASAPI poll timestamps are too coarse/jittery to place every packet by (see
// Add). Driven inline on the SOLE encoder thread -- single owner, no locks. A
// frame-indexed int32 accumulator (int32 so summing two s16 cannot overflow
// before the limiter) holds pending samples; each Add flushes up to the lower of
// the two sources' high-water marks (with a 0.3 s silence-gap fallback so a
// quiet/idle source cannot stall the flush -- WASAPI may deliver nothing during
// pure silence). A peak limiter (not a hard clamp) on the sum is written to the
// merged AAC sink stream.
class AudioMixer {
 public:
  enum class Source { kSystem, kMic };

  // |writer| + |stream| identify the single merged AAC sink stream. |writer| is
  // owned by the Recorder (released after the mixer is reset), held raw here.
  AudioMixer(IMFSinkWriter* writer, DWORD stream)
      : writer_(writer), stream_(stream) {}

  // Mix one source packet (interleaved s16: L,R,L,R...). |pts100ns| is its
  // rebased presentation time (>= 0). Returns the WriteSample HRESULT of the
  // flush it triggers (S_OK if nothing was flushed).
  HRESULT Add(Source src, const int16_t* samples, size_t frame_count,
              LONGLONG pts100ns) {
    if (frame_count == 0) return S_OK;
    // Rebased pts (100ns) -> 48 kHz frame index, rounded. Split seconds +
    // remainder so the multiply cannot overflow int64 (same idiom as Qpc100ns).
    const int64_t pts_frame =
        (pts100ns / 10000000LL) * kSampleRate +
        ((pts100ns % 10000000LL) * kSampleRate + 5000000LL) / 10000000LL;
    // CRITICAL: place each packet CONTIGUOUSLY after this source's previous one
    // (advance the cursor by the real sample count) -- do NOT re-derive the
    // position from every packet's pts. WASAPI audio is POLLED, so packets drained
    // back-to-back carry near-equal dequeue timestamps while representing
    // sequential audio spans, and the ~15 ms poll cadence does not match the
    // per-packet sample count; placing by pts therefore overlaps/gaps consecutive
    // packets, summing audio onto itself -- the merged-track distortion. The pts
    // is used only to seed the cursor on the first packet (aligning system vs mic)
    // and to re-sync across a genuine capture gap (e.g. a loopback silence dropout,
    // where the source delivers nothing for a while), so the two sources stay in
    // sync without per-packet jitter corrupting the stream.
    int64_t& cursor = (src == Source::kSystem) ? sys_cursor_ : mic_cursor_;
    const int64_t drift = pts_frame - cursor;
    if (cursor < 0 || drift > kResyncFrames || drift < -kResyncFrames) {
      cursor = pts_frame;  // first packet, or a real gap -> snap to the wall clock
    }
    MixIn(samples, frame_count, cursor);
    cursor += static_cast<int64_t>(frame_count);
    if (src == Source::kSystem) {
      sys_hwm_ = (std::max)(sys_hwm_, cursor);
    } else {
      mic_hwm_ = (std::max)(mic_hwm_, cursor);
    }
    return Flush(false);
  }

  // Flush any buffered audio still in the accumulator (the tail past the lower
  // high-water mark) before the writer finalizes. Mirrors macOS mixer.finish().
  HRESULT Finish() { return Flush(true); }

 private:
  void MixIn(const int16_t* in, size_t frames, int64_t start_frame) {
    if (base_frame_ < 0) base_frame_ = start_frame;
    const int64_t need_end = start_frame + static_cast<int64_t>(frames);
    const int64_t cur_end = base_frame_ + static_cast<int64_t>(acc_l_.size());
    if (need_end > cur_end) {
      const size_t add = static_cast<size_t>(need_end - cur_end);
      acc_l_.insert(acc_l_.end(), add, 0);
      acc_r_.insert(acc_r_.end(), add, 0);
    }
    const int64_t offset = start_frame - base_frame_;
    if (offset < 0) return;  // a few ms before base: drop (sub-buffer)
    for (size_t i = 0; i < frames; ++i) {
      acc_l_[static_cast<size_t>(offset) + i] += in[i * 2];
      acc_r_[static_cast<size_t>(offset) + i] += in[i * 2 + 1];
    }
  }

  HRESULT Flush(bool final_flush) {
    if (base_frame_ < 0 || acc_l_.empty()) return S_OK;
    int64_t watermark;
    if (final_flush) {
      watermark = base_frame_ + static_cast<int64_t>(acc_l_.size());
    } else {
      int64_t w = (std::min)(sys_hwm_, mic_hwm_);
      const int64_t hi = (std::max)(sys_hwm_, mic_hwm_);
      if (hi - w > kLagFrames) w = hi - kLagFrames;  // silence-gap safety
      watermark = w;
    }
    const int64_t count = watermark - base_frame_;
    if (count <= 0) return S_OK;

    const DWORD bytes =
        static_cast<DWORD>(count * kChannels * sizeof(int16_t));
    winrt::com_ptr<IMFMediaBuffer> buf;
    if (FAILED(MFCreateMemoryBuffer(bytes, buf.put()))) return S_OK;
    BYTE* dst = nullptr;
    if (FAILED(buf->Lock(&dst, nullptr, nullptr))) return S_OK;
    auto* out = reinterpret_cast<int16_t*>(dst);
    for (int64_t i = 0; i < count; ++i) {
      const int32_t l = acc_l_[static_cast<size_t>(i)];
      const int32_t r = acc_r_[static_cast<size_t>(i)];
      // Peak LIMITER (instant attack, slow release) on the system+mic SUM so a
      // loud combined signal is gain-reduced instead of hard-clipped (the
      // break-up distortion the owner heard). gain_ persists across flushes so
      // the reduction is click-free; the final ClampS16 is only a rounding-safety
      // net. Normal-level content stays at unity (gain_ == 1).
      const int32_t al = l < 0 ? -l : l;
      const int32_t ar = r < 0 ? -r : r;
      const int32_t peak = al > ar ? al : ar;
      double target = 1.0;
      if (peak > kLimit) target = static_cast<double>(kLimit) / peak;
      if (target < gain_) {
        gain_ = target;  // attack: drop instantly to avoid an overshoot
      } else {
        gain_ += (target - gain_) * kRelease;  // release: recover slowly
      }
      const double gl = l * gain_;
      const double gr = r * gain_;
      out[i * 2] = ClampS16(static_cast<int32_t>(gl >= 0 ? gl + 0.5 : gl - 0.5));
      out[i * 2 + 1] =
          ClampS16(static_cast<int32_t>(gr >= 0 ? gr + 0.5 : gr - 0.5));
    }
    buf->Unlock();
    buf->SetCurrentLength(bytes);

    LONGLONG pts = base_frame_ * 10000000LL / kSampleRate;
    if (pts <= last_pts_) pts = last_pts_ + 1;  // monotonic guard (defensive)
    last_pts_ = pts;
    const LONGLONG dur = count * 10000000LL / kSampleRate;

    winrt::com_ptr<IMFSample> sample;
    if (FAILED(MFCreateSample(sample.put()))) return S_OK;
    sample->AddBuffer(buf.get());
    sample->SetSampleTime(pts);
    sample->SetSampleDuration(dur);
    const HRESULT hr = writer_->WriteSample(stream_, sample.get());

    acc_l_.erase(acc_l_.begin(), acc_l_.begin() + static_cast<size_t>(count));
    acc_r_.erase(acc_r_.begin(), acc_r_.begin() + static_cast<size_t>(count));
    base_frame_ = watermark;
    return hr;
  }

  static int16_t ClampS16(int32_t v) {
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return static_cast<int16_t>(v);
  }

  static constexpr int64_t kSampleRate = 48000;
  static constexpr int kChannels = 2;
  static constexpr int64_t kLagFrames = 48000 * 3 / 10;  // 0.3 s
  static constexpr int32_t kLimit = 32200;     // limiter ceiling (~ -0.15 dBFS)
  static constexpr double kRelease = 0.0002;   // ~100 ms gain recovery at 48 kHz
  static constexpr int64_t kResyncFrames = 48000 / 5;  // 0.2 s gap -> re-sync

  IMFSinkWriter* writer_;
  DWORD stream_;
  std::vector<int32_t> acc_l_, acc_r_;  // frame-indexed; acc_l_[0] == base_frame_
  int64_t base_frame_ = -1;             // -1 until the first sample lands
  int64_t sys_cursor_ = -1, mic_cursor_ = -1;  // next write frame per source
  int64_t sys_hwm_ = 0, mic_hwm_ = 0;   // highest frame delivered by each source
  LONGLONG last_pts_ = -1;              // monotonic guard for emitted samples
  double gain_ = 1.0;                   // limiter gain state (1 = unity)
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

  // ---- encode (GIF via WIC, the alternative to the mp4 path) -------------
  bool gif = false;
  std::unique_ptr<GifSink> gif_sink;
  uint32_t gif_delay_cs = 0;  // per-frame delay (centiseconds) at the GIF fps
  std::atomic<uint32_t> gif_frames{0};  // appended GIF frames (strip readout)

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
  // drains video + audio in timestamp order. Two separate tracks when both
  // sources are on, UNLESS merge_audio -- then both route through `mixer` onto one
  // merged AAC track (Windows media players play only the first audio track, so a
  // two-track file would silence the mic; macOS players mix both).
  std::unique_ptr<WasapiCapture> sys_cap;
  std::unique_ptr<WasapiCapture> mic_cap;
  AudioStream audio_sys;
  AudioStream audio_mic;
  bool merge_audio = false;           // gated: merge && both sources opened
  std::unique_ptr<AudioMixer> mixer;  // the single merged AAC sink (merge path)

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
  // Stop + join the capture sources (audio threads + the WGC frame pool) so no
  // more samples enqueue. MUST run BEFORE joining the encoder, else a live source
  // (esp. the mic, which always produces) keeps refilling the queue and the
  // encoder's all-empty exit condition is never met -> a hang on stop/abort.
  void StopSources();
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
    // Timestamp on the SHARED QPC clock (NOT WGC SystemRelativeTime, which is a
    // different epoch than the audio clock) so video + audio interleave + sync.
    ts = Qpc100ns();

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

    if (pick == kVideo && gif) {
      // GIF path: append the (cropped) frame with a fixed per-frame delay.
      if (!gif_sink ||
          !gif_sink->AddFrame(vf.bgra.data(), cap_w, cap_h, cap_w * 4,
                              gif_delay_cs)) {
        {
          std::lock_guard<std::mutex> lock(error_mutex);
          async_error = "gif encode failed";
        }
        failed = true;
        if (async_target) {
          PostMessage(async_target, async_msg, Recorder::kAsyncFailed, 0);
        }
        break;
      }
      gif_frames.fetch_add(1, std::memory_order_relaxed);
      continue;  // GIF has no Media Foundation sample
    }

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
      // Audio + video now share ONE clock (QPC), rebased to the first video frame
      // (session_start, set in OnFrameArrived). Drop audio captured BEFORE the
      // first frame (pre-roll) rather than clamping it to 0 -- clamping crammed
      // the whole track at pts~0 (the "mic only plays ~1 second" bug).
      if (start < 0) continue;  // no video frame yet -> drop pre-roll audio
      LONGLONG pts = ap.qpc100ns - start - paused_accum.load();
      if (pts < 0) continue;    // captured before the first frame -> drop

      const LONGLONG frames =
          static_cast<LONGLONG>(ap.samples.size() / WasapiCapture::kChannels);

      if (merge_audio) {
        // Merge path: feed the mixer, which sums system + mic PTS-aligned onto
        // the ONE merged AAC stream and writes it itself.
        hr = mixer->Add(pick == kSys ? AudioMixer::Source::kSystem
                                      : AudioMixer::Source::kMic,
                        ap.samples.data(), static_cast<size_t>(frames), pts);
      } else {
        // Two-track (or single-source) path: write this source's own AAC stream.
        AudioStream& as = (pick == kSys) ? audio_sys : audio_mic;
        if (pts <= as.last_pts) pts = as.last_pts + 1;
        as.last_pts = pts;

        const DWORD bytes =
            static_cast<DWORD>(ap.samples.size() * sizeof(int16_t));
        const LONGLONG dur = frames * 10000000LL /
                             static_cast<LONGLONG>(WasapiCapture::kSampleRate);

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
  // Flush the merge mixer's buffered tail (audio past the lower high-water mark,
  // held back during the run) onto the merged AAC track before the writer
  // finalizes. Runs on this (encoder) thread so the mixer's WriteSample stays on
  // the sole writer. Skip on a failed encode -- the file is discarded anyway.
  // Mirrors macOS RecordingWriter.finish() -> mixer.finish().
  if (merge_audio && mixer && !failed.load()) mixer->Finish();
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

void Recorder::Impl::StopSources() {
  // Stop the audio sources first so no more packets are enqueued (each Stop()
  // joins its capture thread).
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
}

void Recorder::Impl::Cleanup() {
  StopSources();  // idempotent; ensures no source outlives the encoder join
  // Drain + join the worker threads.
  stop_requested = true;
  queue_cv.notify_all();
  if (encoder.joinable()) encoder.join();
  if (autostop.joinable()) autostop.join();

  staging = nullptr;
  context = nullptr;
  device = nullptr;
  item = nullptr;
  mixer.reset();  // holds writer raw -> release before the writer
  merge_audio = false;
  writer = nullptr;
  gif_sink.reset();
  gif = false;
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
  impl_->gif_frames = 0;
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
  impl_->merge_audio = false;
  impl_->mixer.reset();
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
  const int gfps = (std::max)(1, spec.gif_fps);
  impl_->gif = spec.gif;
  // GIF throttles to its own (coarser) rate; mp4 keeps the requested fps.
  impl_->frame_interval = spec.gif ? (10000000LL / gfps) : (10000000LL / fps);
  impl_->gif_delay_cs =
      spec.gif ? static_cast<uint32_t>((100 + gfps / 2) / gfps) : 0;

  // Widen the (Dart-built, ASCII/path-safe) output path once, for either encoder.
  {
    int n = MultiByteToWideChar(CP_UTF8, 0, spec.output_path.c_str(), -1,
                                nullptr, 0);
    impl_->output_path_w.clear();
    if (n > 0) {
      std::wstring w(static_cast<size_t>(n - 1), L'\0');
      MultiByteToWideChar(CP_UTF8, 0, spec.output_path.c_str(), -1, w.data(), n);
      impl_->output_path_w = std::move(w);
    }
  }

  // ---- WASAPI audio sources (mp4 only; GIF has no audio) -----------------
  // Started BEFORE the writer's audio streams so only sources that actually open
  // get an mp4 audio track (no empty-track finalize). Packets accumulate in the
  // bounded queues until the encoder thread starts draining them; while paused
  // they are dropped (the span is excluded). Two separate tracks when both are
  // on, unless mergeAudio sums them onto one (resolved at stream setup below).
  Impl* impl = impl_.get();
  if (!spec.gif && spec.system_audio) {
    impl_->sys_cap = std::make_unique<WasapiCapture>();
    impl_->audio_sys.active = impl_->sys_cap->Start(
        WasapiCapture::Kind::kLoopback, [impl](const AudioPacket& p) {
          if (impl->paused.load() || impl->stop_requested.load()) return;
          {
            std::lock_guard<std::mutex> lock(impl->queue_mutex);
            // Bound memory: drop if the encoder falls far behind (silent).
            if (impl->audio_sys.queue.size() < 128) {
              impl->audio_sys.queue.push_back(p);
            }
          }
          impl->queue_cv.notify_one();
        });
    if (!impl_->audio_sys.active) impl_->sys_cap.reset();
  }
  if (!spec.gif && spec.microphone) {
    impl_->mic_cap = std::make_unique<WasapiCapture>();
    impl_->audio_mic.active = impl_->mic_cap->Start(
        WasapiCapture::Kind::kMicrophone, [impl](const AudioPacket& p) {
          if (impl->paused.load() || impl->stop_requested.load()) return;
          {
            std::lock_guard<std::mutex> lock(impl->queue_mutex);
            // Bound memory: drop if the encoder falls far behind (silent).
            if (impl->audio_mic.queue.size() < 128) {
              impl->audio_mic.queue.push_back(p);
            }
          }
          impl->queue_cv.notify_one();
        });
    if (!impl_->audio_mic.active) impl_->mic_cap.reset();
  }

  // ---- GIF (WIC) encoder, or the Media Foundation sink writer (mp4) ------
  if (spec.gif) {
    impl_->gif_sink = std::make_unique<GifSink>();
    if (!impl_->gif_sink->Open(impl_->output_path_w, 1024)) {
      return fail("gif open");
    }
  }
  // The entire Media Foundation path below is mp4 (H.264 / HEVC) only. `writer`
  // stays null for GIF; every statement up to BeginWriting is guarded by !gif.
  winrt::com_ptr<IMFSinkWriter> writer;
  if (!spec.gif) {
    if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) return fail("MFStartup");
    impl_->mf_started = true;
    winrt::com_ptr<IMFAttributes> sw_attrs;
    if (SUCCEEDED(MFCreateAttributes(sw_attrs.put(), 2))) {
      // Disable inter-stream WriteSample throttling. At stop we stop the video
      // and drain the BUFFERED audio, whose timestamps then run AHEAD of the
      // (now stopped) video. With throttling on (the default) the sink writer
      // blocks each such WriteSample ~1 second waiting for the video to catch up
      // -- the finish/abort HANG (worst with system+mic, the largest audio
      // backlog) -- and the file never finalizes (corrupt). Proven by the
      // stop-path trace: each drained SYS-audio WriteSample took ~1000 ms.
      sw_attrs->SetUINT32(MF_SINK_WRITER_DISABLE_THROTTLING, TRUE);
      // HEVC has no SOFTWARE encoder MFT on Windows (unlike H.264); allow the
      // GPU hardware encoder MFT or AddStream(HEVC) fails (recording never
      // starts). H.264 keeps its software encoder.
      if (spec.hevc) {
        sw_attrs->SetUINT32(MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
      }
    }
    if (FAILED(MFCreateSinkWriterFromURL(impl_->output_path_w.c_str(), nullptr,
                                         sw_attrs.get(), writer.put()))) {
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
  HRESULT add_hr = writer->AddStream(out_type.get(), &impl_->video_stream);
  if (FAILED(add_hr) && spec.hevc) {
    // No HEVC encoder on this machine (no GPU HEVC MFT / HEVC Video Extension
    // not installed): fall back to H.264 so recording still works (both are mp4)
    // instead of silently doing nothing.
    out_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
    add_hr = writer->AddStream(out_type.get(), &impl_->video_stream);
  }
  if (FAILED(add_hr)) {
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
  // Windows ALWAYS mixes to ONE AAC track when both sources are on -- a two-track
  // mp4 is unplayable in common Windows players (Windows Media Player plays no
  // track at all; PotPlayer mixes both at once, so the level is wrong), so the
  // mergeAudio toggle is overridden here. A single source still writes its own
  // single track below. (Owner ruling 2026-06-30; intentional Windows-only
  // deviation from the macOS two-track-when-unmerged behaviour -- spec.merge_audio
  // is therefore not consulted on Windows.) If adding the merged stream fails,
  // fall back to two tracks rather than dropping audio entirely.
  if (impl_->audio_sys.active && impl_->audio_mic.active) {
    DWORD merged_index = 0;
    if (add_audio(&merged_index)) {
      impl_->merge_audio = true;
      impl_->mixer = std::make_unique<AudioMixer>(writer.get(), merged_index);
    }
  }
  if (!impl_->merge_audio) {
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
  }

    if (FAILED(writer->BeginWriting())) return fail("BeginWriting");
    impl_->writer = writer;
  }  // end of the mp4-only Media Foundation setup

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

  // Stop ALL sources (audio threads + WGC pool) BEFORE draining the encoder --
  // otherwise a still-running source (the mic always produces) keeps refilling
  // the queue and the encoder's all-empty exit is never reached -> a hang.
  impl_->StopSources();
  impl_->stop_requested = true;
  impl_->queue_cv.notify_all();
  if (impl_->encoder.joinable()) impl_->encoder.join();

  bool ok = true;
  if (impl_->failed) {
    ok = false;
    if (error) *error = "encode failed";
  } else if (impl_->gif) {
    if (!impl_->gif_sink || !impl_->gif_sink->Finish()) {
      ok = false;
      if (error) *error = "gif finalize failed";
    }
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

int Recorder::GifFrameCount() const {
  return impl_->gif ? static_cast<int>(impl_->gif_frames.load()) : 0;
}
