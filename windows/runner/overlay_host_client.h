#ifndef RUNNER_OVERLAY_HOST_CLIENT_H_
#define RUNNER_OVERLAY_HOST_CLIENT_H_

#include <windows.h>

#include <flutter/encodable_value.h>

#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

// A line (or EOF) from the overlay host arrived; FlutterWindow routes it to
// OverlayHostClient::OnHostMessage on the platform thread.
#define WM_GLIMPR_OVERLAY_HOST (WM_APP + 5)

// Main-process side of the overlay host (overlay_host.h): spawns the child,
// forwards the capture triggers to it, dispatches its one-way calls to the
// resident objects, and replaces it after every session. Exactly one host
// exists at a time; a trigger that arrives while none is ready is held and
// delivered on READY.
class OverlayHostClient {
 public:
  struct Callbacks {
    std::function<void(const std::string& path)> open_in_editor;
    std::function<void()> recent_changed;
    std::function<void(const flutter::EncodableMap& args)> pin_image;
    std::function<void()> open_settings;
    std::function<void(flutter::EncodableValue args)> record_selection;
    std::function<void(bool active, const std::string& label)> set_processing;
  };

  OverlayHostClient(HWND control_hwnd, Callbacks callbacks);
  ~OverlayHostClient();

  OverlayHostClient(const OverlayHostClient&) = delete;
  OverlayHostClient& operator=(const OverlayHostClient&) = delete;

  // Start a host now if none exists, so the first capture finds warm engines.
  void WarmUp();
  void BeginCapture(bool pin_only, bool live_select);
  void RelayRecordSelectHotkey();

  // WM_GLIMPR_OVERLAY_HOST / the client's timers, on the platform thread.
  void OnHostMessage();

  // End the host for good (quit / relaunch / self-update): it must be gone
  // before this process exits so its windows vanish and the exe is unmapped.
  void Shutdown();

 private:
  // kEnding: the host said BYE and is exiting; a trigger now is held for the
  // next host instead of being written into a closing pipe.
  enum class State { kNone, kSpawning, kReady, kInSession, kEnding };

  struct Event {
    uint64_t generation = 0;
    bool eof = false;
    std::string line;
  };

  bool Spawn();
  void ReaderLoop(HANDLE pipe, uint64_t generation);
  void HandleLine(const std::string& line);
  void HandleExit();
  void WriteCommand(const std::string& line);
  void CloseChild(bool terminate);
  void DeliverBegin(bool pin_only, bool live_select);

  static void CALLBACK RespawnProc(HWND, UINT, UINT_PTR, DWORD);
  static void CALLBACK WedgeProc(HWND, UINT, UINT_PTR, DWORD);

  HWND control_hwnd_ = nullptr;
  Callbacks cb_;
  State state_ = State::kNone;
  bool shut_down_ = false;

  HANDLE job_ = nullptr;  // kill-on-close: the host never outlives us
  HANDLE process_ = nullptr;
  DWORD child_pid_ = 0;
  HANDLE child_stdin_wr_ = nullptr;
  uint64_t generation_ = 0;  // stale readers' events are ignored
  bool said_bye_ = false;

  std::mutex mu_;
  std::deque<Event> events_;  // reader threads -> platform thread

  // A trigger that found no ready host: the latest one wins, and it expires.
  bool pending_ = false;
  bool pending_pin_only_ = false;
  bool pending_live_select_ = false;
  ULONGLONG pending_tick_ = 0;

  // Crash handling: back off, and stop respawning eagerly after a burst.
  int crash_count_ = 0;
  ULONGLONG first_crash_tick_ = 0;
  UINT_PTR respawn_timer_ = 0;
  UINT_PTR wedge_timer_ = 0;  // a triggered host that never answers

  static OverlayHostClient* instance_;  // routes the thread-timer callbacks
};

#endif  // RUNNER_OVERLAY_HOST_CLIENT_H_
