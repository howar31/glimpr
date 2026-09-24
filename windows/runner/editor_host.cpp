#include "editor_host.h"

#include <windows.h>
// shellapi.h (CommandLineToArgvW) must follow windows.h.
#include <shellapi.h>

#include <flutter/dart_project.h>
#include <flutter/standard_message_codec.h>

#include <cstdlib>
#include <cwchar>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "base64.h"
#include "editor_exit_gate.h"
#include "editor_placement.h"
#include "editor_window.h"
#include "gpu_preference.h"
#include "overlay_ipc.h"
#include "perf_log.h"
#include "sound_channel.h"
#include "utils.h"

namespace {

// A complete stdin line, heap-allocated by the reader thread (lparam).
constexpr UINT WM_EHOST_LINE = WM_APP + 20;
// stdin closed: the main process is gone, or is shutting this host down.
constexpr UINT WM_EHOST_EOF = WM_APP + 21;
// The exit gate polls the editor's state while the window is hidden.
constexpr UINT_PTR kGateTimerId = 1;
constexpr UINT kGateTickMs = 250;

HANDLE g_stdout = nullptr;
std::mutex g_write_mutex;  // perf marks may come from worker threads
EditorWindow* g_editor = nullptr;
HWND g_host_wnd = nullptr;
egate::State g_gate;

void WriteLine(const std::string& line) {
  std::lock_guard<std::mutex> lock(g_write_mutex);
  if (!g_stdout) return;
  const std::string out = line + "\n";
  DWORD written = 0;
  WriteFile(g_stdout, out.data(), static_cast<DWORD>(out.size()), &written,
            nullptr);
}

void ForwardPerfMark(const std::string& label) {
  WriteLine(oipc::Format("PERF", "mark", label));
}

[[noreturn]] void ExitNow() { ExitProcess(0); }

std::string EncodeArgs(const flutter::EncodableValue& args) {
  if (args.IsNull()) return std::string();
  const auto bytes =
      flutter::StandardMessageCodec::GetInstance().EncodeMessage(args);
  return bytes ? std::string(bytes->begin(), bytes->end()) : std::string();
}

class PipeLink : public EditorHostLink {
 public:
  explicit PipeLink(DWORD main_pid) : main_pid_(main_pid) {}

  void Call(const std::string& method,
            const flutter::EncodableValue& args) override {
    WriteLine(oipc::Format("CALL", method, EncodeArgs(args)));
  }

  void Ready() override {
    perf::Mark("editorHostReady");
    WriteLine(oipc::Format("READY"));
  }

  void Hidden() override {
    g_gate = egate::State{};
    if (g_host_wnd) SetTimer(g_host_wnd, kGateTimerId, kGateTickMs, nullptr);
  }

  void Shown() override {
    g_gate = egate::State{};
    if (g_host_wnd) KillTimer(g_host_wnd, kGateTimerId);
  }

  DWORD main_pid() const override { return main_pid_; }

