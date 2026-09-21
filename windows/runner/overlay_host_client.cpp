#include "overlay_host_client.h"

#include <flutter/standard_message_codec.h>

#include <utility>
#include <vector>

#include "overlay_ipc.h"
#include "perf_log.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// A held trigger older than this is dropped instead of firing late.
constexpr ULONGLONG kPendingMaxAgeMs = 3000;
// A triggered host must say something (its overlays report back at once).
constexpr UINT kWedgeTimeoutMs = 5000;
constexpr ULONGLONG kCrashWindowMs = 30000;
constexpr int kCrashBurst = 3;

std::wstring ExePath() {
  wchar_t buf[MAX_PATH];
  const DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
  return std::wstring(buf, n);
}

std::string GetString(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it == map.end()) return std::string();
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string();
}

bool GetBool(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(std::string(key)));
  if (it == map.end()) return false;
  const auto* b = std::get_if<bool>(&it->second);
  return b && *b;
}

}  // namespace

OverlayHostClient* OverlayHostClient::instance_ = nullptr;

OverlayHostClient::OverlayHostClient(HWND control_hwnd, Callbacks callbacks)
    : control_hwnd_(control_hwnd), cb_(std::move(callbacks)) {
  instance_ = this;
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &info,
                            sizeof(info));
  }
}

OverlayHostClient::~OverlayHostClient() {
  Shutdown();
  if (job_) CloseHandle(job_);
  if (instance_ == this) instance_ = nullptr;
}

void OverlayHostClient::WarmUp() {
  if (shut_down_ || state_ != State::kNone) return;
  if (respawn_timer_) {
    KillTimer(nullptr, respawn_timer_);
    respawn_timer_ = 0;
  }
  if (Spawn()) state_ = State::kSpawning;
}

bool OverlayHostClient::Spawn() {
  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;
  HANDLE out_rd = nullptr, out_wr = nullptr, in_rd = nullptr, in_wr = nullptr;
  if (!CreatePipe(&out_rd, &out_wr, &sa, 0) ||
      !CreatePipe(&in_rd, &in_wr, &sa, 0)) {
    if (out_rd) CloseHandle(out_rd);
    if (out_wr) CloseHandle(out_wr);
    if (in_rd) CloseHandle(in_rd);
    if (in_wr) CloseHandle(in_wr);
    return false;
  }
  // Our ends must not be inherited by the host.
  SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
  SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0);

  // Hand the host exactly its two pipe ends: a record worker spawned while a
  // host is alive (or the reverse) must not inherit the other child's pipe,
  // or the EOF that signals a dead parent would never fire.
  HANDLE inherit[2] = {out_wr, in_rd};
  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
  std::vector<char> attr_buf(attr_size);
  auto* attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
  bool attrs_ok =
      InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) &&
      UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                inherit, sizeof(inherit), nullptr, nullptr);

  std::wstring cl = L"\"" + ExePath() + L"\" --overlay-host --main-pid=" +
                    std::to_wstring(GetCurrentProcessId());
  std::vector<wchar_t> cmd(cl.begin(), cl.end());
  cmd.push_back(L'\0');

  STARTUPINFOEXW si{};
  si.StartupInfo.cb = sizeof(si);
  si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  si.StartupInfo.hStdOutput = out_wr;
  si.StartupInfo.hStdError = out_wr;
  si.StartupInfo.hStdInput = in_rd;
  si.lpAttributeList = attrs_ok ? attrs : nullptr;
  DWORD flags = CREATE_SUSPENDED;
  if (attrs_ok) flags |= EXTENDED_STARTUPINFO_PRESENT;
  PROCESS_INFORMATION pi{};
  const BOOL ok = CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, TRUE,
                                 flags, nullptr, nullptr, &si.StartupInfo, &pi);
  if (attrs_ok) DeleteProcThreadAttributeList(attrs);
  // The host owns the write end of stdout and the read end of stdin now.
  CloseHandle(out_wr);
  CloseHandle(in_rd);
  if (!ok) {
    CloseHandle(out_rd);
    CloseHandle(in_wr);
    return false;
  }
  if (job_) AssignProcessToJobObject(job_, pi.hProcess);
  ResumeThread(pi.hThread);
  CloseHandle(pi.hThread);

  process_ = pi.hProcess;
  child_pid_ = pi.dwProcessId;
  child_stdin_wr_ = in_wr;
  said_bye_ = false;
  const uint64_t generation = ++generation_;
  perf::Mark("overlayHostSpawn");
  // The reader owns [out_rd] and ends on EOF, which a dead host guarantees.
  std::thread([this, out_rd, generation] {
    ReaderLoop(out_rd, generation);
  }).detach();
  return true;
}

