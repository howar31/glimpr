#include "sound_channel.h"

#include <windows.h>
#include <xaudio2.h>

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "wav_parse.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Parse a RIFF/WAVE image: locate the 'fmt ' and 'data' chunks. Returns false
// if it is not a usable PCM WAV. `fmt` receives the format; `pcm`/`pcm_len` the
// sample bytes (pointing into the caller's buffer, which must outlive playback).
using wavfmt::ParseWav;

// A playing cue: the XAudio2 source voice plus the PCM bytes it streams from
// (XAudio2 references this memory until playback ends, so it is kept alive
// here and freed only when the voice is reaped).
struct ActiveVoice {
  IXAudio2SourceVoice* voice = nullptr;
  std::vector<uint8_t> pcm;
};

// Process-wide XAudio2 engine. Created lazily on the first cue. All access is on
// the platform (UI) thread -- every channel handler runs there -- so no locking
// is needed. Multiple source voices mix on the one mastering voice, so cues
// OVERLAP instead of cutting each other off (unlike PlaySound).
struct Engine {
  IXAudio2* xa = nullptr;
  IXAudio2MasteringVoice* master = nullptr;
  std::vector<ActiveVoice> actives;
  bool ok = false;
};

Engine& Eng() {
  static Engine e;
  return e;
}

bool EnsureEngine() {
  Engine& e = Eng();
  if (e.ok) return true;
  if (FAILED(XAudio2Create(&e.xa, 0, XAUDIO2_DEFAULT_PROCESSOR))) {
    e.xa = nullptr;
    return false;
  }
  if (FAILED(e.xa->CreateMasteringVoice(&e.master))) {
    e.xa->Release();
    e.xa = nullptr;
    e.master = nullptr;
    return false;
  }
  e.ok = true;
  return true;
}

void PlayCue(const uint8_t* data, size_t len) {
  if (!EnsureEngine()) return;
  Engine& e = Eng();

  // Reap finished voices (their buffer has drained) so they do not accumulate.
  for (size_t i = 0; i < e.actives.size();) {
    XAUDIO2_VOICE_STATE st{};
    e.actives[i].voice->GetState(&st, XAUDIO2_VOICE_NOSAMPLESPLAYED);
    if (st.BuffersQueued == 0) {
      e.actives[i].voice->DestroyVoice();
      e.actives.erase(e.actives.begin() + i);
    } else {
      ++i;
    }
  }

  WAVEFORMATEX fmt{};
  const uint8_t* pcm = nullptr;
  uint32_t pcm_len = 0;
  if (!ParseWav(data, len, fmt, pcm, pcm_len)) return;

  IXAudio2SourceVoice* voice = nullptr;
  if (FAILED(e.xa->CreateSourceVoice(&voice, &fmt))) return;

  ActiveVoice av;
  av.voice = voice;
  av.pcm.assign(pcm, pcm + pcm_len);
  XAUDIO2_BUFFER buf{};
  buf.AudioBytes = pcm_len;
  buf.pAudioData = av.pcm.data();
  buf.Flags = XAUDIO2_END_OF_STREAM;
  if (FAILED(voice->SubmitSourceBuffer(&buf)) || FAILED(voice->Start(0))) {
    voice->DestroyVoice();
    return;
  }
  e.actives.push_back(std::move(av));
}

}  // namespace

SoundChannel::SoundChannel(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/sound",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

SoundChannel::~SoundChannel() = default;

void SoundChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "play") {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const std::vector<uint8_t>* bytes = nullptr;
    if (args) {
      auto it = args->find(EncodableValue(std::string("bytes")));
      if (it != args->end()) {
        bytes = std::get_if<std::vector<uint8_t>>(&it->second);
      }
    }
    if (!bytes || bytes->empty()) {
      result->Error("bad_args", "play expects non-empty wav bytes");
      return;
    }
    PlayCue(bytes->data(), bytes->size());
    result->Success(EncodableValue());
    return;
  }
  result->NotImplemented();
}
