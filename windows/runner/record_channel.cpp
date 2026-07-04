#include "record_channel.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <thread>
#include <utility>

#include "channel_args.h"
#include "perf_log.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace chanarg;

}  // namespace

RecordChannel::RecordChannel(flutter::BinaryMessenger* messenger,
                             HWND control_hwnd)
    : recorder_(std::make_unique<RecorderClient>()),
      chrome_(std::make_unique<RecordChrome>()),
      control_hwnd_(control_hwnd) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "glimpr/record",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

RecordChannel::~RecordChannel() = default;

void RecordChannel::Emit(const char* method) {
  channel_->InvokeMethod(method, nullptr);
}

void RecordChannel::Emit(const char* method, EncodableValue args) {
  channel_->InvokeMethod(method,
                         std::make_unique<EncodableValue>(std::move(args)));
}

void RecordChannel::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = call.method_name();

  if (method == "isAvailable") {
    // The native recording module exists on Windows (WGC + Media Foundation).
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "start") {
    if (finishing_.load()) {
      // The previous recording is still finalizing on the async-stop worker;
      // one RecorderClient/worker at a time. Surfaces as a normal failure.
      Emit("onRecordFailed",
           EncodableValue(EncodableMap{
               {EncodableValue("message"),
                EncodableValue("previous recording is still finalizing")}}));
      result->Success();
      return;
    }
    const EncodableMap empty;
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const EncodableMap& m = args ? *args : empty;

    Recorder::Spec spec;
    const std::string mode = GetString(m, "mode", "display");
    spec.mode = mode == "window" ? Recorder::Mode::kWindow
                : mode == "region" || mode == "lastRegion"
                    ? Recorder::Mode::kRegion
                    : Recorder::Mode::kDisplay;
    spec.output_path = GetString(m, "outputPath", "");
    spec.display_id = GetInt64(m, "displayId", 0);
    spec.window_id = GetInt64(m, "windowId", 0);
    if (HasKey(m, "w") && HasKey(m, "h")) {
      spec.x = GetDouble(m, "x", 0);
      spec.y = GetDouble(m, "y", 0);
      spec.w = GetDouble(m, "w", 0);
      spec.h = GetDouble(m, "h", 0);
    }
    spec.fps = GetInt(m, "fps", 30);
    spec.hevc = GetBool(m, "hevc", false);
    spec.hdr = GetBool(m, "hdr", false);
    spec.gif = GetBool(m, "gif", false);
    spec.gif_fps = GetInt(m, "gifFps", 15);
    spec.show_cursor = GetBool(m, "showsCursor", true);
    spec.video_quality = GetString(m, "videoQuality", "high");
    spec.max_long_side = GetInt(m, "maxLongSide", 0);
    spec.max_duration_sec = GetInt(m, "maxDuration", 0);
    spec.system_audio = GetBool(m, "systemAudio", false);
    spec.microphone = GetBool(m, "microphone", false);
    spec.merge_audio = GetBool(m, "mergeAudio", false);

    const int countdown = GetInt(m, "countdown", 0);
    const bool show_scrim = GetBool(m, "showScrim", true);
    // A countdown shows a HUD first, then starts on completion (or aborts on a
    // click); otherwise start immediately.
    if (countdown > 0 && chrome_) {
      pending_spec_ = spec;
      pending_scrim_ = show_scrim;
      const bool cd_border = spec.mode != Recorder::Mode::kDisplay;
      // Window mode: follow the moving/resized window during the countdown too.
      HWND follow =
          (spec.mode == Recorder::Mode::kWindow && spec.window_id)
              ? reinterpret_cast<HWND>(static_cast<intptr_t>(spec.window_id))
              : nullptr;
      chrome_->ShowCountdown(
          spec.display_id, spec.x, spec.y, spec.w, spec.h, countdown, cd_border,
          show_scrim, [this]() { DoStart(pending_spec_, pending_scrim_); },
          [this]() {
            if (chrome_) chrome_->Hide();  // tear the countdown frame on cancel
            Emit("onRecordAborted");
          },
          follow);
    } else {
      DoStart(spec, show_scrim);
    }
    result->Success();
    return;
  }

  if (method == "stop") {
    FinishActive();
    result->Success();
    return;
  }

  if (method == "abort") {
    if (recorder_->active()) {
      recorder_->Abort();
      Emit("onRecordAborted");
    }
    if (chrome_) chrome_->Hide();
    NotifyState(false, false);  // abort -> tray snaps back to idle
    result->Success();
    return;
  }

  if (method == "pause") {
    if (recorder_->active() && !recorder_->paused()) {
      recorder_->Pause();
      Emit("onRecordPaused");
      if (chrome_) chrome_->SetPaused(true);
    }
    result->Success();
    return;
  }

  if (method == "resume") {
    if (recorder_->active() && recorder_->paused()) {
      recorder_->Resume();
      Emit("onRecordResumed");
      if (chrome_) chrome_->SetPaused(false);
    }
    result->Success();
    return;
  }

  if (method == "setRecordLabels") {
    // Localized strip / countdown labels pushed once from Dart at boot (the
    // runner C++ is ASCII-only, so Dart owns l10n). Stored on the chrome; used
    // (and the buttons sized) on the next Show.
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (args && chrome_) {
      auto W = [](const std::string& s) -> std::wstring {
        if (s.empty()) return std::wstring();
        int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
        if (n <= 0) return std::wstring();
        std::wstring w(static_cast<size_t>(n - 1), L'\0');
        MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
        return w;
      };
      RecordChrome::Labels lbl;  // English defaults
      auto get = [&](const char* k, const std::wstring& dflt) {
        const std::string s = GetString(*args, k, "");
        return s.empty() ? dflt : W(s);
      };
      lbl.finish = get("finish", lbl.finish);
      lbl.pause = get("pause", lbl.pause);
      lbl.resume = get("resume", lbl.resume);
      lbl.abort = get("abort", lbl.abort);
      lbl.confirm = get("confirm", lbl.confirm);
      lbl.frames = get("frames", lbl.frames);
      lbl.countdown_cancel = get("countdownCancel", lbl.countdown_cancel);
      chrome_->SetLabels(lbl);
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

void RecordChannel::FinishActive() {
  if (!recorder_->active() || finishing_.exchange(true)) return;
  // Mirror macOS: at a graceful stop the recording-red SNAPS off (graceful=false,
  // so it does NOT ease and fight the pulse), the chrome drops IMMEDIATELY, and
  // the logo-gradient "processing" pulse runs on the tray while the file
  // finalizes. The blocking RecorderClient::Stop (encoder join + finalize; a
  // long GIF takes tens of seconds) runs on a worker thread and marshals its
  // result back via kAsyncStopDone -- the platform thread (all engines' UI)
  // stays live during the finalize, full macOS parity.
  NotifyState(false, false);
  NotifyProcessing(true);
  if (chrome_) chrome_->Hide();  // the strip is in the recording's chrome; drop it first
  Emit("onRecordStopping");
  perf::Mark("recordStopBegin");
  std::thread([this]() {
    std::string path, error;
    const bool ok = recorder_->Stop(&path, &error);
    {
      std::lock_guard<std::mutex> lock(stop_mu_);
      stop_ok_ = ok;
      stop_path_ = std::move(path);
      stop_error_ = std::move(error);
    }
    PostMessage(control_hwnd_, WM_GLIMPR_RECORD, Recorder::kAsyncStopDone, 0);
  }).detach();
}

void RecordChannel::DoStart(const Recorder::Spec& spec, bool show_scrim) {
  Recorder::StartedInfo info;
  std::string error;
  perf::Mark("recordStartBegin");
  const bool ok =
      recorder_->Start(spec, control_hwnd_, WM_GLIMPR_RECORD, &info, &error);
  perf::Mark(ok ? "recordWorkerStarted ok=1" : "recordWorkerStarted ok=0");
  if (ok) {
    NotifyState(true, true);  // recording started -> tray goes recording-red
    Emit("onRecordStarted",
         EncodableValue(EncodableMap{
             {EncodableValue("displayId"), EncodableValue(info.display_id)},
             {EncodableValue("x"), EncodableValue(info.x)},
             {EncodableValue("y"), EncodableValue(info.y)},
             {EncodableValue("w"), EncodableValue(info.w)},
             {EncodableValue("h"), EncodableValue(info.h)}}));
    // Window mode: the chrome follows the moving/resized window.
    HWND follow =
        (spec.mode == Recorder::Mode::kWindow && spec.window_id)
            ? reinterpret_cast<HWND>(static_cast<intptr_t>(spec.window_id))
            : nullptr;
    ShowChrome(info, spec.mode != Recorder::Mode::kDisplay, show_scrim,
               spec.max_duration_sec, spec.output_path, spec.gif, follow);
  } else {
    Emit("onRecordFailed",
         EncodableValue(EncodableMap{
             {EncodableValue("message"), EncodableValue(error)}}));
  }
}

void RecordChannel::ShowChrome(const Recorder::StartedInfo& info, bool border,
                               bool scrim, int max_duration_sec,
                               const std::string& output_path, bool gif,
                               HWND follow) {
  if (!chrome_) return;
  chrome_->Show(info.display_id, info.x, info.y, info.w, info.h, border, scrim,
                max_duration_sec, gif, output_path,
                [this]() { return recorder_->GifFrameCount(); },
                RecordChrome::Callbacks{
                    [this]() { FinishActive(); },
                    [this]() {
                      if (!recorder_->active()) return;
                      if (recorder_->paused()) {
                        recorder_->Resume();
                        Emit("onRecordResumed");
                      } else {
                        recorder_->Pause();
                        Emit("onRecordPaused");
                      }
                      if (chrome_) chrome_->SetPaused(recorder_->paused());
                    },
                    [this]() {
                      if (recorder_->active()) {
                        recorder_->Abort();
                        Emit("onRecordAborted");
                      }
                      if (chrome_) chrome_->Hide();
                      NotifyState(false, false);  // strip Abort -> tray idle
                    },
                },
                follow);
}

void RecordChannel::RelaySelection(EncodableValue args) {
  Emit("onRecordSelection", std::move(args));
}

void RecordChannel::OnNativeEvent(uint32_t code) {
  if (code == Recorder::kAsyncFailed) {
    // While an async stop is finalizing, a worker failure surfaces through the
    // stop thread's result (Stop unblocks with the error) -- swallowing here
    // avoids a double onRecordFailed.
    if (finishing_.load()) return;
    std::string error = recorder_->TakeAsyncError();
    if (error.empty()) error = "recording failed";
    if (recorder_->active()) recorder_->Abort();  // discard the partial file
    if (chrome_) chrome_->Hide();
    NotifyState(false, false);  // failure -> tray snaps back to idle
    Emit("onRecordFailed",
         EncodableValue(flutter::EncodableMap{
             {flutter::EncodableValue("message"),
              flutter::EncodableValue(error)}}));
  } else if (code == Recorder::kAsyncAutoStop) {
    // The auto-stop poller hit maxDuration: finalize like a user stop.
    FinishActive();
  } else if (code == Recorder::kAsyncStopDone) {
    // The async-stop worker finished finalizing: emit the outcome on the
    // platform thread (FinishActive already dropped the chrome + started the
    // pulse when the stop began).
    bool ok = false;
    std::string path, error;
    {
      std::lock_guard<std::mutex> lock(stop_mu_);
      ok = stop_ok_;
      path = std::move(stop_path_);
      error = std::move(stop_error_);
    }
    perf::Mark(ok ? "recordFinalized ok=1" : "recordFinalized ok=0");
    NotifyProcessing(false);  // pulse ends at the next low (>= 1 full cycle)
    if (ok) {
      Emit("onRecordFinished",
           EncodableValue(EncodableMap{
               {EncodableValue("path"), EncodableValue(path)}}));
    } else {
      Emit("onRecordFailed",
           EncodableValue(EncodableMap{
               {EncodableValue("message"), EncodableValue(error)}}));
    }
    finishing_.store(false);
  }
}
