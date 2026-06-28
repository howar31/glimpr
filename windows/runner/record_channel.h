#ifndef RUNNER_RECORD_CHANNEL_H_
#define RUNNER_RECORD_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>
#include <string>

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

  // Notified when recording starts/stops so the tray can reflect the state
  // (active=true on start; active=false on stop -- graceful=false for an abort /
  // failure, true for a normal finish). Set once by FlutterWindow.
  void SetRecordingStateCallback(std::function<void(bool active, bool graceful)> cb) {
    on_state_ = std::move(cb);
  }

 private:
  void NotifyState(bool active, bool graceful) {
    if (on_state_) on_state_(active, graceful);
  }
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
  // (region/window modes); [scrim] dims the other displays AND the area outside
  // the rect on the recording display. [output_path]/[gif] drive the strip's
  // file-size / frame-count readout.
  void ShowChrome(const Recorder::StartedInfo& info, bool border, bool scrim,
                  int max_duration_sec, const std::string& output_path, bool gif,
                  HWND follow);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<Recorder> recorder_;
  std::unique_ptr<RecordChrome> chrome_;
  HWND control_hwnd_ = nullptr;

  // Held across a countdown: the spec to start when the countdown completes.
  Recorder::Spec pending_spec_;
  bool pending_scrim_ = true;
  std::function<void(bool, bool)> on_state_;  // recording-state -> tray
};

#endif  // RUNNER_RECORD_CHANNEL_H_