void OverlayHostClient::ReaderLoop(HANDLE pipe, uint64_t generation) {
  std::string buf;
  char chunk[1024];
  auto push = [&](Event e) {
    e.generation = generation;
    HWND target = nullptr;
    {
      std::lock_guard<std::mutex> lock(mu_);
      events_.push_back(std::move(e));
      target = control_hwnd_;
    }
    PostMessage(target, WM_GLIMPR_OVERLAY_HOST, 0, 0);
  };
  for (;;) {
    DWORD n = 0;
    if (!ReadFile(pipe, chunk, sizeof(chunk), &n, nullptr) || n == 0) break;
    buf.append(chunk, n);
    size_t nl;
    while ((nl = buf.find('\n')) != std::string::npos) {
      Event e;
      e.line = buf.substr(0, nl);
      buf.erase(0, nl + 1);
      if (!e.line.empty()) push(std::move(e));
    }
  }
  CloseHandle(pipe);
  Event eof;
  eof.eof = true;
  push(std::move(eof));
}

void OverlayHostClient::OnHostMessage() {
  for (;;) {
    Event e;
    {
      std::lock_guard<std::mutex> lock(mu_);
      if (events_.empty()) return;
      e = std::move(events_.front());
      events_.pop_front();
    }
    if (e.generation != generation_ || shut_down_) continue;  // a past host
    if (e.eof) {
      HandleExit();
    } else {
      HandleLine(e.line);
    }
  }
}

void OverlayHostClient::HandleLine(const std::string& line) {
  // Any sign of life answers the trigger.
  if (wedge_timer_) {
    KillTimer(nullptr, wedge_timer_);
    wedge_timer_ = 0;
  }
  const oipc::Message m = oipc::Parse(line);
  if (!m.ok) return;
  if (m.verb == "READY") {
    perf::Mark("overlayHostReady");
    state_ = State::kReady;
    crash_count_ = 0;
    if (pending_) {
      pending_ = false;
      if (GetTickCount64() - pending_tick_ <= kPendingMaxAgeMs) {
        DeliverBegin(pending_pin_only_, pending_live_select_);
      }
    }
    return;
  }
  if (m.verb == "BYE") {
    said_bye_ = true;
    state_ = State::kEnding;
    return;
  }
  if (m.verb == "PERF") {
    perf::Mark(m.payload);
    return;
  }
  if (m.verb != "CALL") return;

  EncodableValue args;
  if (!m.payload.empty()) {
    auto decoded = flutter::StandardMessageCodec::GetInstance().DecodeMessage(
        reinterpret_cast<const uint8_t*>(m.payload.data()), m.payload.size());
    if (decoded) args = std::move(*decoded);
  }
  const EncodableMap empty;
  const auto* map_ptr = std::get_if<EncodableMap>(&args);
  const EncodableMap& map = map_ptr ? *map_ptr : empty;

  if (m.method == "openInEditor") {
    const std::string path = GetString(map, "path");
    if (!path.empty() && cb_.open_in_editor) cb_.open_in_editor(path);
  } else if (m.method == "recentChanged") {
    if (cb_.recent_changed) cb_.recent_changed();
  } else if (m.method == "pinImage") {
    if (cb_.pin_image) cb_.pin_image(map);
  } else if (m.method == "openSettings") {
    if (cb_.open_settings) cb_.open_settings();
  } else if (m.method == "recordSelection") {
    if (cb_.record_selection) cb_.record_selection(std::move(args));
  } else if (m.method == "setProcessing") {
    if (cb_.set_processing) {
      cb_.set_processing(GetBool(map, "active"), GetString(map, "label"));
    }
  }
}

