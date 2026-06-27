#include "record_audio.h"

#include <audioclient.h>
#include <mmdeviceapi.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <thread>

namespace {

// COM smart-release helper kept local (the runner does not pull in a COM wrapper
// for these). Releases on scope exit.
template <typename T>
struct ComPtr {
  T* p = nullptr;
  ~ComPtr() {
    if (p) p->Release();
  }
  T** put() { return &p; }
  T* operator->() const { return p; }
  explicit operator bool() const { return p != nullptr; }
};

}  // namespace

struct WasapiCapture::Impl {
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  std::thread thread;
  std::atomic<bool> running{false};
  Sink sink;
  Kind kind = Kind::kLoopback;

  void Loop();
};

WasapiCapture::WasapiCapture() : impl_(std::make_unique<Impl>()) {}
WasapiCapture::~WasapiCapture() { Stop(); }

bool WasapiCapture::Start(Kind kind, Sink sink) {
  impl_->kind = kind;
  impl_->sink = std::move(sink);

  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                              reinterpret_cast<void**>(enumerator.put())))) {
    return false;
  }
  ComPtr<IMMDevice> device;
  // Loopback captures the render endpoint; mic captures the capture endpoint.
  const EDataFlow flow = (kind == Kind::kLoopback) ? eRender : eCapture;
  if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, eConsole,
                                                 device.put())) ||
      !device) {
    return false;
  }
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              reinterpret_cast<void**>(impl_->client.put()))) ||
      !impl_->client) {
    return false;
  }

  // Canonical capture format: 48 kHz / stereo / 16-bit PCM. AUTOCONVERTPCM makes
  // WASAPI convert from the device mix format for us (no hand-written resampler).
  WAVEFORMATEX wfx{};
  wfx.wFormatTag = WAVE_FORMAT_PCM;
  wfx.nChannels = kChannels;
  wfx.nSamplesPerSec = kSampleRate;
  wfx.wBitsPerSample = 16;
  wfx.nBlockAlign = wfx.nChannels * wfx.wBitsPerSample / 8;
  wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
  wfx.cbSize = 0;

  DWORD flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  if (kind == Kind::kLoopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
  // 200ms shared buffer; polled (no event callback -- loopback does not support
  // event-driven mode reliably).
  const REFERENCE_TIME buffer_100ns = 2000000;
  if (FAILED(impl_->client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags,
                                       buffer_100ns, 0, &wfx, nullptr))) {
    return false;
  }
  if (FAILED(impl_->client->GetService(
          __uuidof(IAudioCaptureClient),
          reinterpret_cast<void**>(impl_->capture.put()))) ||
      !impl_->capture) {
    return false;
  }
  if (FAILED(impl_->client->Start())) return false;

  impl_->running = true;
  Impl* impl = impl_.get();
  impl_->thread = std::thread([impl] { impl->Loop(); });
  return true;
}

void WasapiCapture::Impl::Loop() {
  while (running.load()) {
    Sleep(10);
    UINT32 packet = 0;
    if (FAILED(capture->GetNextPacketSize(&packet))) continue;
    while (packet > 0 && running.load()) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD buf_flags = 0;
      UINT64 dev_pos = 0;
      UINT64 qpc_pos = 0;  // 100ns units (QPC), same epoch as WGC frame times
      HRESULT hr = capture->GetBuffer(&data, &frames, &buf_flags, &dev_pos,
                                      &qpc_pos);
      if (FAILED(hr)) break;
      if (frames > 0) {
        AudioPacket pkt;
        pkt.qpc100ns = static_cast<int64_t>(qpc_pos);
        const size_t count = static_cast<size_t>(frames) * kChannels;
        pkt.samples.resize(count);
        if (buf_flags & AUDCLNT_BUFFERFLAGS_SILENT) {
          // Silent span: emit zeros (keeps the AAC track continuous).
          std::fill(pkt.samples.begin(), pkt.samples.end(),
                    static_cast<int16_t>(0));
        } else {
          std::memcpy(pkt.samples.data(), data, count * sizeof(int16_t));
        }
        if (sink) sink(pkt);
      }
      capture->ReleaseBuffer(frames);
      if (FAILED(capture->GetNextPacketSize(&packet))) break;
    }
  }
}

void WasapiCapture::Stop() {
  impl_->running = false;
  if (impl_->thread.joinable()) impl_->thread.join();
  if (impl_->client) impl_->client->Stop();
  // ComPtr members release on Impl destruction.
}
