#ifndef RUNNER_RECORD_AUDIO_H_
#define RUNNER_RECORD_AUDIO_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

// WASAPI audio capture for screen recording: a loopback client on the default
// render endpoint (system audio) and/or a capture client on the default capture
// endpoint (microphone). Each delivers canonical 48 kHz / stereo / 16-bit PCM,
// timestamped on the QPC 100ns clock -- the same epoch as WGC SystemRelativeTime,
// so audio and video rebase onto one shared session start. The macOS analogue is
// the SCStream .audio / .microphone outputs. The Recorder routes the PCM into the
// Media Foundation sink writer as AAC stream(s).
//
// Format conversion (device mix format -> 48k/stereo/s16) is delegated to WASAPI
// via AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, so there is no hand-written resampler.

// One PCM packet: interleaved 16-bit stereo at 48 kHz, with the QPC capture time
// (100ns) of its first frame.
struct AudioPacket {
  std::vector<int16_t> samples;  // interleaved L,R,L,R,...
  int64_t qpc100ns = 0;
};

// Captures one WASAPI endpoint on its own polling thread.
class WasapiCapture {
 public:
  enum class Kind { kLoopback, kMicrophone };
  // By value so the producer moves the packet in and the consumer moves it
  // into its queue (each was copied twice per ~10ms poll before).
  using Sink = std::function<void(AudioPacket)>;

  static constexpr uint32_t kSampleRate = 48000;
  static constexpr uint16_t kChannels = 2;

  WasapiCapture();
  ~WasapiCapture();

  WasapiCapture(const WasapiCapture&) = delete;
  WasapiCapture& operator=(const WasapiCapture&) = delete;

  // Start capturing; each packet (48k/stereo/s16) is handed to |sink| on the
  // capture thread. Returns false on setup failure (caller proceeds without it).
  bool Start(Kind kind, Sink sink);
  void Stop();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_RECORD_AUDIO_H_
