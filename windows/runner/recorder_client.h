#ifndef RUNNER_RECORDER_CLIENT_H_
#define RUNNER_RECORDER_CLIENT_H_

#include <windows.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

#include "recorder.h"

// Drives a screen recording in a SEPARATE worker process (glimpr.exe
// --record-worker) so a capture/encode crash kills only the worker, never the
// main app. Exposes the SAME interface as Recorder, so RecordChannel is
// unchanged apart from the member type. The spec is passed to the worker via
// argv; control (pause/resume/stop/abort) via the worker's stdin; lifecycle
// events via the worker's stdout, parsed by a reader thread. Mid-recording async
// events (auto-stop, a worker failure, or an unexpected worker exit) are posted
// to the control window via |async_msg| exactly like Recorder -- so
// RecordChannel::OnNativeEvent is unchanged and the main app survives a worker
// crash (it reports onRecordFailed).
class RecorderClient {
 public:
  RecorderClient();
  ~RecorderClient();

  RecorderClient(const RecorderClient&) = delete;
  RecorderClient& operator=(const RecorderClient&) = delete;

  bool Start(const Recorder::Spec& spec, HWND async_target, UINT async_msg,
             Recorder::StartedInfo* out, std::string* error);
  bool Stop(std::string* out_path, std::string* error);
  void Abort();
  void Pause();
  void Resume();

  bool active() const { return active_.load(); }
  bool paused() const { return paused_.load(); }
  int GifFrameCount() const { return gif_frames_.load(); }
  std::string TakeAsyncError();

 private:
  enum class Phase { kIdle, kStarting, kRunning, kStopping, kDone };

  void ReaderLoop();
  void HandleLine(const std::string& line);
  void WriteCommand(const char* cmd);
  void Cleanup();

  HWND async_target_ = nullptr;
  UINT async_msg_ = 0;

  HANDLE process_ = nullptr;          // worker process
  HANDLE child_stdout_rd_ = nullptr;  // we read worker events
  HANDLE child_stdin_wr_ = nullptr;   // we write worker commands
  std::thread reader_;

  std::mutex mu_;
  std::condition_variable cv_;
  Phase phase_ = Phase::kIdle;
  Recorder::StartedInfo started_info_{};
  std::string finished_path_;
  std::string error_;
  std::string async_error_;

  std::atomic<bool> active_{false};
  std::atomic<bool> paused_{false};
  std::atomic<int> gif_frames_{0};
};

#endif  // RUNNER_RECORDER_CLIENT_H_