void OverlayHostClient::HandleExit() {
  const bool normal = said_bye_;
  CloseChild(/*terminate=*/false);
  state_ = State::kNone;
  if (normal) {
    perf::Mark("overlayHostBye");
    WarmUp();  // the next capture should find warm engines again
    return;
  }
  // The host died mid-session. Undo what it may have left behind: a drawing
  // lock clips the cursor system-wide, and the tray may still be pulsing.
  perf::Mark("overlayHostCrashed");
  ClipCursor(nullptr);
  if (cb_.set_processing) cb_.set_processing(false, std::string());

  const ULONGLONG now = GetTickCount64();
  if (crash_count_ == 0 || now - first_crash_tick_ > kCrashWindowMs) {
    crash_count_ = 0;
    first_crash_tick_ = now;
  }
  ++crash_count_;
  if (crash_count_ >= kCrashBurst) return;  // wait for the next trigger
  if (crash_count_ == 1) {
    WarmUp();
    return;
  }
  respawn_timer_ = SetTimer(nullptr, 0, crash_count_ == 2 ? 1000 : 5000,
                            &OverlayHostClient::RespawnProc);
}

void OverlayHostClient::BeginCapture(bool pin_only, bool live_select) {
  if (shut_down_) return;
  if (state_ == State::kReady || state_ == State::kInSession) {
    DeliverBegin(pin_only, live_select);
    return;
  }
  // No host can take it yet (none, still warming, or the last one is on its
  // way out): hold the latest trigger for READY.
  pending_ = true;
  pending_pin_only_ = pin_only;
  pending_live_select_ = live_select;
  pending_tick_ = GetTickCount64();
  WarmUp();
}

void OverlayHostClient::DeliverBegin(bool pin_only, bool live_select) {
  // The hotkey gave THIS process the right to take the foreground; pass it on
  // so the host's overlay can take keyboard focus.
  AllowSetForegroundWindow(child_pid_);
  WriteCommand(oipc::FormatBegin(pin_only, live_select));
  if (state_ == State::kReady) {
    state_ = State::kInSession;
    if (wedge_timer_) KillTimer(nullptr, wedge_timer_);
    wedge_timer_ =
        SetTimer(nullptr, 0, kWedgeTimeoutMs, &OverlayHostClient::WedgeProc);
  }
}

void OverlayHostClient::RelayRecordSelectHotkey() {
  if (state_ == State::kReady || state_ == State::kInSession) {
    AllowSetForegroundWindow(child_pid_);
    WriteCommand(oipc::Format("RSHOTKEY"));
  }
}

void OverlayHostClient::WriteCommand(const std::string& line) {
  if (!child_stdin_wr_) return;
  const std::string out = line + "\n";
  DWORD written = 0;
  WriteFile(child_stdin_wr_, out.data(), static_cast<DWORD>(out.size()),
            &written, nullptr);
}

void OverlayHostClient::CloseChild(bool terminate) {
  if (wedge_timer_) {
    KillTimer(nullptr, wedge_timer_);
    wedge_timer_ = 0;
  }
  if (child_stdin_wr_) {
    CloseHandle(child_stdin_wr_);  // EOF on its stdin = exit now
    child_stdin_wr_ = nullptr;
  }
  if (process_) {
    if (terminate && WaitForSingleObject(process_, 300) != WAIT_OBJECT_0) {
      TerminateProcess(process_, 0);
      WaitForSingleObject(process_, 1000);
    }
    CloseHandle(process_);
    process_ = nullptr;
  }
  child_pid_ = 0;
}

void OverlayHostClient::Shutdown() {
  if (shut_down_) return;
  shut_down_ = true;
  if (respawn_timer_) {
    KillTimer(nullptr, respawn_timer_);
    respawn_timer_ = 0;
  }
  ++generation_;  // drop whatever the reader still delivers
  CloseChild(/*terminate=*/true);
  state_ = State::kNone;
}

// static
void CALLBACK OverlayHostClient::RespawnProc(HWND, UINT, UINT_PTR id, DWORD) {
  KillTimer(nullptr, id);
  if (!instance_) return;
  instance_->respawn_timer_ = 0;
  instance_->WarmUp();
}

// static
void CALLBACK OverlayHostClient::WedgeProc(HWND, UINT, UINT_PTR id, DWORD) {
  KillTimer(nullptr, id);
  if (!instance_) return;
  instance_->wedge_timer_ = 0;
  // Triggered and silent: a hung host could be holding a topmost full-screen
  // window over every display with nothing able to dismiss it.
  perf::Mark("overlayHostWedged");
  ++instance_->generation_;
  instance_->CloseChild(/*terminate=*/true);
  instance_->state_ = State::kNone;
  ClipCursor(nullptr);
  instance_->WarmUp();
}