 private:
  DWORD main_pid_;
};

// The window is closed and the editor's deferred work has drained: hand the
// placement to the main process for the next host, say goodbye, and leave.
void EndProcess() {
  if (g_host_wnd) KillTimer(g_host_wnd, kGateTimerId);
  eplace::Placement p;
  if (g_editor && g_editor->GetPlacement(&p)) {
    WriteLine(oipc::Format("CALL", "placement",
                           EncodeArgs(flutter::EncodableValue(eplace::Encode(p)))));
  }
  perf::Mark("editorHostBye");
  WriteLine(oipc::Format("BYE"));
  FlushFileBuffers(g_stdout);
  ExitNow();
}

void OnGateTick() {
  if (!g_editor) return;
  egate::Inputs in;
  in.hidden = g_editor->IsHidden();
  in.processing = g_editor->processing();
  in.sound_idle = SoundChannel::IsIdle();
  in.now_ms = GetTickCount64();
  if (egate::MayExit(in, &g_gate)) EndProcess();
}

void HandleCommand(const oipc::Message& m) {
  if (!g_editor || m.verb != "CALL") return;
  if (m.method == "reveal") {
    g_editor->RevealEditor();
  } else if (m.method == "loadPath") {
    std::string path;
    if (!m.payload.empty()) {
      auto decoded =
          flutter::StandardMessageCodec::GetInstance().DecodeMessage(
              reinterpret_cast<const uint8_t*>(m.payload.data()),
              m.payload.size());
      if (decoded) {
        if (const auto* s = std::get_if<std::string>(decoded.get())) path = *s;
      }
    }
    if (!path.empty()) g_editor->OpenWithPath(path);
  } else if (m.method == "loadClipboard") {
    g_editor->LoadClipboard();
  } else if (m.method == "clearRecent") {
    g_editor->ClearRecent();
  } else if (m.method == "refreshRecent") {
    g_editor->RefreshRecent();
  }
}

LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  switch (msg) {
    case WM_EHOST_LINE: {
      std::unique_ptr<std::string> line(
          reinterpret_cast<std::string*>(lparam));
      const oipc::Message m = oipc::Parse(*line);
      if (m.ok) HandleCommand(m);
      return 0;
    }
    case WM_EHOST_EOF:
      ExitNow();
    case WM_TIMER:
      if (wparam == kGateTimerId) {
        OnGateTick();
        return 0;
      }
      break;
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

// Marshals each stdin line to the UI thread, which owns the editor window.
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
      auto* line = new std::string(buf.substr(0, nl));
      buf.erase(0, nl + 1);
      if (!PostMessage(wnd, WM_EHOST_LINE, 0,
                       reinterpret_cast<LPARAM>(line))) {
        delete line;
      }
    }
  }
  PostMessage(wnd, WM_EHOST_EOF, 0, 0);
}

// The value of "--<name>=" on our command line, empty when absent.
std::wstring ArgValue(const wchar_t* prefix) {
  std::wstring value;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const size_t prefix_len = wcslen(prefix);
  for (int i = 1; argv && i < argc; ++i) {
    if (wcsncmp(argv[i], prefix, prefix_len) == 0) value = argv[i] + prefix_len;
  }
  if (argv) LocalFree(argv);
  return value;
}

std::optional<eplace::Placement> ParsePlacementArg() {
  const std::wstring v = ArgValue(L"--placement=");
  if (v.empty()) return std::nullopt;
  const std::string decoded = b64::Decode(Utf8FromUtf16(v));
  eplace::Placement p;
  if (!eplace::Parse(decoded, &p)) return std::nullopt;
  return p;
}

}  // namespace

int EditorHostMain() {
  g_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
  perf::InitForward(&ForwardPerfMark);
  // Flutter, the file_selector plugin, WIC, the clipboard and RegisterDragDrop
  // want an OLE-initialized STA thread, same as the main process.
  OleInitialize(nullptr);

  const DWORD main_pid = static_cast<DWORD>(
      wcstoul(ArgValue(L"--main-pid=").c_str(), nullptr, 10));

  WNDCLASSW wc{};
  wc.lpfnWndProc = HostProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"GlimprEditorHost";
  RegisterClassW(&wc);
  g_host_wnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
                               HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
  if (!g_host_wnd) {
    OleUninitialize();
    return 1;
  }

  flutter::DartProject project(L"data");
  // A fresh host per open, so the GPU choice applies from the next open
  // without restarting the main process.
  prefs::ApplyGpuPreference(&project);
  PipeLink link(main_pid);
  EditorWindow editor(project, &link);
  g_editor = &editor;
  if (const auto placement = ParsePlacementArg()) {
    editor.ApplyPlacement(*placement);
  }
  perf::Mark("editorHostWarmUp");
  editor.WarmUp();  // hidden window + engine; READY follows from editorReady

  std::thread reader(StdinReader, g_host_wnd);
  reader.detach();  // blocked in ReadFile until the process exits

  MSG msg;
  while (GetMessage(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }
  ExitNow();
}
