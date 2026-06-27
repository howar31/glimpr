#include "record_channel.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool GetBool(const EncodableMap& map, const char* key, bool dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<bool>(v)) return *p;
  }
  return dflt;
}

int GetInt(const EncodableMap& map, const char* key, int dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return static_cast<int>(*p);
  }
  return dflt;
}

int64_t GetInt64(const EncodableMap& map, const char* key, int64_t dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<int32_t>(v)) return *p;
    if (auto p = std::get_if<int64_t>(v)) return *p;
  }
  return dflt;
}

double GetDouble(const EncodableMap& map, const char* key, double dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<double>(v)) return *p;
    if (auto p = std::get_if<int32_t>(v)) return static_cast<double>(*p);
    if (auto p = std::get_if<int64_t>(v)) return static_cast<double>(*p);
  }
  return dflt;
}

std::string GetString(const EncodableMap& map, const char* key,
                      const char* dflt) {
  if (const auto* v = Find(map, key)) {
    if (auto p = std::get_if<std::string>(v)) return *p;
  }
  return dflt;
}

bool HasKey(const EncodableMap& map, const char* key) {
  return Find(map, key) != nullptr;
}

}  // namespace

RecordChannel::RecordChannel(flutter::BinaryMessenger* messenger,
                             HWND control_hwnd)
    : recorder_(std::make_unique<Recorder>()), control_hwnd_(control_hwnd) {
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
    spec.gif = GetBool(m, "gif", false);
    spec.gif_fps = GetInt(m, "gifFps", 15);
    spec.show_cursor = GetBool(m, "showsCursor", true);
    spec.video_quality = GetString(m, "videoQuality", "high");
    spec.max_long_side = GetInt(m, "maxLongSide", 0);
    spec.max_duration_sec = GetInt(m, "maxDuration", 0);
    spec.system_audio = GetBool(m, "systemAudio", false);
    spec.microphone = GetBool(m, "microphone", false);

    Recorder::StartedInfo info;
    std::string error;
    const bool ok = recorder_->Start(spec, control_hwnd_, WM_GLIMPR_RECORD,
                                     &info, &error);
    result->Success();
    if (ok) {
      Emit("onRecordStarted",
           EncodableValue(EncodableMap{
               {EncodableValue("displayId"), EncodableValue(info.display_id)},
               {EncodableValue("x"), EncodableValue(info.x)},
               {EncodableValue("y"), EncodableValue(info.y)},
               {EncodableValue("w"), EncodableValue(info.w)},
               {EncodableValue("h"), EncodableValue(info.h)}}));
    } else {
      Emit("onRecordFailed",
           EncodableValue(EncodableMap{
               {EncodableValue("message"), EncodableValue(error)}}));
    }
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
    result->Success();
    return;
  }

  if (method == "pause") {
    if (recorder_->active() && !recorder_->paused()) {
      recorder_->Pause();
      Emit("onRecordPaused");
    }
    result->Success();
    return;
  }

  if (method == "resume") {
    if (recorder_->active() && recorder_->paused()) {
      recorder_->Resume();
      Emit("onRecordResumed");
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

void RecordChannel::FinishActive() {
  if (!recorder_->active()) return;
  Emit("onRecordStopping");
  std::string path, error;
  if (recorder_->Stop(&path, &error)) {
    Emit("onRecordFinished",
         EncodableValue(EncodableMap{
             {EncodableValue("path"), EncodableValue(path)}}));
  } else {
    Emit("onRecordFailed",
         EncodableValue(EncodableMap{
             {EncodableValue("message"), EncodableValue(error)}}));
  }
}

void RecordChannel::OnNativeEvent(uint32_t code) {
  if (code == Recorder::kAsyncFailed) {
    std::string error = recorder_->TakeAsyncError();
    if (error.empty()) error = "recording failed";
    if (recorder_->active()) recorder_->Abort();  // discard the partial file
    Emit("onRecordFailed",
         EncodableValue(flutter::EncodableMap{
             {flutter::EncodableValue("message"),
              flutter::EncodableValue(error)}}));
  } else if (code == Recorder::kAsyncAutoStop) {
    // The auto-stop poller hit maxDuration: finalize like a user stop.
    FinishActive();
  }
}
