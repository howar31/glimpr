#include "editor_host_client.h"

#include <flutter/encodable_value.h>
#include <flutter/standard_message_codec.h>

#include <thread>
#include <utility>
#include <vector>

#include "base64.h"
#include "overlay_ipc.h"
#include "perf_log.h"

namespace {

using ehstate::Machine;
using ehstate::Pending;
using ehstate::State;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr ULONGLONG kCrashWindowMs = 30000;
constexpr int kCrashBurst = 3;
// A graceful close (stdin EOF) gets this long before the host is terminated:
// long enough for a pending settings write to land.
constexpr DWORD kGracefulExitMs = 1000;

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

std::string EncodeArgs(const EncodableValue& args) {
  const auto bytes =
      flutter::StandardMessageCodec::GetInstance().EncodeMessage(args);
  return bytes ? std::string(bytes->begin(), bytes->end()) : std::string();
}

}  // namespace

EditorHostClient* EditorHostClient::instance_ = nullptr;

EditorHostClient::EditorHostClient(HWND control_hwnd, Callbacks callbacks)
    : control_hwnd_(control_hwnd), cb_(std::move(callbacks)) {
  instance_ = this;
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
    // Kill-on-close binds the host to us; silent breakaway keeps the
    // Explorer windows the editor opens ("More..." in the gallery) out of the
    // job, so quitting Glimpr never closes them.
    info.BasicLimitInformation.LimitFlags =
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK;
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &info,
                            sizeof(info));
  }
}

EditorHostClient::~EditorHostClient() {
  Shutdown();
  if (job_) CloseHandle(job_);
  if (instance_ == this) instance_ = nullptr;
}

void EditorHostClient::Reveal() { Request(Pending::kReveal, std::string()); }

void EditorHostClient::OpenWithPath(const std::string& path) {
  if (path.empty()) return;
  Request(Pending::kPath, path);
}

void EditorHostClient::LoadClipboard() {
  Request(Pending::kClipboard, std::string());
}

void EditorHostClient::ClearRecent() {
  if (machine_.state == State::kOpen) WriteCommand(oipc::Format("CALL", "clearRecent"));
}

void EditorHostClient::RefreshRecent() {
  if (machine_.state == State::kOpen) {
    WriteCommand(oipc::Format("CALL", "refreshRecent"));
  }
}

void EditorHostClient::Request(Pending::Kind kind, const std::string& path) {
  if (shut_down_) return;
  const Machine::Action a = machine_.OnRequest(kind, path);
  if (a == Machine::Action::kSend) {
    SendRequest(kind, path);
    return;
  }
  Act(a);
}

void EditorHostClient::Act(Machine::Action action) {
  switch (action) {
    case Machine::Action::kSpawn:
      if (respawn_timer_) {
        KillTimer(nullptr, respawn_timer_);
        respawn_timer_ = 0;
      }
      Act(machine_.OnSpawned(Spawn()));
      break;
    case Machine::Action::kSendPending:
      SendPending();
      break;
    case Machine::Action::kDropPending:
      perf::Mark("editorHostSpawnFailed");
      break;
    case Machine::Action::kSend:
    case Machine::Action::kNone:
      break;
  }
}

bool EditorHostClient::Spawn() {
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

  // Hand the host exactly its two pipe ends (the overlay host and the record
  // worker must not inherit them, or a dead parent's EOF never fires).
  HANDLE inherit[2] = {out_wr, in_rd};
  SIZE_T attr_size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &attr_size);
  std::vector<char> attr_buf(attr_size);
  auto* attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attr_buf.data());
  bool attrs_ok =
      InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size) &&
      UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                inherit, sizeof(inherit), nullptr, nullptr);

  std::wstring cl = L"\"" + ExePath() + L"\" --editor-host --main-pid=" +
                    std::to_wstring(GetCurrentProcessId());
  if (placement_) {
    const std::string enc = b64::Encode(eplace::Encode(*placement_));
    cl += L" --placement=" + std::wstring(enc.begin(), enc.end());
  }
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
  machine_.said_bye = false;
  const uint64_t generation = ++generation_;
  perf::Mark("editorHostSpawn");
  // The reader owns [out_rd] and ends on EOF, which a dead host guarantees.
  std::thread([this, out_rd, generation] {
    ReaderLoop(out_rd, generation);
  }).detach();
  return true;
}

