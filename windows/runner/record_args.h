#ifndef RUNNER_RECORD_ARGS_H_
#define RUNNER_RECORD_ARGS_H_

#include <cstdlib>
#include <string>
#include <vector>

#include "base64.h"
#include "recorder.h"

// The --record-worker argv contract, shared by the worker (which parses it) and
// its tests. The recorder client builds the matching command line; keeping the
// parse here makes the round-trip unit-testable without spawning a process.
namespace recordargs {

// The value of a "--key=value" argv token (ASCII: numbers / base64 / keywords).
// Empty if the key is absent.
inline std::string ArgVal(const std::vector<std::wstring>& args,
                          const wchar_t* key) {
  const std::wstring k = key;
  for (const auto& a : args) {
    if (a.rfind(k, 0) == 0) {
      const std::wstring v = a.substr(k.size());
      std::string narrow;  // values are ASCII (numbers / base64 / keywords)
      narrow.reserve(v.size());
      for (wchar_t c : v) narrow.push_back(static_cast<char>(c));
      return narrow;
    }
  }
  return "";
}

// Decode the full --record-worker token set into a Recorder::Spec, applying the
// same defaults the worker uses (fps/gif_fps floors, quality "high", cursor
// defaults on).
inline Recorder::Spec ParseSpec(const std::vector<std::wstring>& args) {
  Recorder::Spec s;
  const std::string mode = ArgVal(args, L"--mode=");
  s.mode = mode == "window"   ? Recorder::Mode::kWindow
           : mode == "region" ? Recorder::Mode::kRegion
                              : Recorder::Mode::kDisplay;
  s.output_path = b64::Decode(ArgVal(args, L"--output-b64="));
  s.display_id = _atoi64(ArgVal(args, L"--display=").c_str());
  s.window_id = _atoi64(ArgVal(args, L"--window=").c_str());
  s.x = atof(ArgVal(args, L"--x=").c_str());
  s.y = atof(ArgVal(args, L"--y=").c_str());
  s.w = atof(ArgVal(args, L"--w=").c_str());
  s.h = atof(ArgVal(args, L"--h=").c_str());
  s.fps = atoi(ArgVal(args, L"--fps=").c_str());
  if (s.fps <= 0) s.fps = 30;
  s.hevc = ArgVal(args, L"--hevc=") == "1";
  s.hdr = ArgVal(args, L"--hdr=") == "1";
  s.gif = ArgVal(args, L"--gif=") == "1";
  s.gif_fps = atoi(ArgVal(args, L"--giffps=").c_str());
  if (s.gif_fps <= 0) s.gif_fps = 15;
  s.show_cursor = ArgVal(args, L"--cursor=") != "0";
  const std::string q = ArgVal(args, L"--quality=");
  s.video_quality = q.empty() ? "high" : q;
  s.max_long_side = atoi(ArgVal(args, L"--maxlong=").c_str());
  s.max_duration_sec = atoi(ArgVal(args, L"--maxdur=").c_str());
  s.system_audio = ArgVal(args, L"--sysaudio=") == "1";
  s.microphone = ArgVal(args, L"--mic=") == "1";
  s.merge_audio = ArgVal(args, L"--merge=") == "1";
  return s;
}

}  // namespace recordargs

#endif  // RUNNER_RECORD_ARGS_H_
