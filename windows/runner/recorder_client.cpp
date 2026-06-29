#include "recorder_client.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

// Standard base64 encode for the output path argv token (so a path with spaces
// or non-ASCII needs no command-line quoting; the worker base64-decodes it).
std::string B64Encode(const std::string& in) {
  static const char* T =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  size_t i = 0;
  while (i + 3 <= in.size()) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16 |
                 (uint32_t)(uint8_t)in[i + 1] << 8 | (uint8_t)in[i + 2];
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += T[(n >> 6) & 63];
    out += T[n & 63];
    i += 3;
  }
  if (i + 1 == in.size()) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16;
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += "==";
  } else if (i + 2 == in.size()) {
    uint32_t n = (uint32_t)(uint8_t)in[i] << 16 | (uint32_t)(uint8_t)in[i + 1] << 8;
    out += T[(n >> 18) & 63];
    out += T[(n >> 12) & 63];
    out += T[(n >> 6) & 63];
    out += '=';
  }
  return out;
}

std::wstring Ascii(const std::string& s) {
  std::wstring w;
  w.reserve(s.size());
  for (char c : s) w.push_back(static_cast<wchar_t>(static_cast<unsigned char>(c)));
  return w;
}

std::wstring BuildCommandLine(const Recorder::Spec& spec) {
  wchar_t exe[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, exe, MAX_PATH);
  const std::wstring mode = spec.mode == Recorder::Mode::kWindow ? L"window"
                            : spec.mode == Recorder::Mode::kRegion ? L"region"
                                                                   : L"display";
  std::wstring cl = L"\"";
  cl += exe;
  cl += L"\" --record-worker";
  cl += L" --mode=" + mode;
  cl += L" --output-b64=" + Ascii(B64Encode(spec.output_path));
  cl += L" --display=" + std::to_wstring(spec.display_id);
  cl += L" --window=" + std::to_wstring(spec.window_id);
  cl += L" --x=" + std::to_wstring(spec.x);
  cl += L" --y=" + std::to_wstring(spec.y);
  cl += L" --w=" + std::to_wstring(spec.w);
  cl += L" --h=" + std::to_wstring(spec.h);
  cl += L" --fps=" + std::to_wstring(spec.fps);
  cl += L" --hevc=" + std::to_wstring(spec.hevc ? 1 : 0);
  cl += L" --gif=" + std::to_wstring(spec.gif ? 1 : 0);
  cl += L" --giffps=" + std::to_wstring(spec.gif_fps);
  cl += L" --cursor=" + std::to_wstring(spec.show_cursor ? 1 : 0);
  cl += L" --quality=" + Ascii(spec.video_quality);
  cl += L" --maxlong=" + std::to_wstring(spec.max_long_side);
  cl += L" --maxdur=" + std::to_wstring(spec.max_duration_sec);
  cl += L" --sysaudio=" + std::to_wstring(spec.system_audio ? 1 : 0);
  cl += L" --mic=" + std::to_wstring(spec.microphone ? 1 : 0);
  cl += L" --merge=" + std::to_wstring(spec.merge_audio ? 1 : 0);
  return cl;
}

}  // namespace

RecorderClient::RecorderClient() = default;

RecorderClient::~RecorderClient() { Cleanup(); }

