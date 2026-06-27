#ifndef RUNNER_RECORDER_H_
#define RUNNER_RECORDER_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

// One screen-recording session: continuous Windows.Graphics.Capture frames
// encoded by a Media Foundation IMFSinkWriter to an mp4 (H.264 in S6a; HEVC and
// GIF and audio land in later sub-slices). One active Recorder at a time (the
// RecordChannel owns it). The Windows analogue of the macOS RecordingController +
// RecordingWriter + RecordingSink: we own the frame pump, the timestamps and the
// pause/rebase math (the "engine B" timeline model).
//
// Threading: Start/Stop/Abort run on the platform (UI) thread. WGC delivers
// frames on a free-threaded pool; those callbacks copy pixels off the GPU under a
// lock and hand them to a single encoder worker thread (the lone IMFSinkWriter
// writer, mirroring the macOS serial sample queue). A fatal mid-recording error
// is reported by posting |async_msg| to |async_target| (the control window),
// which routes back to the platform thread before any Dart event is emitted --
// Flutter channels are never touched off the platform thread.
class Recorder {
 public:
  enum class Mode { kDisplay, kRegion, kWindow };

  struct Spec {
    Mode mode = Mode::kDisplay;
    std::string output_path;  // UTF-8; Dart builds it (extension .mp4)
    int64_t display_id = 0;   // HMONITOR round-tripped as int64 (display/region)
    int64_t window_id = 0;    // HWND round-tripped as int64 (window mode)
    double x = 0, y = 0, w = 0, h = 0;  // display-local logical pts (region mode)
    int fps = 30;
    bool hevc = false;
    bool gif = false;     // direct GIF (WIC) instead of mp4; no audio
    int gif_fps = 15;     // GIF frame rate (throttle + per-frame delay)
    bool show_cursor = true;
    std::string video_quality = "high";  // low|medium|high -> bitrate bpp tier
    int max_long_side = 0;               // px, 0 = native (mp4 cap)
    int max_duration_sec = 0;            // auto-stop after N unpaused seconds (0 = off)
    bool system_audio = false;           // WASAPI loopback (default render endpoint)
    bool microphone = false;             // WASAPI capture (default capture endpoint)
    bool merge_audio = false;            // sum system + mic into ONE AAC track (both-on only)
  };

  // The recorded rect reported back to Dart as onRecordStarted (display-local
  // TOP-LEFT logical points; full-display rect for display mode).
  struct StartedInfo {
    int64_t display_id = 0;
    double x = 0, y = 0, w = 0, h = 0;
  };

  // Async event codes posted to the control window (wparam of |async_msg|).
  static constexpr uint32_t kAsyncFailed = 1;
  static constexpr uint32_t kAsyncAutoStop = 2;

  Recorder();
  ~Recorder();

  Recorder(const Recorder&) = delete;
  Recorder& operator=(const Recorder&) = delete;

  // Begin capturing + encoding. Returns false (and fills *error) on setup
  // failure; on success fills *out with the recorded rect. Platform thread only.
  bool Start(const Spec& spec, HWND async_target, UINT async_msg,
             StartedInfo* out, std::string* error);

  // Stop + finalize the file (blocks briefly while the sink drains). Returns the
  // output path in *out_path on success, else fills *error. Platform thread only.
  bool Stop(std::string* out_path, std::string* error);

  // Discard the active recording and delete the partial file. Platform thread.
  void Abort();

  // Pause / resume the timeline (one continuous file; the paused span is excluded
  // from the output and from the auto-stop elapsed). Platform thread; no-op unless
  // recording. Mirrors the macOS pause-rebase.
  void Pause();
  void Resume();

  bool active() const { return active_; }
  bool paused() const;

  // Frames appended to the GIF so far (the strip readout; GIF buffers until
  // finalize so its on-disk size is 0 mid-record). 0 for the mp4 path. Reads an
  // atomic written by the encoder thread; safe to call from the platform thread.
  int GifFrameCount() const;

  // The last fatal error captured by the encoder worker (for the async-failed
  // path). Empty if none.
  std::string TakeAsyncError();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  bool active_ = false;
};

#endif  // RUNNER_RECORDER_H_
