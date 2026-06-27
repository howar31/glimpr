#ifndef RUNNER_RECORD_CHANNEL_H_
#define RUNNER_RECORD_CHANNEL_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

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

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Emit(const char* method);
  void Emit(const char* method, flutter::EncodableValue args);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<Recorder> recorder_;
  HWND control_hwnd_ = nullptr;
};

#endif  // RUNNER_RECORD_CHANNEL_H_
