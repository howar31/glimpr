#include "overlay_host.h"

#include <windows.h>
// shellapi.h (CommandLineToArgvW) must follow windows.h.
#include <shellapi.h>

#include <flutter/dart_project.h>
#include <flutter/standard_message_codec.h>

#include <cstdlib>
#include <cwchar>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "element_snap.h"
#include "gpu_preference.h"
#include "overlay_ipc.h"
#include "overlay_manager.h"
#include "perf_log.h"

namespace {

// A complete stdin line, heap-allocated by the reader thread (lparam).
constexpr UINT WM_OHOST_LINE = WM_APP + 20;
// stdin closed: the main process is gone, or is shutting this host down.
constexpr UINT WM_OHOST_EOF = WM_APP + 21;

HANDLE g_stdout = nullptr;
std::mutex g_write_mutex;  // perf marks may come from worker threads
OverlayManager* g_manager = nullptr;

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

[[noreturn]] void ExitNow() {
  // A drawing lock clips the cursor system-wide and would outlive us.
  ClipCursor(nullptr);
  ExitProcess(0);
}

class PipeLink : public OverlayHostLink {
 public:
  explicit PipeLink(DWORD main_pid) : main_pid_(main_pid) {}

  void Call(const std::string& method,
            const flutter::EncodableValue& args) override {
    std::string payload;
    if (!args.IsNull()) {
      const auto bytes =
          flutter::StandardMessageCodec::GetInstance().EncodeMessage(args);
      if (bytes) payload.assign(bytes->begin(), bytes->end());
    }
    WriteLine(oipc::Format("CALL", method, payload));
  }

  void EndSession() override {
    WriteLine(oipc::Format("BYE"));
    FlushFileBuffers(g_stdout);
    ExitNow();
  }

  DWORD main_pid() const override { return main_pid_; }

 private:
  DWORD main_pid_;
};

LRESULT CALLBACK HostProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  switch (msg) {
    case WM_GLIMPR_ELSNAP:
      if (g_manager) g_manager->OnElementSnapDone();
      return 0;
    case WM_OHOST_LINE: {
      std::unique_ptr<std::string> line(
          reinterpret_cast<std::string*>(lparam));
      const oipc::Message m = oipc::Parse(*line);
      bool pin_only = false, live_select = false;
      if (!g_manager || !m.ok) return 0;
      if (oipc::ParseBegin(m, &pin_only, &live_select)) {
        g_manager->BeginCapture(pin_only, live_select);
        // Proof of life for the main process's wedge watchdog: this thread
        // took the trigger and came back from the capture.
        WriteLine(oipc::Format("ACK"));
      } else if (m.verb == "RSHOTKEY") {
        g_manager->RelayRecordSelectHotkey();
      }
      return 0;
    }
    case WM_OHOST_EOF:
      ExitNow();
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

// Marshals each stdin line to the UI thread, which owns the OverlayManager.
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
      if (!PostMessage(wnd, WM_OHOST_LINE, 0,
                       reinterpret_cast<LPARAM>(line))) {
        delete line;
      }
    }
  }
  PostMessage(wnd, WM_OHOST_EOF, 0, 0);
}

DWORD ParseMainPid() {
  DWORD pid = 0;
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const wchar_t kPrefix[] = L"--main-pid=";
  const size_t prefix_len = wcslen(kPrefix);
  for (int i = 1; argv && i < argc; ++i) {
    if (wcsncmp(argv[i], kPrefix, prefix_len) == 0) {
      pid = static_cast<DWORD>(wcstoul(argv[i] + prefix_len, nullptr, 10));
    }
  }
  if (argv) LocalFree(argv);
  return pid;
}

}  // namespace

int OverlayHostMain() {
  g_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
  perf::InitForward(&ForwardPerfMark);
  // Flutter, the file_selector plugin, WIC and the clipboard want an
  // OLE-initialized STA thread, same as the main process.
  OleInitialize(nullptr);

  const DWORD main_pid = ParseMainPid();
  elsnap::SetMainProcessId(main_pid);

  WNDCLASSW wc{};
  wc.lpfnWndProc = HostProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"GlimprOverlayHost";
  RegisterClassW(&wc);
  HWND wnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0,
                             HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
  if (!wnd) {
    OleUninitialize();
    return 1;
  }

  flutter::DartProject project(L"data");
  // A fresh host per session, so the GPU choice applies from the next
  // screenshot without restarting the main process.
  prefs::ApplyGpuPreference(&project);
  PipeLink link(main_pid);
  OverlayManager manager(project, wnd, &link);
  g_manager = &manager;
  manager.WarmUp();  // build the per-display engines before announcing
  WriteLine(oipc::Format("READY"));

  std::thread reader(StdinReader, wnd);
  reader.detach();  // blocked in ReadFile until the process exits

  MSG msg;
  while (GetMessage(&msg, nullptr, 0, 0)) {
    TranslateMessage(&msg);
    DispatchMessage(&msg);
  }
  ExitNow();
}
