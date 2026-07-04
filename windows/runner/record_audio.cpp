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

// QueryPerformanceCounter as 100ns ticks -- the SAME clock + formula the video
// capture uses (recorder.cpp Qpc100ns), so audio and video timestamps are
// comparable. Read at packet receipt rather than trusting the driver's
// u64QPCPosition (some drivers leave it 0 / on a different epoch).
int64_t Qpc100ns() {
  static const int64_t freq = [] {
    LARGE_INTEGER f{};
    QueryPerformanceFrequency(&f);
    return f.QuadPart ? f.QuadPart : 10000000LL;
  }();
  LARGE_INTEGER c{};
  QueryPerformanceCounter(&c);
  // Split seconds + remainder so QuadPart * 1e7 cannot overflow int64.
  return (c.QuadPart / freq) * 10000000LL +
         (c.QuadPart % freq) * 10000000LL / freq;
}

}  // namespace

struct WasapiCapture::Impl {
  std::thread thread;
  std::atomic<bool> running{false};
  std::atomic<bool> started_ok{false};
  HANDLE start_event = nullptr;  // worker signals init done (success or failure)
  Sink sink;
  Kind kind = Kind::kLoopback;

  // The WHOLE WASAPI COM lifecycle (create + capture loop + release) runs here,
  // on the worker thread in its own MTA apartment.
  void Run();
};

WasapiCapture::WasapiCapture() : impl_(std::make_unique<Impl>()) {}
WasapiCapture::~WasapiCapture() { Stop(); }

bool WasapiCapture::Start(Kind kind, Sink sink) {
  impl_->kind = kind;
  impl_->sink = std::move(sink);
  impl_->running = true;
  impl_->started_ok = false;
  impl_->start_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  Impl* impl = impl_.get();
  impl_->thread = std::thread([impl] { impl->Run(); });
  // Block until the worker reports init success/failure. The worker owns the COM
  // objects on its OWN MTA thread, so there is never cross-apartment marshaling
  // to the (STA) platform thread -- which would otherwise deadlock on stop.
  if (impl_->start_event) {
    WaitForSingleObject(impl_->start_event, 5000);
  }
  if (!impl_->started_ok.load()) {
    impl_->running = false;
    if (impl_->thread.joinable()) impl_->thread.join();
    if (impl_->start_event) {
      CloseHandle(impl_->start_event);
      impl_->start_event = nullptr;
    }
    return false;
  }
  return true;
}

void WasapiCapture::Impl::Run() {
  // CRITICAL: create, USE and release ALL WASAPI COM objects on THIS worker
  // thread, in its own MTA apartment. If they were created on the STA platform
  // thread (as before) and used here, joining this thread on stop -- while the
  // platform thread is blocked in join() and not pumping messages -- deadlocks a
  // marshaled GetBuffer call. The mic produces continuously so it hits this every
  // time: the app hangs AND the recording never finalizes (a corrupt file). With
  // the COM lifecycle confined to this thread there is nothing to marshal.
  const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> client;
    ComPtr<IAudioCaptureClient> capture;
    bool ok = false;
    do {
      if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                  reinterpret_cast<void**>(enumerator.put())))) {
        break;
      }
      // Loopback captures the render endpoint; mic captures the capture endpoint.
      const EDataFlow flow = (kind == Kind::kLoopback) ? eRender : eCapture;
      if (FAILED(enumerator->GetDefaultAudioEndpoint(flow, eConsole,
                                                     device.put())) ||
          !device) {
        break;
      }
      if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                  reinterpret_cast<void**>(client.put()))) ||
          !client) {
        break;
      }
      // Canonical capture format: 48 kHz / stereo / 16-bit PCM. AUTOCONVERTPCM
      // makes WASAPI convert from the device mix format (no hand-written
      // resampler). No gain is applied -- the system audio is captured as-is.
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
      // 200ms shared buffer; polled (loopback does not support event mode).
      const REFERENCE_TIME buffer_100ns = 2000000;
      if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, buffer_100ns,
                                    0, &wfx, nullptr))) {
        break;
      }
      if (FAILED(client->GetService(
              __uuidof(IAudioCaptureClient),
              reinterpret_cast<void**>(capture.put()))) ||
          !capture) {
        break;
      }
      if (FAILED(client->Start())) break;
      ok = true;
    } while (false);

    started_ok = ok;
    if (start_event) SetEvent(start_event);  // unblock WasapiCapture::Start

    if (ok) {
      while (running.load()) {
        Sleep(10);
        UINT32 packet = 0;
        if (FAILED(capture->GetNextPacketSize(&packet))) continue;
        while (packet > 0 && running.load()) {
          BYTE* data = nullptr;
          UINT32 frames = 0;
          DWORD buf_flags = 0;
          UINT64 dev_pos = 0;
          UINT64 qpc_pos = 0;  // 100ns QPC, same epoch as WGC frame times
          HRESULT hr = capture->GetBuffer(&data, &frames, &buf_flags, &dev_pos,
                                          &qpc_pos);
          if (FAILED(hr)) break;
          if (frames > 0) {
            AudioPacket pkt;
            pkt.qpc100ns = Qpc100ns();  // shared QPC clock (see recorder.cpp)
            const size_t count = static_cast<size_t>(frames) * kChannels;
            pkt.samples.resize(count);
            if (buf_flags & AUDCLNT_BUFFERFLAGS_SILENT) {
              std::fill(pkt.samples.begin(), pkt.samples.end(),
                        static_cast<int16_t>(0));
            } else {
              std::memcpy(pkt.samples.data(), data, count * sizeof(int16_t));
            }
            if (sink) sink(std::move(pkt));
          }
          capture->ReleaseBuffer(frames);
          if (FAILED(capture->GetNextPacketSize(&packet))) break;
        }
      }
      client->Stop();
    }
  }  // ComPtr destructors release the COM objects HERE, on this thread,...
  if (com) CoUninitialize();  // ...before its MTA apartment is uninitialized.
}

void WasapiCapture::Stop() {
  impl_->running = false;
  // The worker owns + releases its COM on its own thread, so this join makes no
  // COM call and cannot deadlock (the cause of the mic finish/abort hang).
  if (impl_->thread.joinable()) impl_->thread.join();
  if (impl_->start_event) {
    CloseHandle(impl_->start_event);
    impl_->start_event = nullptr;
  }
}