void EditorHostClient::ReaderLoop(HANDLE pipe, uint64_t generation) {
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
    PostMessage(target, WM_GLIMPR_EDITOR_HOST, 0, 0);
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

void EditorHostClient::OnHostMessage() {
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

void EditorHostClient::HandleLine(const std::string& line) {
  const oipc::Message m = oipc::Parse(line);
  if (!m.ok) return;
  if (m.verb == "READY") {
    perf::Mark("editorHostReadyMain");
    crash_count_ = 0;
    Act(machine_.OnReady());
    return;
  }
  if (m.verb == "BYE") {
    Act(machine_.OnBye());
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

  if (m.method == "setRecentImages") {
    std::vector<std::string> list;
    if (const auto* l = std::get_if<EncodableList>(&args)) {
      for (const auto& v : *l) {
        if (const auto* s = std::get_if<std::string>(&v)) list.push_back(*s);
      }
    }
    if (cb_.set_recent_images) cb_.set_recent_images(std::move(list));
  } else if (m.method == "pinImage") {
    const std::string path = GetString(map, "path");
    if (!path.empty() && cb_.pin_image) cb_.pin_image(path);
  } else if (m.method == "setProcessing") {
    if (cb_.set_processing) {
      cb_.set_processing(GetBool(map, "active"), GetString(map, "label"));
    }
  } else if (m.method == "openSettings") {
    if (cb_.open_settings) cb_.open_settings();
  } else if (m.method == "placement") {
    eplace::Placement p;
    if (const auto* s = std::get_if<std::string>(&args)) {
      if (eplace::Parse(*s, &p)) placement_ = p;
    }
  }
}

void EditorHostClient::HandleExit() {
  const bool normal = machine_.said_bye;
  machine_.said_bye = false;
  CloseChild(/*terminate=*/false);
  const Machine::Action next = machine_.OnExit();
  if (normal) {
    perf::Mark("editorHostGone");
    Act(next);
    return;
  }
  // The host died with its window up (or mid-export): the tray may still be
  // pulsing on its behalf.
  perf::Mark("editorHostCrashed");
  if (cb_.set_processing) cb_.set_processing(false, std::string());

  const ULONGLONG now = GetTickCount64();
  if (crash_count_ == 0 || now - first_crash_tick_ > kCrashWindowMs) {
    crash_count_ = 0;
    first_crash_tick_ = now;
  }
  ++crash_count_;
  if (next != Machine::Action::kSpawn) return;  // nothing waiting: stay down
  if (crash_count_ >= kCrashBurst) {
    machine_.pending = Pending{};  // give up on it; the next request retries
    return;
  }
  if (crash_count_ == 1) {
    Act(next);
    return;
  }
  respawn_timer_ = SetTimer(nullptr, 0, crash_count_ == 2 ? 1000 : 5000,
                            &EditorHostClient::RespawnProc);
}

void EditorHostClient::SendPending() {
  const Pending p = machine_.pending;
  machine_.pending = Pending{};
  if (p.kind == Pending::kNoneKind) return;
  SendRequest(p.kind, p.path);
}

void EditorHostClient::SendRequest(Pending::Kind kind, const std::string& path) {
  // Whoever asked us (a hotkey, the tray, the overlay) gave THIS process the
  // right to take the foreground; pass it on so the editor window can.
  AllowSetForegroundWindow(child_pid_);
  switch (kind) {
    case Pending::kReveal:
      WriteCommand(oipc::Format("CALL", "reveal"));
      break;
    case Pending::kPath:
      WriteCommand(
          oipc::Format("CALL", "loadPath", EncodeArgs(EncodableValue(path))));
      break;
    case Pending::kClipboard:
      WriteCommand(oipc::Format("CALL", "loadClipboard"));
      break;
    case Pending::kNoneKind:
      break;
  }
}

void EditorHostClient::WriteCommand(const std::string& line) {
  if (!child_stdin_wr_) return;
  const std::string out = line + "\n";
  DWORD written = 0;
  WriteFile(child_stdin_wr_, out.data(), static_cast<DWORD>(out.size()),
            &written, nullptr);
}

void EditorHostClient::CloseChild(bool terminate) {
  if (child_stdin_wr_) {
    CloseHandle(child_stdin_wr_);  // EOF on its stdin = exit now
    child_stdin_wr_ = nullptr;
  }
  if (process_) {
    if (terminate &&
        WaitForSingleObject(process_, kGracefulExitMs) != WAIT_OBJECT_0) {
      TerminateProcess(process_, 0);
      WaitForSingleObject(process_, 1000);
    }
    CloseHandle(process_);
    process_ = nullptr;
  }
  child_pid_ = 0;
}

void EditorHostClient::Shutdown() {
  if (shut_down_) return;
  shut_down_ = true;
  if (respawn_timer_) {
    KillTimer(nullptr, respawn_timer_);
    respawn_timer_ = 0;
  }
  ++generation_;  // drop whatever the reader still delivers
  CloseChild(/*terminate=*/true);
  machine_ = Machine{};
}

// static
void CALLBACK EditorHostClient::RespawnProc(HWND, UINT, UINT_PTR id, DWORD) {
  KillTimer(nullptr, id);
  if (!instance_) return;
  instance_->respawn_timer_ = 0;
  if (instance_->machine_.state == State::kNone &&
      instance_->machine_.pending.kind != Pending::kNoneKind) {
    instance_->Act(Machine::Action::kSpawn);
  }
}