bool RecorderClient::Start(const Recorder::Spec& spec, HWND async_target,
                           UINT async_msg, Recorder::StartedInfo* out,
                           std::string* error) {
  async_target_ = async_target;
  async_msg_ = async_msg;
  gif_frames_ = 0;
  paused_ = false;

  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  HANDLE out_rd = nullptr, out_wr = nullptr, in_rd = nullptr, in_wr = nullptr;
  if (!CreatePipe(&out_rd, &out_wr, &sa, 0) ||
      !CreatePipe(&in_rd, &in_wr, &sa, 0)) {
    if (error) *error = "pipe creation failed";
    if (out_rd) CloseHandle(out_rd);
    if (out_wr) CloseHandle(out_wr);
    if (in_rd) CloseHandle(in_rd);
    if (in_wr) CloseHandle(in_wr);
    return false;
  }
  // The parent's ends must not be inherited by the worker.
  SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0);

  std::wstring cl = BuildCommandLine(spec);
  std::vector<wchar_t> cmd(cl.begin(), cl.end());
  cmd.push_back(L'\0');

  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdOutput = out_wr;
  si.hStdError = out_wr;
  si.hStdInput = in_rd;
  PROCESS_INFORMATION pi{};
  BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE,
                           CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
  // The worker owns the write end of stdout and the read end of stdin now.
  CloseHandle(out_wr);
  CloseHandle(in_rd);
  if (!ok) {
    if (error) *error = "could not start recording worker";
    CloseHandle(out_rd);
    CloseHandle(in_wr);
    return false;
  }
  CloseHandle(pi.hThread);
  process_ = pi.hProcess;
  child_stdout_rd_ = out_rd;
  child_stdin_wr_ = in_wr;

  {
    std::lock_guard<std::mutex> lk(mu_);
    phase_ = Phase::kStarting;
    error_.clear();
    async_error_.clear();
    finished_path_.clear();
    started_info_ = Recorder::StartedInfo{};
  }
  reader_ = std::thread([this] { ReaderLoop(); });

  std::unique_lock<std::mutex> lk(mu_);
  cv_.wait_for(lk, std::chrono::seconds(20), [this] {
    return phase_ == Phase::kRunning || phase_ == Phase::kDone;
  });
  if (phase_ == Phase::kRunning) {
    if (out) *out = started_info_;
    active_ = true;
    return true;
  }
  if (error) {
    *error = error_.empty() ? "recording worker failed to start" : error_;
  }
  lk.unlock();
  Cleanup();
  return false;
}

bool RecorderClient::Stop(std::string* out_path, std::string* error) {
  {
    std::lock_guard<std::mutex> lk(mu_);
    if (phase_ != Phase::kRunning) {
      if (!finished_path_.empty()) {
        if (out_path) *out_path = finished_path_;
      } else if (error) {
        *error = error_.empty() ? "not recording" : error_;
      }
    } else {
      phase_ = Phase::kStopping;
    }
  }
  WriteCommand("STOP");
  std::unique_lock<std::mutex> lk(mu_);
  // Generous backstop only: a normal finish, a failure, or worker death each
  // wakes this immediately. The long GIF finalize can take many seconds, so do
  // not kill the worker prematurely (that would lose the file).
  cv_.wait_for(lk, std::chrono::seconds(300),
               [this] { return phase_ == Phase::kDone; });
  const bool ok = !finished_path_.empty();
  if (ok) {
    if (out_path) *out_path = finished_path_;
  } else if (error) {
    *error = error_.empty() ? "stop timed out" : error_;
  }
  lk.unlock();
  Cleanup();
  return ok;
}

void RecorderClient::Abort() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    phase_ = Phase::kDone;  // suppress the reader's EOF -> async-fail path
  }
  active_ = false;
  WriteCommand("ABORT");
  Cleanup();
}

void RecorderClient::Pause() {
  paused_ = true;
  WriteCommand("PAUSE");
}

void RecorderClient::Resume() {
  paused_ = false;
  WriteCommand("RESUME");
}

std::string RecorderClient::TakeAsyncError() {
  std::lock_guard<std::mutex> lk(mu_);
  std::string e = async_error_;
  async_error_.clear();
  return e;
}

void RecorderClient::WriteCommand(const char* cmd) {
  HANDLE h = child_stdin_wr_;
  if (!h) return;
  std::string s = cmd;
  s += "\n";
  DWORD written = 0;
  WriteFile(h, s.data(), static_cast<DWORD>(s.size()), &written, nullptr);
}

