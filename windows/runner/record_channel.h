#ifndef RUNNER_RECORD_CHANNEL_H_
#define RUNNER_RECORD_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include "record_chrome.h"
#include "recorder.h"

// The window message a background recorder thread posts to the control window to
// marshal an async event (e.g. a mid-recording encode failure) back to the
// platform thread before any Dart event is emitted. WM_GLIMPR_TRAY is WM_APP + 1.
#define WM_GLIMPR_RECORD (WM_APP + 2)

// Hosts the "glimpr/record" method channel on the CONTROL engine: the Windows
// half of the screen-recording seam. Mirrors the macOS RecordingChannel. Owns the
// single active Recorder; parses start() args into a RecordSpec, drives start/
// stop/pause/resume/abort, and emits the onRecord* lifecycle events Dart's
// RecordController listens for. In-runner, not a pub plugin.
class RecordChannel {
 public:
  RecordChannel(flutter::BinaryMessenger* messenger, HWND control_hwnd);
  ~RecordChannel();

  RecordChannel(const RecordChannel&) = delete;
  RecordChannel& operator=(const RecordChannel&) = delete;

  // Routed from FlutterWindow::MessageHandler on WM_GLIMPR_RECORD. Runs on the
  // platform thread, so it may safely emit Dart events.
  void OnNativeEvent(uint32_t code);

  // Relay an overlay engine's record-select confirm/cancel to this control
  // engine's Dart (emits onRecordSelection -> RecordController). Platform thread.
  void RelaySelection(flutter::EncodableValue args);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Stop the active recording + finalize, emitting onRecordStopping then
  // onRecordFinished (or onRecordFailed). Shared by the stop method and the
  // native auto-stop event. Platform thread only.
  void FinishActive();
  void Emit(const char* method);
  void Emit(const char* method, flutter::EncodableValue args);
  // Actually start the recorder (after any countdown) + emit onRecordStarted +
  // show the chrome, or emit onRecordFailed.
  void DoStart(const Recorder::Spec& spec, bool show_scrim);
  // Show the recording chrome for the started recording + wire its Stop/Pause/
  // Abort buttons back to this channel. [border] draws the recorded-rect outline
  // (region/window modes); [scrim] dims the other displays.
  void ShowChrome(const Recorder::StartedInfo& info, bool border, bool scrim);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<Recorder> recorder_;
  std::unique_ptr<RecordChrome> chrome_;
  HWND control_hwnd_ = nullptr;

  // Held across a countdown: the spec to start when the countdown completes.
  Recorder::Spec pending_spec_;
  bool pending_scrim_ = true;
};

#endif  // RUNNER_RECORD_CHANNEL_H_
