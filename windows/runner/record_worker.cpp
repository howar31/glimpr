#include "record_worker.h"

#include <windows.h>
// shellapi.h (CommandLineToArgvW) must follow windows.h.
#include <shellapi.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "recorder.h"

namespace {

// Recorder posts its async events here (wparam = Recorder::kAsync*); stdin
// commands are marshalled to the worker's main thread here too.
constexpr UINT WM_WORKER_RECORD = WM_APP + 2;
constexpr UINT WM_WORKER_CMD = WM_APP + 10;
enum WorkerCmd { CMD_PAUSE = 1, CMD_RESUME, CMD_STOP, CMD_ABORT };

Recorder* g_recorder = nullptr;
HANDLE g_stdout = nullptr;

void WriteLine(const std::string& s) {
  if (!g_stdout) return;
  std::string line = s;
  line += "\n";
  DWORD written = 0;
  WriteFile(g_stdout, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
}

// Standard base64 decode (the output path arrives base64'd to avoid argv
// quoting); returns the decoded UTF-8 bytes.
std::string B64Decode(const std::string& in) {
  auto val = [](char c) -> int {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
  };
  std::string out;
  int buf = 0, bits = 0;
  for (char c : in) {
    if (c == '=') break;
    int v = val(c);
    if (v < 0) continue;
    buf = (buf << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += static_cast<char>((buf >> bits) & 0xFF);
    }
  }
  return out;
}

// The value of a "--key=value" argv token (ASCII; the output path value is
// base64 so it is ASCII too). Empty if absent.
std::string ArgVal(const std::vector<std::wstring>& args, const wchar_t* key) {
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

Recorder::Spec ParseSpec(const std::vector<std::wstring>& args) {
  Recorder::Spec s;
  const std::string mode = ArgVal(args, L"--mode=");
  s.mode = mode == "window"   ? Recorder::Mode::kWindow
           : mode == "region" ? Recorder::Mode::kRegion
                              : Recorder::Mode::kDisplay;
  s.output_path = B64Decode(ArgVal(args, L"--output-b64="));
  s.display_id = _atoi64(ArgVal(args, L"--display=").c_str());
  s.window_id = _atoi64(ArgVal(args, L"--window=").c_str());
  s.x = atof(ArgVal(args, L"--x=").c_str());
  s.y = atof(ArgVal(args, L"--y=").c_str());
  s.w = atof(ArgVal(args, L"--w=").c_str());
  s.h = atof(ArgVal(args, L"--h=").c_str());
  s.fps = atoi(ArgVal(args, L"--fps=").c_str());
  if (s.fps <= 0) s.fps = 30;
  s.hevc = ArgVal(args, L"--hevc=") == "1";
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

LRESULT CALLBACK WorkerProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_WORKER_RECORD) {
    if (wparam == Recorder::kAsyncFailed) {
      std::string e = g_recorder ? g_recorder->TakeAsyncError() : std::string();
      if (e.empty()) e = "recording failed";
      WriteLine("FAILED async " + e);
      if (g_recorder) g_recorder->Abort();
      PostQuitMessage(1);
    } else if (wparam == Recorder::kAsyncAutoStop) {
      // Mirror the in-process behaviour: signal, then wait for the main app to
      // send STOP (which finalizes), rather than self-stopping.
      WriteLine("AUTOSTOP");
    }
    return 0;
  }
  if (msg == WM_WORKER_CMD) {
    switch (wparam) {
      case CMD_PAUSE:
        if (g_recorder) g_recorder->Pause();
        break;
      case CMD_RESUME:
        if (g_recorder) g_recorder->Resume();
        break;
      case CMD_STOP: {
        std::string path, err;
        const bool ok = g_recorder && g_recorder->Stop(&path, &err);
        if (ok) {
          WriteLine("FINISHED " + path);
        } else {
          WriteLine("FAILED stop " + err);
        }
        PostQuitMessage(0);
        break;
      }
      case CMD_ABORT:
        if (g_recorder) g_recorder->Abort();
        WriteLine("ABORTED");
        PostQuitMessage(0);
        break;
    }
    return 0;
  }
  if (msg == WM_TIMER) {
    if (g_recorder) {
      WriteLine("STATS frames=" + std::to_string(g_recorder->GifFrameCount()));
    }
    return 0;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

// Reads stdin lines (the main app's control commands) and marshals each to the
// worker's main thread (which owns the Recorder). EOF means the parent died ->
// abort and exit so no orphan keeps recording.
void StdinReader(HWND wnd) {
  HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
  std::string buf;
  char chunk[256];
  for (;;) {
    DWORD n = 0;
    if (!ReadFile(in, chunk, sizeof(chunk), &n, nullptr) || n == 0) break;
    buf.append(chunk, n);
    size_t nl;
    while ((nl = buf.find('\n')) != std::string::npos) {
      std::string line = buf.substr(0, nl);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      buf.erase(0, nl + 1);
      if (line == "PAUSE") {
        PostMessage(wnd, WM_WORKER_CMD, CMD_PAUSE, 0);
      } else if (line == "RESUME") {
        PostMessage(wnd, WM_WORKER_CMD, CMD_RESUME, 0);
      } else if (line == "STOP") {
        PostMessage(wnd, WM_WORKER_CMD, CMD_STOP, 0);
      } else if (line == "ABORT") {
        PostMessage(wnd, WM_WORKER_CMD, CMD_ABORT, 0);
      }
    }
  }
  PostMessage(wnd, WM_WORKER_CMD, CMD_ABORT, 0);  // parent gone -> abort
}

}  // namespace

int RecordWorkerMain() {
  g_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  int argc = 0;
  LPWSTR* argvw = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::vector<std::wstring> args;
  for (int i = 0; i < argc; ++i) args.push_back(argvw[i]);
  if (argvw) LocalFree(argvw);
  const Recorder::Spec spec = ParseSpec(args);

  WNDCLASSW wc{};
  wc.lpfnWndProc = WorkerProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"GlimprRecordWorker";
  RegisterClassW(&wc);
  HWND wnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
                             HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
  if (!wnd) {
    WriteLine("FAILED start could not create worker window");
    CoUninitialize();
    return 1;
  }

  Recorder recorder;
  g_recorder = &recorder;
  Recorder::StartedInfo info{};
  std::string err;
  bool ok = false;
  try {
    ok = recorder.Start(spec, wnd, WM_WORKER_RECORD, &info, &err);
  } catch (...) {
    ok = false;
    if (err.empty()) err = "exception during start";
  }
  if (!ok) {
    WriteLine("FAILED start " + err);
    g_recorder = nullptr;
    DestroyWindow(wnd);
    CoUninitialize();
    return 1;
  }

  char started[256];
  snprintf(started, sizeof(started), "STARTED %lld %.3f %.3f %.3f %.3f",
           static_cast<long long>(info.display_id), info.x, info.y, info.w,
           info.h);
  WriteLine(started);

  std::thread reader(StdinReader, wnd);
  SetTimer(wnd, 1, 250, nullptr);

  MSG msg;
  while (GetMessage(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }
  const int code = static_cast<int>(msg.wParam);

  KillTimer(wnd, 1);
  g_recorder = nullptr;  // recorder (local) is torn down as this function returns
  reader.detach();       // blocked on stdin ReadFile; ends when the process exits
  DestroyWindow(wnd);
  CoUninitialize();
  return code;
}
