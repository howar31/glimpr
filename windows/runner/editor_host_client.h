#ifndef RUNNER_EDITOR_HOST_CLIENT_H_
#define RUNNER_EDITOR_HOST_CLIENT_H_

#include <windows.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "editor_host_state.h"
#include "editor_placement.h"

// A line (or EOF) from the editor host arrived; FlutterWindow routes it to
// EditorHostClient::OnHostMessage on the platform thread.
#define WM_GLIMPR_EDITOR_HOST (WM_APP + 6)

// Main-process side of the editor host (editor_host.h): spawns the child on
// the first open request, forwards open / load / recents commands to it,
// dispatches its one-way calls to the resident objects (tray, pins, Settings)
// and forgets it when it says BYE. At most one host exists; a request that
// arrives while none is ready is held and delivered on READY.
class EditorHostClient {
 public:
  struct Callbacks {
    std::function<void(std::vector<std::string>)> set_recent_images;
    std::function<void(const std::string& path)> pin_image;
    std::function<void(bool active, const std::string& label)> set_processing;
    std::function<void()> open_settings;
  };

  EditorHostClient(HWND control_hwnd, Callbacks callbacks);
  ~EditorHostClient();

  EditorHostClient(const EditorHostClient&) = delete;
  EditorHostClient& operator=(const EditorHostClient&) = delete;

  // Open requests (spawn a host when none is alive).
  void Reveal();
  void OpenWithPath(const std::string& path);
  void LoadClipboard();
  // Recents commands: only a live editor cares (the control engine owns the
  // tray list); dropped when no host is open.
  void ClearRecent();
  void RefreshRecent();

  // WM_GLIMPR_EDITOR_HOST / the client's timers, on the platform thread.
  void OnHostMessage();

  // End the host for good (quit / relaunch / self-update): it must be gone
  // before this process exits so its window vanishes and the exe is unmapped.
  void Shutdown();

 private:
  struct Event {
    uint64_t generation = 0;
    bool eof = false;
    std::string line;
  };

  void Request(ehstate::Pending::Kind kind, const std::string& path);
  void Act(ehstate::Machine::Action action);
  bool Spawn();
  void ReaderLoop(HANDLE pipe, uint64_t generation);
  void HandleLine(const std::string& line);
  void HandleExit();
  void SendPending();
  void SendRequest(ehstate::Pending::Kind kind, const std::string& path);
  void WriteCommand(const std::string& line);
  void CloseChild(bool terminate);

  static void CALLBACK RespawnProc(HWND, UINT, UINT_PTR, DWORD);

  HWND control_hwnd_ = nullptr;
  Callbacks cb_;
  ehstate::Machine machine_;
  bool shut_down_ = false;

  HANDLE job_ = nullptr;  // kill-on-close: the host never outlives us
  HANDLE process_ = nullptr;
  DWORD child_pid_ = 0;
  HANDLE child_stdin_wr_ = nullptr;
  uint64_t generation_ = 0;  // stale readers' events are ignored

  std::mutex mu_;
  std::deque<Event> events_;  // reader threads -> platform thread

  // The last host's window placement, handed to the next one.
  std::optional<eplace::Placement> placement_;

  // Crash handling: back off, and stop respawning eagerly after a burst.
  int crash_count_ = 0;
  ULONGLONG first_crash_tick_ = 0;
  UINT_PTR respawn_timer_ = 0;

  static EditorHostClient* instance_;  // routes the thread-timer callback
};

#endif  // RUNNER_EDITOR_HOST_CLIENT_H_