void RecorderClient::ReaderLoop() {
  std::string buf;
  char chunk[512];
  for (;;) {
    DWORD n = 0;
    BOOL ok = ReadFile(child_stdout_rd_, chunk, sizeof(chunk), &n, nullptr);
    if (!ok || n == 0) break;  // pipe closed -> worker exited
    buf.append(chunk, n);
    size_t nl;
    while ((nl = buf.find('\n')) != std::string::npos) {
      std::string line = buf.substr(0, nl);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      buf.erase(0, nl + 1);
      if (!line.empty()) HandleLine(line);
    }
  }
  // EOF: the worker exited. If we were mid-startup/stop, unblock the waiter; if
  // we were running, it crashed -> async-fail so the main app reports it.
  std::lock_guard<std::mutex> lk(mu_);
  if (phase_ == Phase::kStarting || phase_ == Phase::kStopping) {
    if (error_.empty()) error_ = "recording worker exited unexpectedly";
    phase_ = Phase::kDone;
    cv_.notify_all();
  } else if (phase_ == Phase::kRunning) {
    async_error_ = "recording worker exited unexpectedly";
    phase_ = Phase::kDone;  // terminal: do not also fire from a later signal
    active_ = false;
    if (async_target_) {
      PostMessage(async_target_, async_msg_, Recorder::kAsyncFailed, 0);
    }
  }
}

void RecorderClient::HandleLine(const std::string& line) {
  if (line.rfind("STARTED ", 0) == 0) {
    long long did = 0;
    double x = 0, y = 0, w = 0, h = 0;
    sscanf_s(line.c_str() + 8, "%lld %lf %lf %lf %lf", &did, &x, &y, &w, &h);
    std::lock_guard<std::mutex> lk(mu_);
    started_info_.display_id = static_cast<int64_t>(did);
    started_info_.x = x;
    started_info_.y = y;
    started_info_.w = w;
    started_info_.h = h;
    phase_ = Phase::kRunning;
    cv_.notify_all();
  } else if (line.rfind("FINISHED ", 0) == 0) {
    std::lock_guard<std::mutex> lk(mu_);
    finished_path_ = line.substr(9);
    phase_ = Phase::kDone;
    active_ = false;
    cv_.notify_all();
  } else if (line.rfind("FAILED", 0) == 0) {
    std::string msg = line.size() > 7 ? line.substr(7) : "recording failed";
    std::lock_guard<std::mutex> lk(mu_);
    if (phase_ == Phase::kStarting || phase_ == Phase::kStopping) {
      error_ = msg;
      phase_ = Phase::kDone;
      active_ = false;
      cv_.notify_all();
    } else {
      async_error_ = msg;
      active_ = false;
      if (async_target_) {
        PostMessage(async_target_, async_msg_, Recorder::kAsyncFailed, 0);
      }
    }
  } else if (line == "AUTOSTOP") {
    if (async_target_) {
      PostMessage(async_target_, async_msg_, Recorder::kAsyncAutoStop, 0);
    }
  } else if (line.rfind("STATS ", 0) == 0) {
    const char* p = std::strstr(line.c_str(), "frames=");
    if (p) gif_frames_ = atoi(p + 7);
  }
}

void RecorderClient::Cleanup() {
  // Closing our write end of the worker's stdin signals EOF -> the worker aborts
  // and exits; then its stdout closes and the reader thread ends.
  if (child_stdin_wr_) {
    CloseHandle(child_stdin_wr_);
    child_stdin_wr_ = nullptr;
  }
  if (process_) {
    if (WaitForSingleObject(process_, 3000) == WAIT_TIMEOUT) {
      TerminateProcess(process_, 1);
    }
  }
  if (reader_.joinable()) reader_.join();
  if (child_stdout_rd_) {
    CloseHandle(child_stdout_rd_);
    child_stdout_rd_ = nullptr;
  }
  if (process_) {
    CloseHandle(process_);
    process_ = nullptr;
  }
  active_ = false;
}
