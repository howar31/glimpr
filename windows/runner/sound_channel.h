#ifndef RUNNER_SOUND_CHANNEL_H_
#define RUNNER_SOUND_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Hosts the "glimpr/sound" method channel: play a short feedback cue (shutter /
// completion) whose wav bytes arrive raw from Dart, via XAudio2. Replaces the
// audioplayers package, whose Windows backend raised an access violation when a
// cue played while a recording's encoder was running. XAudio2 mixes multiple
// source voices, so overlapping cues play together instead of cutting each
// other off. Registered on every engine, like ClipboardChannel.
class SoundChannel {
 public:
  explicit SoundChannel(flutter::BinaryMessenger* messenger);
  ~SoundChannel();

  SoundChannel(const SoundChannel&) = delete;
  SoundChannel& operator=(const SoundChannel&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_SOUND_CHANNEL_H_
